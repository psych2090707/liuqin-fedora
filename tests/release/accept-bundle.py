#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline acceptance test for a real liuqin Fedora bundle.

TEST-ONLY HARNESS: the single *project* bundle verifier is
``scripts/verify-bundle.sh`` (single-producer rule).  This runner is kept as a release tooling
test harness for release-asset packaging checks and must not be treated as a
second production verifier; the delivery gate evidence comes from
scripts/verify-bundle.sh.

This is the end-to-end acceptance runner: it takes an assembled bundle
directory (``images/<name>/``: boot.img, installer.img, root.img,
rootfs.tar.gz, bundle.json, SHA256SUMS, manifests/, VERIFICATION.md,
LICENSE, NOTICE) and verifies everything that can be verified without a
tablet:

  A  bundle layout, SHA256SUMS, bundle.json identity and manifest digests
  B  installer/install.py local check + a full --dry-run with the PATH-injected
     fake Fastboot simulator (no device, no writes)
  C  kernel release chain: bundle.json <-> root.img (flat root) <-> rootfs.tar.gz
     <-> manifests/kernel-modules.manifest <-> kernel source lock
  D  root.img content: e2fsck, ext4 label/block size, FLAT layout (flat install contract),
     os-release, fstab labels, plasmalogin display manager, release-gate
     prerequisite files, aarch64-only ELF scan (fuse2fs, read-only), package list
  E  boot.img structure: Android header v2, 192 MiB limit, ramdisk initramfs
     entries and the embedded Fedora root admission contract v2
  F  installer.img structure: RAM-installer marker and device-side tools
  G  bundle verification artifacts, historical validation record, and the project
     verifier script (dev result plus expected release-gate FAILs)

Never touches a device: no fastboot/adb against hardware, no /dev block
device writes, read-only mounts of image files only.  Files are only written
below --out (default out/bundle-acceptance/<bundle-name>/).

Exit codes: 0 = offline acceptance passed, 1 = at least one acceptance check
failed, 2 = usage/environment error.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[2]
INSTALLER = PROJECT / 'installer'
FAKE_FASTBOOT = PROJECT / 'tests/installer/fake-fastboot'
VERIFY_BUNDLE = PROJECT / 'scripts/verify-bundle.sh'
BOOT_PARTITION_BYTES = 201326592  # pinned 192 MiB boot partition
BUNDLE_PAYLOAD = ('boot.img', 'installer.img', 'rootfs.tar.gz')
REQUIRED_FILES = BUNDLE_PAYLOAD + ('root.img', 'bundle.json', 'SHA256SUMS',
                                   'VERIFICATION.md', 'LICENSE', 'NOTICE')
REQUIRED_DIRS = ('manifests',)
ENVIRONMENT = dict(os.environ, LC_ALL='C', LANG='C')
ELF_MACHINES = {0xB7: 'aarch64', 0x3E: 'x86_64', 0x03: 'i386', 0x28: 'arm'}


def sha256_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(command, timeout=600, env=None, cwd=None):
    """Run a command; never raises for a nonzero status."""
    try:
        return subprocess.run([str(item) for item in command], capture_output=True,
                              text=True, timeout=timeout, env=env or ENVIRONMENT, cwd=cwd)
    except (OSError, subprocess.SubprocessError) as error:
        return subprocess.CompletedProcess([str(item) for item in command], 127,
                                           '', f'{type(error).__name__}: {error}')


def read_elf_machine(stream):
    head = stream.read(20)
    if len(head) < 20 or head[:4] != b'\x7fELF':
        return None
    return int.from_bytes(head[18:20], 'little')


def parse_boot_image(path):
    """The header fields an Android boot image v2 actually carries."""
    with path.open('rb') as stream:
        page = stream.read(4096)
    if len(page) < 4096 or page[:8] != b'ANDROID!':
        return None

    def u32(offset):
        return int.from_bytes(page[offset:offset + 4], 'little')

    return {
        'header_version': u32(40),
        'kernel_size': u32(8),
        'ramdisk_size': u32(16),
        'second_size': u32(24),
        'page_size': u32(36),
        'header_size': u32(1644),
        'dtb_size': u32(1648),
        'header_cmdline': page[608:608 + 512].split(b'\0', 1)[0].decode(errors='replace'),
        'bytes': path.stat().st_size,
    }


