#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""One bounded, passive liuqin sample. No input events or application content."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time

VERSION = '1'
SEGMENT = 8 * 1024 * 1024
TOTAL = 64 * 1024 * 1024
RESERVE = 512 * 1024 * 1024
LINE = 16 * 1024
NAME = re.compile(r'sample-(\d{20})-([0-9a-f-]{36})\.jsonl\Z')


def read(path, limit=4096):
    try:
        with open(path) as stream:
            return stream.read(limit).strip()
    except OSError as exc:
        return {'unavailable': exc.__class__.__name__}


def command(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=0.4,
                                env={'PATH': '/usr/bin:/usr/sbin', 'LC_ALL': 'C'})
        if result.returncode:
            return {'unavailable': 'exit', 'code': result.returncode}
        return result.stdout.strip()[:4096]
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {'unavailable': exc.__class__.__name__}


def notes_build_id(data):
    # Same NT_GNU_BUILD_ID parsing as the sleep probe; sysfs is not an ELF file.
    offset, found = 0, []
    while offset + 12 <= len(data):
        namesz, descsz, kind = struct.unpack_from('<III', data, offset)
        offset += 12
        desc_at = offset + ((namesz + 3) & ~3)
        end = desc_at + descsz
        if desc_at > len(data) or end > len(data):
            raise ValueError('truncated ELF note')
        if data[offset:offset + namesz].rstrip(b'\0') == b'GNU' and kind == 3:
            found.append(data[desc_at:end].hex())
        offset = desc_at + ((descsz + 3) & ~3)
    if len(found) != 1 or not found[0]:
        raise ValueError('expected exactly one GNU build ID')
    return found[0]


def identity():
    try:
        build = notes_build_id(Path('/sys/kernel/notes').read_bytes())
    except (OSError, ValueError) as exc:
        build = {'unavailable': str(exc)}
    # Keep this inexpensive: RPM/whole journal enumeration is not a periodic job.
    return {'kernel_release': os.uname().release, 'build_id': build,
            'sampler_version': VERSION, 'os_release': read('/etc/os-release'),
            'python': os.sys.version.split()[0]}


def collect():
    started = time.monotonic_ns()
    power = {}
    # Raw kernel power_supply ABI: *_uAh, *_uWh, *_uA, *_uV; temperature is 0.1 C.
    fields = ('type', 'online', 'status', 'capacity', 'charge_now', 'charge_full',
              'energy_now', 'energy_full', 'current_now', 'voltage_now', 'temp')
    for supply in sorted(Path('/sys/class/power_supply').glob('*')):
        power[supply.name] = {key: read(supply / key) for key in fields
                              if (supply / key).exists()}
    mem = read('/proc/meminfo')
    if isinstance(mem, str):
        mem = {key: value.strip() for line in mem.splitlines() if ':' in line
               for key, value in [line.split(':', 1)]
               if key in ('MemAvailable', 'MemTotal', 'SwapTotal', 'SwapFree')}
    sessions = command(['loginctl', 'list-sessions', '--no-legend', '--no-pager'])
    locked = {}
    if isinstance(sessions, str):
        for line in sessions.splitlines():
            values = line.split()
            if len(values) >= 4 and values[3] == 'seat0':
                sid = values[0]
                locked[sid] = command(['loginctl', 'show-session', sid,
                                       '-p', 'LockedHint', '-p', 'Type', '-p', 'Active'])
    else:
        locked = sessions
    # No SSID, address, scan, ping, debugfs or D-Bus call that activates fprintd.
    wifi = {p.parent.name: read(p.parent / 'operstate')
            for p in Path('/sys/class/net').glob('*/wireless')}
    fingerprint = command(['systemctl', 'show', 'fprintd.service', '-p', 'ActiveState',
                           '-p', 'Result', '-p', 'ExecMainStatus'])
    dpms = {p.parent.name: read(p) for p in Path('/sys/class/drm').glob('card*-*/dpms')}
    row = {'schema': 1, 'boot_id': read('/proc/sys/kernel/random/boot_id'),
           'boottime_ns': time.clock_gettime_ns(time.CLOCK_BOOTTIME),
           'monotonic_ns': time.monotonic_ns(), 'realtime_ns': time.time_ns(),
           'ntp_synchronized': command(['timedatectl', 'show', '-p', 'NTPSynchronized',
                                        '--value']),
           'power_supply_raw': power, 'memory': mem,
           'psi': {key: read('/proc/pressure/' + key) for key in ('cpu', 'memory', 'io')},
           'thermal_millidegree_c': {p.parent.name: read(p) for p in
                                   Path('/sys/class/thermal').glob('thermal_zone*/temp')},
           'mem_sleep': read('/sys/power/mem_sleep'),
           'qcrypto_loaded': Path('/sys/module/qcrypto').exists(),
           'sessions': locked, 'drm_dpms': dpms or {'unavailable': 'no DRM dpms ABI'},
           'wifi_operstate': wifi, 'fprintd_service': fingerprint}
    row['collection_ns'] = time.monotonic_ns() - started
    return row


