#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Save a conservative time floor for systemd PID1; never set clocks or RTCs.

chronyd remains the NTP client. A same-boot CLOCK_BOOTTIME anchor permits
bounded holdover on shutdown without trusting a manually changed wall clock.
Paths cannot be changed through CLI/environment; tests inject private fixtures.
"""
import argparse
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time

SECOND = 1_000_000_000
MIN_EPOCH = 1_577_836_800 * SECOND  # 2020-01-01, sanity only, not a clock source.
MAX_HOLDOVER = 7 * 24 * 3600 * SECOND
OWNER = 0
GROUP = 0


@dataclass(frozen=True)
class Paths:
    epoch: Path = Path('/usr/lib/clock-epoch')
    runtime: Path = Path('/run/liuqin-clock')
    boot_id: Path = Path('/proc/sys/kernel/random/boot_id')


def check_stat(info, *, directory=False):
    kind_ok = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if (not kind_ok or info.st_uid != OWNER or info.st_gid != GROUP
            or info.st_mode & 0o022 or (not directory and info.st_nlink != 1)):
        raise ValueError('expected root-owned, non-group/world-writable regular file/directory')


def open_safe(path, flags, mode=0o600):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, mode)
    try:
        check_stat(os.fstat(fd))
    except Exception:
        os.close(fd)
        raise
    return fd


def sample():
    return time.time_ns(), time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def chrony_synced():
    # Explicit Unix socket: no DNS, UDP fallback, NTP traffic, or chrony changes.
    try:
        result = subprocess.run(
            ['/usr/bin/chronyc', '-u', 'root', '-n', '-h', '/run/chrony/chronyd.sock',
             'waitsync', '1', '0.5', '0', '0'],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=3, check=False,
            env={'LC_ALL': 'C', 'PATH': '/usr/sbin:/usr/bin'},
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def load_anchor(path):
    try:
        fd = open_safe(path, os.O_RDONLY)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'r') as f:
        if os.fstat(f.fileno()).st_size > 1024:
            raise ValueError('oversized anchor')
        try:
            data = json.load(f)
        except (ValueError, UnicodeError) as exc:
            raise ValueError('invalid anchor JSON') from exc
    if (not isinstance(data, dict) or data.get('version') != 1
            or not isinstance(data.get('boot_id'), str)
            or type(data.get('epoch_ns')) is not int
            or type(data.get('boottime_ns')) is not int
            or data['epoch_ns'] < MIN_EPOCH or data['boottime_ns'] < 0):
        raise ValueError('invalid anchor fields')
    return data


def store_anchor(path, anchor):
    fd, name = tempfile.mkstemp(prefix='.anchor-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(anchor, f, sort_keys=True)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save(paths=Paths(), *, require_sync=False, sync_check=chrony_synced, clock=sample):
    check_stat(paths.runtime.lstat(), directory=True)
    lock_fd = open_safe(paths.runtime / 'lock', os.O_CREAT | os.O_RDWR)
    try:
        # A timer and shutdown must not update the timestamp concurrently.
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        boot_id = paths.boot_id.read_text().strip()
        wall_before, boot_before = clock()
        synced = sync_check()
        wall, boot = clock()
        stable = abs((wall - wall_before) - (boot - boot_before)) <= SECOND
        anchor_path = paths.runtime / 'anchor.json'
        anchor = None
        if synced and stable and wall >= MIN_EPOCH:
            # waitsync requires <=0.5 s remaining correction; subtract 1 s.
            candidate = wall - SECOND
            anchor = {'version': 1, 'boot_id': boot_id,
                      'epoch_ns': candidate, 'boottime_ns': boot}
            source = 'chrony'
        else:
            if require_sync:
                raise ValueError('chronyd is not synchronised or wall clock changed during check')
            old = load_anchor(anchor_path)
            elapsed = boot - old['boottime_ns'] if old and old['boot_id'] == boot_id else -1
            if not 0 <= elapsed <= MAX_HOLDOVER:
                return {'status': 'skipped', 'reason': 'no valid same-boot time anchor'}
            candidate = old['epoch_ns'] + elapsed
            source = 'holdover'

        # The administrator creates this empty file during explicit activation.
        # Never create it in a read-only /usr sandbox and never replace a bind mount.
        fd = open_safe(paths.epoch, os.O_RDWR)
        try:
            info = os.fstat(fd)
            if info.st_size != 0:
                raise ValueError('clock-epoch is not empty; refusing an unknown file')
            if info.st_mtime_ns > candidate + 5 * SECOND:
                raise ValueError('clock-epoch is ahead of trusted time; manual review required')
            target = max(candidate, info.st_mtime_ns)
            os.utime(fd, ns=(info.st_atime_ns, target))
            os.fsync(fd)
            if os.fstat(fd).st_mtime_ns != target:
                raise OSError('clock-epoch mtime readback mismatch')
        finally:
            os.close(fd)
        if anchor is not None:
            store_anchor(anchor_path, anchor)
        return {'status': 'saved', 'source': source, 'epoch_ns': target}
    finally:
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-sync', action='store_true',
                        help='fail without a fresh chronyd sync (initial activation)')
    args = parser.parse_args()
    if os.geteuid() != OWNER:
        parser.error('must run as root')
    try:
        result = save(require_sync=args.require_sync)
    except (OSError, ValueError) as exc:
        print(json.dumps({'status': 'error', 'reason': str(exc)}), flush=True)
        return 1
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