def read_ramdisk(path, header):
    """The decompressed initramfs bytes of a v2 boot image."""
    page = header['page_size']
    with path.open('rb') as stream:
        stream.seek(page * (1 + -(-header['kernel_size'] // page)))
        raw = stream.read(header['ramdisk_size'])
    return gzip.decompress(raw)


def parse_cpio(data):
    """Minimal newc cpio reader: name -> bytes (bounded, no path traversal)."""
    entries = {}
    offset = 0
    limit = min(len(data), 512 * 1024 * 1024)
    while offset + 110 <= limit:
        header = data[offset:offset + 110]
        if header[:6] not in (b'070701', b'070702'):
            raise ValueError('not a newc cpio archive at offset ' + str(offset))
        fields = [int(header[6 + index * 8:6 + (index + 1) * 8], 16) for index in range(13)]
        file_size = fields[6]
        name_size = fields[11]
        name = data[offset + 110:offset + 110 + name_size - 1].decode(errors='replace')
        offset = (offset + 110 + name_size + 3) & ~3
        if name == 'TRAILER!!!':
            break
        if name in ('.', './'):
            key = '/'
        elif name.startswith('./'):
            key = '/' + name[2:]
        elif name.startswith('/'):
            key = name
        else:
            key = '/' + name
        entries[key] = data[offset:offset + file_size]
        offset = (offset + file_size + 3) & ~3
    return entries


def debugfs(image, command, timeout=300):
    return run(['debugfs', '-R', command, image], timeout=timeout)


def debugfs_cat(image, path):
    result = debugfs(image, 'cat ' + path)
    text = result.stdout
    if result.stderr and 'File not found' in result.stderr:
        return None
    if result.returncode != 0 and not text:
        return None
    return text


def debugfs_stat(image, path):
    result = debugfs(image, 'stat ' + path)
    if 'File not found' in (result.stderr + result.stdout):
        return None
    return result.stdout + result.stderr


def parse_symlink_target(stat_output):
    match = re.search(r'Fast link dest: "([^"]+)"', stat_output or '')
    return match.group(1) if match else None


class Report:
    def __init__(self):
        self.rows = []

    def add(self, section, ident, status, detail):
        self.rows.append({'section': section, 'id': ident, 'status': status, 'detail': detail})
        line = f'[{status}] {ident}: {detail}'
        print(line, flush=True)

    def ok(self, section, ident, condition, detail):
        self.add(section, ident, 'PASS' if condition else 'FAIL', detail)
        return condition

    def warn(self, section, ident, detail):
        self.add(section, ident, 'WARN', detail)

    def skip(self, section, ident, detail):
        self.add(section, ident, 'SKIP', detail)

    def info(self, section, ident, detail):
        self.add(section, ident, 'INFO', detail)

    def counts(self):
        counts = {'PASS': 0, 'FAIL': 0, 'WARN': 0, 'SKIP': 0, 'INFO': 0}
        for row in self.rows:
            counts[row['status']] += 1
        return counts

    def render_markdown(self, manifest_data):
        lines = [
            '# liuqin Fedora bundle — offline acceptance report',
            '',
            f'- bundle: `{manifest_data["bundle"]}`',
            f'- generated: `{manifest_data["generated"]}`',
            f'- host: `{manifest_data["host"]}`',
            f'- verdict: **{manifest_data["verdict"]}**',
            f'- install candidate: **{manifest_data["phase6_candidate"]}**',
            f'- device_ready: `{manifest_data["device_ready"]}`',
            '',
        ]
        if manifest_data.get('device_ready_reasons'):
            lines += ['## bundle.json device_ready_reasons', '']
            lines += [f'- {reason}' for reason in manifest_data['device_ready_reasons']]
            lines += ['']
        lines += ['## Checks', '', '| id | status | detail |', '|---|---|---|']
        for row in self.rows:
            detail = row['detail'].replace('|', '\\|').replace('\n', ' ')
            lines.append(f'| {row["id"]} | {row["status"]} | {detail} |')
        counts = self.counts()
        lines += ['', '## Counts', '',
                  f'PASS {counts["PASS"]} / WARN {counts["WARN"]} / FAIL {counts["FAIL"]} / '
                  f'SKIP {counts["SKIP"]} / INFO {counts["INFO"]}', '']
        lines += ['## What this report does NOT prove', '',
                  '- No tablet was connected: Fastboot/flash/USB-NCM/ABL/AVB behaviour is unverified.',
                  '- `device_ready=false` bundles are workflow rehearsals, not hardware candidates.',
                  '- qemu user-space boot (if recorded) does not validate liuqin hardware.',
                  '']
        return '\n'.join(lines)


def section_a_layout(report, bundle, bundle_json):
    section = 'A bundle'
    missing = [name for name in REQUIRED_FILES if not (bundle / name).is_file()]
    missing += [name for name in REQUIRED_DIRS if not (bundle / name).is_dir()]
    report.ok(section, 'A1 bundle layout', not missing,
              'all required files present' if not missing else 'missing: ' + ', '.join(missing))

    sums = bundle / 'SHA256SUMS'
    if not sums.is_file():
        return
    listed = {}
    bad = []
    for line in sums.read_text(errors='replace').splitlines():
        if not line.strip():
            continue
        digest, _, name = line.partition('  ')
        name = name.strip()
        if name.startswith('./'):
            name = name[2:]
        if len(digest) != 64 or not name:
            bad.append('malformed line: ' + line[:80])
            continue
        listed[name] = digest
        target = bundle / name
        if not target.is_file():
            bad.append('missing: ' + name)
        elif sha256_file(target) != digest:
            bad.append('sha256 mismatch: ' + name)
    unlisted = [name for name in REQUIRED_FILES
                if name not in listed and name != 'SHA256SUMS' and (bundle / name).is_file()]
    report.ok(section, 'A2 SHA256SUMS', not bad and not unlisted,
              f'{len(listed)} files verified' if not bad and not unlisted
              else '; '.join(bad[:5] + (['unlisted: ' + ', '.join(unlisted)] if unlisted else [])))

    files = bundle_json.get('files', {}) if isinstance(bundle_json, dict) else {}
    mismatched = []
    for name in BUNDLE_PAYLOAD:
        actual = bundle / name
        if not actual.is_file():
            continue
        declared = files.get(name)
        if declared is not None and declared != sha256_file(actual):
            mismatched.append(name)
    report.ok(section, 'A3 bundle.json file hashes', not mismatched,
              'bundle.json.files matches the payload' if not mismatched
              else 'mismatch: ' + ', '.join(mismatched))

    identity = (isinstance(bundle_json, dict) and bundle_json.get('device') == 'liuqin'
                and isinstance(bundle_json.get('kernel_release'), str)
                and bool(bundle_json.get('kernel_release').strip()))
    report.ok(section, 'A4 bundle identity', identity,
              'device=liuqin kernel_release=' + str(bundle_json.get('kernel_release'))
              if identity else 'device/kernel_release invalid')

    fedora = bundle_json.get('fedora') or {}
    report.ok(section, 'A5 Fedora extension', fedora.get('contract') ==
              '/etc/liuqin-fedora-root.contract' and
              fedora.get('contract_version', 2) == 2,
              'contract=' + str(fedora.get('contract')) +
              ' version=' + str(fedora.get('contract_version')))
    exit_value = bundle_json.get('status')
    report.info(section, 'A6 bundle status', 'status=' + str(exit_value) +
                ' offline_only=' + str(bundle_json.get('offline_only')) +
                ' device_ready=' + str(bundle_json.get('device_ready')))
    reasons = bundle_json.get('device_ready_reasons') or []
    report.info(section, 'A7 device_ready reasons', str(len(reasons)) + ' recorded reasons')
    redistribution = str(bundle_json.get('redistribution'))
    report.info(section, 'A8 redistribution', redistribution)
    notice = bundle / 'NOTICE'
    licence = bundle / 'LICENSE'
    firmware_clause = False
    if notice.is_file():
        firmware_clause = bool(re.search(r'firmware.*(not|no).*(redistribut|distribut)',
                                         notice.read_text(errors='replace'), re.I | re.S))
    report.ok(section, 'A9 licence/firmware notice', licence.is_file() and notice.is_file()
              and firmware_clause,
              'LICENSE+NOTICE present, firmware non-redistribution clause found'
              if firmware_clause else
              'LICENSE/NOTICE present but no firmware redistribution clause found')

    # manifest digest cross-references
    manifests = bundle / 'manifests'
    rootfs_manifest = manifests / 'rootfs.files.sha256'
    declared = fedora.get('rootfs_manifest')
    if declared and rootfs_manifest.is_file():
        report.ok(section, 'A10 rootfs manifest digest',
                  sha256_file(rootfs_manifest) == declared,
                  'fedora.rootfs_manifest matches manifests/rootfs.files.sha256')
    elif declared:
        report.warn(section, 'A10 rootfs manifest digest',
                    'fedora.rootfs_manifest recorded but manifests/rootfs.files.sha256 absent')
    else:
        report.warn(section, 'A10 rootfs manifest digest', 'bundle.json has no fedora.rootfs_manifest')


def section_b_installer(report, bundle, out, simulator_path):
    section = 'B installer'
    python = sys.executable
    check = run([python, INSTALLER / 'install.py', '--bundle', bundle, '--check',
                 '--layout', 'linux-only'])
    (out / 'install-check.log').write_text(check.stdout + check.stderr)
    report.ok(section, 'B1 install.py --check', check.returncode == 0 and
              'Local bundle checksums verified' in check.stdout,
              f'rc={check.returncode}')

    fakebin = out / 'fake-fastboot-bin'
    fakebin.mkdir(exist_ok=True)
    simulator = fakebin / 'fastboot'
    shutil.copyfile(simulator_path, simulator)
    simulator.chmod(0o755)
    fixture = out / 'device.fixture'
    fixture.write_text(
        'product=liuqin\nunlocked=yes\nserial=TEST_SERIAL\ncurrent-slot=a\n'
        f'userdata=0x1000000000\nboot_a={hex(BOOT_PARTITION_BYTES)}\n'
        f'boot_b={hex(BOOT_PARTITION_BYTES)}\nmax-download-size=0x30000000\n')
    log = out / 'fastboot.log'
    if log.exists():
        log.unlink()
    backup = out / 'dry-run-backup'
    env = dict(ENVIRONMENT, PATH=str(fakebin) + os.pathsep + ENVIRONMENT.get('PATH', ''),
               FAKE_FASTBOOT_LOG=str(log), FAKE_FASTBOOT_FIXTURE=str(fixture))
    before = {name: sha256_file(bundle / name) for name in REQUIRED_FILES
              if (bundle / name).is_file()}
    dry = run([python, INSTALLER / 'install.py', '--bundle', bundle,
               '--serial', 'TEST_SERIAL', '--backup', backup, '--erase-userdata',
               '--layout', 'linux-only', '--allow-unverified', '--yes', '--dry-run'],
              timeout=900, env=env)
    (out / 'install-dry-run.log').write_text(dry.stdout + dry.stderr)
    completed = dry.returncode == 0 and 'DRY-RUN COMPLETE' in dry.stdout
    report.ok(section, 'B2 install.py --dry-run', completed, f'rc={dry.returncode}')
    if completed:
        facts = {
            'padded boot digest': bool(re.search(r'sha256 [0-9a-f]{64}', dry.stdout)),
            'layout plan': 'linux_root' in dry.stdout and 'linux_home' in dry.stdout,
            'RAM install command': 'install-root.sh' in dry.stdout,
            'fastboot boot step': 'fastboot -s TEST_SERIAL boot ' in dry.stdout,
            'fastboot tail (flash boot_b/set-active)':
                'flash boot_b ' in dry.stdout and '--set-active=b' in dry.stdout,
            'kernel_release check': str(json.loads((bundle / 'bundle.json').read_text())
                                        .get('kernel_release')) in dry.stdout,
        }
        report.ok(section, 'B3 dry-run write sequence', all(facts.values()),
                  '; '.join(f'{name}={"yes" if value else "NO"}'
                            for name, value in facts.items()))
        expected_padded = hashlib.sha256(
            (bundle / 'boot.img').read_bytes() +
            bytes(BOOT_PARTITION_BYTES - (bundle / 'boot.img').stat().st_size)).hexdigest()
        report.ok(section, 'B4 zero-filled boot digest',
                  expected_padded in dry.stdout, 'padded sha256 ' + expected_padded)
        if log.is_file():
            commands = []
            for line in log.read_text().splitlines():
                tokens = line.split()
                if tokens[:1] == ['-s']:
                    tokens = tokens[2:]
                commands.append(tokens[0] if tokens else '')
            writes = [command for command in commands
                      if command in ('flash', 'boot', 'erase', 'format', 'reboot')
                      or command.startswith('--set-active')]
            report.ok(section, 'B5 dry-run executed no write',
                      not writes and all(command == 'getvar' for command in commands),
                      f'{len(commands)} read-only Fastboot calls' if not writes
                      else 'writes executed: ' + ', '.join(writes))
        else:
            report.ok(section, 'B5 dry-run executed no write', False,
                      'fastboot simulator was never called (expected read-only getvar calls)')
        report.ok(section, 'B6 dry-run created no backup',
                  not backup.exists(), 'backup directory not created')

    after = {name: sha256_file(bundle / name) for name in REQUIRED_FILES
             if (bundle / name).is_file()}
    report.ok(section, 'B7 bundle unchanged by the rehearsal', before == after,
              'bundle payload hashes unchanged')

    default = run([python, INSTALLER / 'install.py', '--bundle', bundle],
                  timeout=300, env=ENVIRONMENT)
    report.ok(section, 'B8 default mode is local-only', default.returncode == 0 and
              'Default mode: local checks only' in default.stdout,
              f'rc={default.returncode}')

    write_gate = run([python, INSTALLER / 'install.py', '--bundle', bundle,
                      '--serial', 'TEST_SERIAL', '--layout', 'linux-only',
                      '--check', '--yes-write-device'], timeout=300, env=ENVIRONMENT)
    report.ok(section, 'B9 write gate refuses --check + device writes',
              write_gate.returncode != 0 and 'never accesses a device' in write_gate.stderr,
              f'rc={write_gate.returncode}')


def section_c_kernel(report, bundle, bundle_json):
    section = 'C kernel release'
    release = str(bundle_json.get('kernel_release') or '')
    root_img = bundle / 'root.img'
    if not root_img.is_file():
        report.skip(section, 'C1 root.img kernel release', 'root.img absent')
    else:
        embedded = debugfs_cat(root_img, '/usr/share/liuqin/kernel.release')
        embedded = embedded.strip() if embedded else ''
        report.ok(section, 'C1 root.img kernel release', embedded == release,
                  f'root.img has {embedded!r}, bundle.json has {release!r}')
        modules = debugfs(root_img, 'ls -l /usr/lib/modules')
        report.ok(section, 'C2 root.img kernel modules',
                  modules.returncode == 0 and release in modules.stdout,
                  '/usr/lib/modules/' + release + ' present'
                  if release in (modules.stdout or '') else 'module directory missing')

    tarball = bundle / 'rootfs.tar.gz'
    if not tarball.is_file():
        report.skip(section, 'C3 rootfs.tar.gz kernel release', 'rootfs.tar.gz absent')
    else:
        entry = run(['tar', '-xOzf', tarball, './usr/share/liuqin/kernel.release'], timeout=900)
        value = (entry.stdout or '').strip()
        report.ok(section, 'C3 rootfs.tar.gz kernel release', value == release,
                  f'tar has {value!r}, bundle.json has {release!r}')

    modules_manifest = bundle / 'manifests/kernel-modules.manifest'
    if modules_manifest.is_file():
        lines = [line for line in modules_manifest.read_text(errors='replace').splitlines()
                 if line.strip()]
        matches = [line for line in lines if f'/usr/lib/modules/{release}/' in line]
        report.ok(section, 'C4 kernel modules manifest',
                  len(matches) >= 100, f'{len(matches)} .ko entries for {release}')
    else:
        report.warn(section, 'C4 kernel modules manifest', 'manifests/kernel-modules.manifest absent')

    build_info = bundle / 'manifests/image-build-info.json'
    if build_info.is_file():
        try:
            info = json.loads(build_info.read_text())
        except ValueError:
            info = {}
        recorded = json.dumps(info)
        report.ok(section, 'C5 image build info release',
                  release in recorded, 'kernel release appears in image-build-info.json'
                  if release in recorded else 'kernel release not recorded in build info')
    else:
        report.warn(section, 'C5 image build info', 'manifests/image-build-info.json absent')

    source_lock = PROJECT / 'kernel/source.json'
    commit = str(bundle_json.get('kernel_commit') or '')
    if source_lock.is_file() and commit:
        lock = json.loads(source_lock.read_text())
        report.ok(section, 'C6 kernel source lock', lock.get('commit') == commit,
                  f'bundle commit {commit[:12]} matches kernel/source.json')
    else:
        report.warn(section, 'C6 kernel source lock', 'no kernel_commit/source.json to compare')


def section_d_root_img(report, bundle, bundle_json, out):
    section = 'D root.img'
    image = bundle / 'root.img'
    if not image.is_file():
        report.add(section, 'D1 root.img', 'FAIL', 'root.img is missing from the bundle')
        return
    fsck = run(['e2fsck', '-fn', image], timeout=1800)
    (out / 'e2fsck-root.log').write_text(fsck.stdout + fsck.stderr)
    report.ok(section, 'D1 e2fsck clean', fsck.returncode == 0, f'rc={fsck.returncode}')
    header = run(['dumpe2fs', '-h', image], timeout=300)
    label = re.search(r'Filesystem volume name:\s*(\S+)', header.stdout or '')
    block = re.search(r'Block size:\s*(\d+)', header.stdout or '')
    report.ok(section, 'D2 ext4 label/block size',
              bool(label) and label.group(1) == 'LIUQIN_ROOT' and bool(block)
              and block.group(1) == '4096',
              f'label={label.group(1) if label else None} block={block.group(1) if block else None}')

    root_ls = debugfs(image, 'ls -l /')
    root_names = (root_ls.stdout or '')
    report.ok(section, 'D3 flat layout (flat install contract)',
              'native-root' not in root_names and 'etc' in root_names and 'usr' in root_names,
              'LIUQIN_ROOT root IS the rootfs root (/etc, /usr at the image root; no native-root/)')
    marker = debugfs_cat(image, '/etc/liuqin-fedora-root')
    report.ok(section, 'D4 Fedora root marker',
              (marker or '').strip() == 'liuqin-fedora-root-v1',
              'marker content ' + repr((marker or '').strip()))

    os_release = debugfs_cat(image, '/etc/os-release') or ''
    release = str((bundle_json.get('fedora') or {}).get('release', ''))
    report.ok(section, 'D5 os-release', 'ID=fedora' in os_release and
              (f'VERSION_ID={release}' in os_release or release == ''),
              'ID=fedora VERSION_ID=' + release)

    fstab = debugfs_cat(image, '/etc/fstab') or ''
    report.ok(section, 'D6 fstab label',
              'LABEL=LIUQIN_HOME' in fstab and '/home' in fstab,
              '/etc/fstab mounts /home by LABEL=LIUQIN_HOME')

    dm = debugfs_stat(image, '/etc/systemd/system/display-manager.service')
    target = parse_symlink_target(dm)
    contract = debugfs_cat(image, '/etc/liuqin/image-contract') or ''
    report.ok(section, 'D7 display manager',
              bool(target) and ('plasmalogin' in target or 'sddm' in target) and
              ('plasmalogin' in contract or 'sddm' in contract),
              f'display-manager.service -> {target}; /etc/liuqin/image-contract says '
              f'{contract.strip()[:80]!r}')

    lock_manifest = debugfs(image, 'stat /usr/share/liuqin/rootfs.files.sha256')
    lock_size = re.search(r'Size:\s*(\d+)', (lock_manifest.stdout or '') + (lock_manifest.stderr or ''))
    report.ok(section, 'D8 shipped rootfs.files.sha256',
              bool(lock_size) and int(lock_size.group(1)) > 1024 * 1024,
              'release-gate prerequisite present inside the image'
              if lock_size else 'missing /usr/share/liuqin/rootfs.files.sha256')

    packages = bundle / 'manifests/rootfs.packages.txt'
    if packages.is_file():
        names = {line.split('\t')[0] for line in packages.read_text(errors='replace').splitlines()
                 if line.strip()}
        wanted = {'fedora-release', 'plasma-workspace', 'plasmalogin', 'systemd',
                  'NetworkManager', 'kwin'}
        found = {name for name in wanted if any(name == package or
                                                package.startswith(name + '-')
                                                for package in names)}
        report.ok(section, 'D9 RPM package list',
                  len(names) > 500 and len(found) >= 4,
                  f'{len(names)} packages, found {sorted(found)}')
    else:
        report.warn(section, 'D9 RPM package list', 'manifests/rootfs.packages.txt absent')

    private = debugfs_stat(image, '/var/lib/liuqin-private')
    report.ok(section, 'D10 no device-private data', private is None,
              'no /var/lib/liuqin-private (device data must come from the tablet persist)'
              if private is None else 'device-private data found in the image')

    # aarch64-only ELF scan over rootfs.tar.gz (the same tree the installer
    # extracts).  A streaming tar read is used on purpose: mounting root.img,
    # even read-only through fuse2fs, rewrites its superblock on unmount, and an
    # acceptance run must leave the bundle byte-identical.
    tarball = bundle / 'rootfs.tar.gz'
    if not tarball.is_file():
        report.skip(section, 'D11 aarch64-only ELF scan', 'rootfs.tar.gz absent')
        return
    try:
        scan = scan_elfs_in_tar(tarball, out / 'arch-scan.txt')
    except Exception as error:
        report.skip(section, 'D11 aarch64-only ELF scan',
                    'tar scan failed: ' + type(error).__name__ + ': ' + str(error)[:200])
        return
    report.ok(section, 'D11 aarch64-only ELF scan', scan['x86_64'] == 0 and scan['aarch64'] > 0,
              f'{scan["files"]} files, aarch64={scan["aarch64"]} x86_64={scan["x86_64"]} '
              f'other={scan["other"]}' +
              ('; x86_64 files: ' + ', '.join(scan['examples'][:5]) if scan['x86_64'] else ''))
    if scan['aarch64'] < 1000:
        report.warn(section, 'D11b ELF sample size',
                    f'only {scan["aarch64"]} aarch64 ELFs found; a full KDE rootfs should be larger')
    if scan['deadline']:
        report.warn(section, 'D11c scan deadline', 'tar scan hit its deadline; partial result')


def scan_elfs_in_tar(tarball, log_path, deadline_seconds=900):
    """Count ELF classes in a rootfs tar.gz without extracting it to disk."""
    import tarfile
    counts = {'files': 0, 'aarch64': 0, 'x86_64': 0, 'other': 0, 'examples': [], 'deadline': False}
    started = time.monotonic()
    with tarfile.open(tarball, mode='r|gz') as archive:
        for member in archive:
            if not member.isfile():
                continue
            counts['files'] += 1
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            machine = read_elf_machine(extracted)
            if machine is None:
                continue
            name = ELF_MACHINES.get(machine, hex(machine))
            if machine == 0xB7:
                counts['aarch64'] += 1
            elif machine == 0x3E:
                counts['x86_64'] += 1
                if len(counts['examples']) < 20:
                    counts['examples'].append(member.name)
            else:
                counts['other'] += 1
            if time.monotonic() - started > deadline_seconds:
                counts['deadline'] = True
                break
    log = [f'files scanned: {counts["files"]}', f'aarch64: {counts["aarch64"]}',
           f'x86_64: {counts["x86_64"]}', f'other ELF machines: {counts["other"]}']
    log += ['x86_64: ' + name for name in counts['examples']]
    log_path.write_text('\n'.join(log) + '\n')
    return counts


def section_e_boot(report, bundle):
    section = 'E boot.img'
    path = bundle / 'boot.img'
    if not path.is_file():
        report.add(section, 'E1 boot.img', 'FAIL', 'boot.img is missing')
        return
    header = parse_boot_image(path)
    if header is None:
        report.add(section, 'E1 boot header', 'FAIL', 'not an Android boot image (ANDROID! magic)')
        return
    checks = {
        'header v2': header['header_version'] == 2,
        'page 4096': header['page_size'] == 4096,
        'header 1660': header['header_size'] == 1660,
        'kernel present': header['kernel_size'] > 0,
        'ramdisk present': header['ramdisk_size'] > 0,
        'dtb present': header['dtb_size'] > 0,
        'empty header cmdline': header['header_cmdline'] == '',
        'fits 192 MiB partition': header['bytes'] <= BOOT_PARTITION_BYTES,
    }
    report.ok(section, 'E1 boot header', all(checks.values()),
              ', '.join(f'{name}={"ok" if value else "NO"}' for name, value in checks.items()) +
              f'; {header["bytes"]} bytes')
    try:
        entries = parse_cpio(read_ramdisk(path, header))
    except (OSError, ValueError, gzip.BadGzipFile) as error:
        report.add(section, 'E2 boot ramdisk', 'FAIL', 'cannot unpack ramdisk: ' + str(error))
        return
    wanted = {'/init', '/bin/busybox', '/etc/liuqin-fedora-root.contract'}
    present = {name for name in entries if name in wanted}
    report.ok(section, 'E2 boot ramdisk', present == wanted,
              f'{len(entries)} entries; found {sorted(present)}')
    contract = entries.get('/etc/liuqin-fedora-root.contract', b'')
    contract_lines = [line for line in contract.decode(errors='replace').splitlines()
                      if line.strip()]
    topology = [line for line in contract_lines[1:] if not line.lstrip().startswith('#')]
    content_pins = [line for line in topology if re.fullmatch(r'[0-9a-f]{64}  /\S+', line)]
    report.ok(section, 'E3 embedded contract v2',
              contract_lines[:1] == ['LIUQIN_FEDORA_ROOT_CONTRACT_V2']
              and len(topology) >= 8 and not content_pins,
              f'header={contract_lines[:1]!r} topology_entries={len(topology)} '
              f'content_pins={len(content_pins)} (topology contract)')
    report.ok(section, 'E4 boot size limit', header['bytes'] <= BOOT_PARTITION_BYTES,
              f'{header["bytes"]} <= {BOOT_PARTITION_BYTES}')


def section_f_installer(report, bundle):
    section = 'F installer.img'
    path = bundle / 'installer.img'
    if not path.is_file():
        report.add(section, 'F1 installer.img', 'FAIL', 'installer.img is missing')
        return
    header = parse_boot_image(path)
    if header is None:
        report.add(section, 'F1 installer header', 'FAIL', 'not an Android boot image')
        return
    report.ok(section, 'F1 installer header', header['header_version'] == 2 and
              header['page_size'] == 4096 and header['bytes'] <= BOOT_PARTITION_BYTES,
              f'header v2/page 4096, {header["bytes"]} bytes')
    try:
        entries = parse_cpio(read_ramdisk(path, header))
    except (OSError, ValueError, gzip.BadGzipFile) as error:
        report.add(section, 'F2 installer ramdisk', 'FAIL', 'cannot unpack ramdisk: ' + str(error))
        return
    wanted = {'/etc/liuqin-installer', '/usr/lib/liuqin/install-root.sh',
              '/usr/sbin/mkfs.ext4', '/usr/sbin/sgdisk', '/bin/busybox'}
    present = {name for name in entries if name in wanted}
    marker = entries.get('/etc/liuqin-installer', b'').strip()
    report.ok(section, 'F2 installer ramdisk', present == wanted and marker == b'liuqin',
              f'{len(entries)} entries; marker={marker!r}; found {sorted(present)}')
    report.ok(section, 'F3 installer storage mode',
              entries.get('/etc/liuqin-storage-mode', b'').strip() == b'readonly',
              'read-only RAM installer marker present')


def section_g_verification(report, bundle, bundle_json, out):
    section = 'G verification'
    verification = bundle / 'VERIFICATION.md'
    report.ok(section, 'G1 VERIFICATION.md',
              verification.is_file() and verification.stat().st_size > 500,
              f'{verification.stat().st_size if verification.is_file() else 0} bytes')
    qemu = bundle_json.get('qemu_validation')
    if qemu:
        report.info(section, 'G2 qemu user-space validation', json.dumps(qemu)[:400])
    else:
        report.info(section, 'G2 historical qemu validation', 'not required; VM simulation retired (retired VM plan)')

    if not VERIFY_BUNDLE.is_file():
        report.skip(section, 'G3 project verifier', 'scripts/verify-bundle.sh missing')
    else:
        dev_json = out / 'verify-bundle-dev.json'
        dev = run(['bash', VERIFY_BUNDLE, '--bundle', bundle, '--bundle-partial',
                   '--no-boot', '--no-rootfs', '--no-repo', '--advisory',
                   '--json', dev_json, '--quiet'], timeout=900)
        (out / 'verify-bundle-dev.log').write_text(dev.stdout + dev.stderr)
        report.info(section, 'G3 project verifier (dev)',
                    f'rc={dev.returncode}; report: {dev_json.name}')
        if dev_json.is_file():
            try:
                payload = json.loads(dev_json.read_text())
            except ValueError:
                payload = {}
            statuses = {}
            for check in payload.get('checks', []):
                statuses[check.get('status')] = statuses.get(check.get('status'), 0) + 1
            report.info(section, 'G4 verifier result', json.dumps(statuses))
            report.ok(section, 'G5 verifier bundle section has no FAIL',
                      statuses.get('FAIL', 0) == 0,
                      'dev verifier FAIL count=' + str(statuses.get('FAIL', 0)))

        gate_json = out / 'verify-bundle-release-gate.json'
        gate = run(['bash', VERIFY_BUNDLE, '--bundle', bundle, '--bundle-partial',
                    '--release-gate', '--advisory', '--json', gate_json, '--quiet'],
                   timeout=900)
        (out / 'verify-bundle-release-gate.log').write_text(gate.stdout + gate.stderr)
        gate_fails = 0
        if gate_json.is_file():
            try:
                payload = json.loads(gate_json.read_text())
            except ValueError:
                payload = {}
            gate_fails = sum(1 for check in payload.get('checks', [])
                             if check.get('status') == 'FAIL')
        report.info(section, 'G6 release gate on this bundle',
                    f'{gate_fails} FAIL checks (dev bundle expected to fail the gate)')
        report.ok(section, 'G7 release gate is effective for dev artifacts',
                  gate_fails > 0,
                  'gate reports FAIL for the offline dev bundle, as designed'
                  if gate_fails > 0 else 'gate unexpectedly passes a dev bundle')


def accept(bundle, out, skip_external=False, simulator=FAKE_FASTBOOT):
    bundle = bundle.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = Report()
    started = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    bundle_json = {}
    manifest_path = bundle / 'bundle.json'
    if manifest_path.is_file():
        try:
            bundle_json = json.loads(manifest_path.read_text())
        except ValueError:
            bundle_json = {}
    else:
        report.add('A bundle', 'A0 bundle.json', 'FAIL', 'bundle.json is missing')

    section_a_layout(report, bundle, bundle_json)
    if (bundle / 'bundle.json').is_file():
        try:
            section_b_installer(report, bundle, out, simulator)
        except Exception as error:  # keep the report complete on harness errors
            report.add('B installer', 'B0 harness', 'FAIL', f'{type(error).__name__}: {error}')
        try:
            section_c_kernel(report, bundle, bundle_json)
        except Exception as error:
            report.add('C kernel release', 'C0 harness', 'FAIL',
                       f'{type(error).__name__}: {error}')
        try:
            section_d_root_img(report, bundle, bundle_json, out)
        except Exception as error:
            report.add('D root.img', 'D0 harness', 'FAIL', f'{type(error).__name__}: {error}')
        try:
            section_e_boot(report, bundle)
        except Exception as error:
            report.add('E boot.img', 'E0 harness', 'FAIL', f'{type(error).__name__}: {error}')
        try:
            section_f_installer(report, bundle)
        except Exception as error:
            report.add('F installer.img', 'F0 harness', 'FAIL',
                       f'{type(error).__name__}: {error}')
        if not skip_external:
            try:
                section_g_verification(report, bundle, bundle_json, out)
            except Exception as error:
                report.add('G verification', 'G0 harness', 'FAIL',
                           f'{type(error).__name__}: {error}')

    counts = report.counts()
    device_ready = bool(bundle_json.get('device_ready'))
    reasons = bundle_json.get('device_ready_reasons') or []
    offline_only = bundle_json.get('offline_only')
    gate_ok = False
    if (out / 'verify-bundle-release-gate.json').is_file():
        gate_ok = True  # the gate was executed; its content is recorded
    phase6 = bool(device_ready and not offline_only and not reasons and
                  (bundle_json.get('status') == 'DEVICE_TESTED') and
                  (bundle_json.get('contract') or (bundle_json.get('fedora') or {}).get('contract')))
    verdict = 'OFFLINE_ACCEPTED' if counts['FAIL'] == 0 else 'OFFLINE_NOT_ACCEPTED'
    if counts['FAIL'] == 0 and not device_ready:
        verdict += ' (workflow rehearsal only: device_ready=false)'
    manifest = {
        'format': 'liuqin-bundle-acceptance/1',
        'bundle': str(bundle),
        'generated': started,
        'host': {'kernel': os.uname().release, 'machine': os.uname().machine},
        'verdict': verdict,
        'counts': counts,
        'device_ready': device_ready,
        'device_ready_reasons': reasons,
        'phase6_candidate': phase6,
        'gate_executed': gate_ok,
        'checks': report.rows,
    }
    (out / 'acceptance.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (out / 'ACCEPTANCE.md').write_text(report.render_markdown(manifest))
    print('\nverdict: ' + verdict, flush=True)
    print('install candidate: ' + ('YES' if phase6 else 'NO'), flush=True)
    return 0 if counts['FAIL'] == 0 else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True, help='images/<name>/ bundle directory')
    parser.add_argument('--out', type=Path,
                        help='report directory (default out/bundle-acceptance/<bundle-name>)')
    parser.add_argument('--skip-external', action='store_true',
                        help='skip the verify-bundle.sh sections (self-tests/fixtures)')
    parser.add_argument('--fake-fastboot', type=Path, default=FAKE_FASTBOOT,
                        help='Fastboot simulator used for --dry-run')
    args = parser.parse_args(argv)
    if not args.bundle.is_dir():
        parser.error('--bundle is not a directory: ' + str(args.bundle))
    out = args.out or (PROJECT / 'out/bundle-acceptance' / args.bundle.resolve().name)
    if not args.fake_fastboot.is_file():
        parser.error('fake fastboot simulator is missing: ' + str(args.fake_fastboot))
    return accept(args.bundle, out, args.skip_external, args.fake_fastboot)


if __name__ == '__main__':
    sys.exit(main())