def segments(directory):
    return sorted(p for p in directory.iterdir() if NAME.fullmatch(p.name)
                  and p.is_file() and not p.is_symlink())


def last_record(paths):
    for path in reversed(paths):
        with path.open('rb') as stream:
            stream.seek(max(0, path.stat().st_size - 3 * LINE))
            lines = stream.read().splitlines()
        for line in reversed(lines):
            try:
                row = json.loads(line)
                if (row.get('schema') == 1 and isinstance(row.get('seq'), int)
                        and row.get('seq', 0) > 0 and isinstance(row.get('boot_id'), str)):
                    return row
            except (ValueError, AttributeError):
                pass
    return None


def append(directory, row, segment=SEGMENT, total=TOTAL, reserve=RESERVE):
    """Bound only our numbered files. Check free space before deleting anything.

    A torn tail stays in place, delimited from the next record by a newline;
    readers skip it and report it. Sequence recovery never uses wall time/mtime.
    """
    directory = Path(directory)
    if directory.is_symlink():
        raise RuntimeError('refusing symlink state directory')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    with (directory / '.lock').open('a') as lock:
        os.chmod(directory / '.lock', 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if shutil.disk_usage(directory).free < reserve:
            raise RuntimeError('low space: stopped without deleting logs')
        paths = segments(directory)
        previous = last_record(paths)
        boot = row['boot_id']
        if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', boot):
            raise ValueError('invalid boot ID')
        same_boot = previous is not None and previous['boot_id'] == boot
        row = dict(row, seq=previous['seq'] + 1 if same_boot else 1)
        if not same_boot:
            row['identity'] = identity()
            row['previous_boot_id'] = previous['boot_id'] if previous else None
        raw = (json.dumps(row, separators=(',', ':'), sort_keys=True) + '\n').encode()
        if len(raw) > min(LINE, segment, total):
            raise ValueError('sample exceeds line/segment/quota limit')
        path = paths[-1] if paths else None
        newline = b''
        if path and path.stat().st_size:
            with path.open('rb') as stream:
                stream.seek(-1, 2)
                if stream.read(1) != b'\n':
                    newline = b'\n'
        if (path is None or NAME.fullmatch(path.name)[2] != boot
                or path.stat().st_size + len(newline) + len(raw) > segment):
            number = int(NAME.fullmatch(paths[-1].name)[1]) + 1 if paths else 1
            path = directory / f'sample-{number:020d}-{boot}.jsonl'
            newline = b''
        used = sum(p.stat().st_size for p in paths)
        needed = len(newline) + len(raw)
        while paths and used + needed > total:
            oldest = paths.pop(0)
            # Never truncate an active segment to satisfy a misconfigured quota.
            if oldest == path:
                raise RuntimeError('quota too small for current segment')
            used -= oldest.stat().st_size
            oldest.unlink()
        # No fsync or journal copying in the sampling path; existing sync policy applies.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, 'ab') as stream:
                stream.write(newline + raw)
        except BaseException:
            # fdopen owns fd once constructed.
            raise
        return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('/var/lib/liuqin-daily-log'))
    parser.add_argument('--stdout', action='store_true', help='one read-only sample; no state write')
    args = parser.parse_args()
    os.umask(0o077)
    row = collect()
    if args.stdout:
        row['identity'] = identity()
    else:
        row = append(args.directory, row)
    print(json.dumps(row, separators=(',', ':')))


if __name__ == '__main__':
    main()
