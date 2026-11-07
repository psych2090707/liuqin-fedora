#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Assemble the Fedora RAM-installer overlay for the boot-builder pipeline.

The installer boot image (``installer.img``) is a boot.img whose ramdisk is a
BusyBox initramfs plus the installer runtime.  Upstream builds it in
``tools/lib/build-initramfs.sh`` (installer branch) and
``tools/build-liuqin-native-boot.sh``; in this project that is the boot-builder
task's pipeline (``scripts/build-initramfs.sh`` + ``scripts/build-bootimg.sh``).

This program produces what that pipeline consumes and verifies everything that
can be verified without device access:

    out/installer/image-overlay/
      <runtime tree>                        seven ELF tools + libs + mke2fs.conf
      usr/lib/liuqin/install-root.sh        device-side install (Fedora adapted)
      usr/lib/liuqin/install-layout.sh      device-side GPT operations
      usr/lib/liuqin/install-switch-store.sh
      usr/lib/liuqin/provision.sh           persist provisioning
      etc/liuqin-installer                  'liuqin' marker the RAM shell checks
      etc/liuqin-storage-mode               'readonly'
      etc/liuqin-fedora-root.contract       root admission contract v2 (ADR-0004 D4)
      installer-image.json                  manifest + boot-builder interface

It does not build a boot image and cannot make one bootable: the kernel, the
DTB, the stock-ROM overlay inputs, mkbootimg and the static BusyBox all come
from the boot-builder pipeline.  The manifest records that dependency instead
of hiding it.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

UPSTREAM_COMMIT = 'f5a535f5c1c980f042b58cb77467ff8f02a5518e'
RAM_SCRIPTS = (
    ('install-root.sh', 'device-side installer: formats the root, unpacks the '
                        'Fedora root archive (flat install), provisions persist, '
                        'KDE/plasmalogin first boot'),
    ('install-privileges.sh', 'privileged-file validator sourced by install-root.sh: '
                              'setuid/setgid modes + security.capability xattrs from the '
                              'rootfs-derived expectation list'),
    ('install-layout.sh', 'device-side GPT operations: report/geometry/backup-gpt/'
                          'restore-gpt/wipe-head/apply/digest'),
    ('install-switch-store.sh', 'dual layout: stores the two boot images for liuqin-switch'),
    ('provision.sh', 'reads the factory persist partition read-only into the new root'),
)
CONTRACT_HEADER = 'LIUQIN_FEDORA_ROOT_CONTRACT_V2'
# Contract v2 grammar (ADR-0004 D2): topology only, no content-hash pins.
CONTRACT_FIELDS = {'marker': 4, 'file': 2, 'exec': 2, 'resolve': 3, 'display-manager': 2}
SHA256 = re.compile(r'^[0-9a-f]{64}$')


class AssembleError(Exception):
    """A missing or inconsistent input; nothing was written outside --out."""


def load_build_runtime():
    path = Path(__file__).resolve().parent / 'build-runtime.py'
    spec = importlib.util.spec_from_file_location('build_runtime', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy_tree(source, destination, epoch):
    """Copy a tree, keeping modes and normalising timestamps for reproducibility."""
    for item in sorted(source.rglob('*')):
        target = destination / item.relative_to(source)
        if item.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(item.readlink())
            continue
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            target.chmod(0o755)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(item, target)
        target.chmod(item.stat().st_mode & 0o777)
    for item in sorted(source.rglob('*')):
        target = destination / item.relative_to(source)
        if target.is_symlink():
            continue
        try:
            os.utime(target, (epoch, epoch), follow_symlinks=False)
        except OSError:
            pass


def check_scripts(scripts):
    for name, _ in RAM_SCRIPTS:
        path = scripts / name
        if not path.is_file():
            raise AssembleError('missing device-side script: ' + str(path))
        result = subprocess.run(['sh', '-n', str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            raise AssembleError('shell syntax error in ' + name + ': ' + result.stderr.strip())


PRIVILEGE_KINDS = ('setuid', 'setgid', 'cap')


def check_privileges(path):
    """Validate the rootfs-derived privileged-file expectation list."""
    lines = path.read_text(encoding='ascii').splitlines()
    entries = 0
    kinds = set()
    for number, line in enumerate(lines, start=1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split(' ')
        if '' in fields or fields[0] not in PRIVILEGE_KINDS or len(fields) != 3:
            raise AssembleError(f'privileged-file expectation line {number} is malformed: {line!r}')
        if fields[2].startswith('/') is False or '/../' in fields[2]:
            raise AssembleError(
                f'privileged-file expectation line {number} path is not absolute: {line!r}')
        if fields[0] in ('setuid', 'setgid'):
            if not re.fullmatch(r'[0-7]{3,4}', fields[1]):
                raise AssembleError(
                    f'privileged-file expectation line {number} mode is not octal: {line!r}')
        elif not fields[1]:
            raise AssembleError(
                f'privileged-file expectation line {number} capability is empty: {line!r}')
        entries += 1
        kinds.add(fields[0])
    return entries, len([k for k in kinds if k in ('setuid', 'setgid')]) > 0, 'cap' in kinds


def check_contract(path):
    """Validate the v2 topology contract the RAM installer verifies roots against."""
    lines = path.read_text(encoding='ascii').splitlines()
    if not lines or lines[0] != CONTRACT_HEADER:
        raise AssembleError(
            'the Fedora root admission contract header is not ' + CONTRACT_HEADER + ': '
            + str(path))
    if not 8 <= len(lines) <= 128:
        raise AssembleError(
            f'the Fedora root admission contract has {len(lines)} lines (expected 8..128): '
            + str(path))
    entries = 0
    kinds = set()
    for number, line in enumerate(lines[1:], start=2):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split(' ')
        if '' in fields:
            raise AssembleError(f'contract line {number} has repeated spaces: {line!r}')
        kind = fields[0]
        if kind not in CONTRACT_FIELDS or len(fields) != CONTRACT_FIELDS[kind]:
            raise AssembleError(f'contract line {number} is not valid v2 topology: {line!r}')
        if kind in ('marker', 'file', 'exec', 'resolve') and (
                not fields[1].startswith('/') or '/../' in fields[1]):
            raise AssembleError(f'contract line {number} path is not a plain absolute path: {line!r}')
        if kind == 'marker':
            if not SHA256.fullmatch(fields[3]):
                raise AssembleError(f'contract line {number} marker sha256 is malformed: {line!r}')
        if kind == 'resolve' and '/' in fields[2]:
            raise AssembleError(f'contract line {number} resolve target is not a basename: {line!r}')
        entries += 1
        kinds.add(kind)
    if entries < 8:
        raise AssembleError(f'the Fedora root admission contract has only {entries} entries')
    if 'marker' not in kinds or 'display-manager' not in kinds:
        raise AssembleError('the Fedora root admission contract is missing the root marker or '
                            'the display-manager entry')
    return entries


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True, help='built runtime tree')
    parser.add_argument('--out', type=Path, required=True, help='new overlay directory')
    parser.add_argument('--scripts', type=Path,
                        help='directory with the device-side scripts (default: lib/ beside this file)')
    parser.add_argument('--contract', type=Path, help='Fedora root admission contract')
    parser.add_argument('--privileges', type=Path,
                        help='rootfs-derived privileged-file expectations '
                             '(setuid/setgid modes + security.capability xattrs)')
    parser.add_argument('--busybox', type=Path,
                        help='static aarch64 BusyBox from the boot-builder pipeline (recorded, '
                             'not copied: the ramdisk already provides it)')
    parser.add_argument('--source-date-epoch', type=int, default=0)
    parser.add_argument('--device', default='liuqin')
    args = parser.parse_args(argv)
    runtime = args.runtime.resolve()
    out = args.out.resolve()
    scripts = (args.scripts or Path(__file__).resolve().parent / 'lib').resolve()
    try:
        if out.exists():
            raise AssembleError('output must be a new directory: ' + str(out))
        if args.device != 'liuqin':
            raise AssembleError('this installer image is liuqin-only')
        build_runtime = load_build_runtime()
        try:
            runtime_files = build_runtime.verify(runtime)
        except build_runtime.ElfError as error:
            raise AssembleError('runtime verification failed: ' + str(error))
        check_scripts(scripts)
        privileges_sha = privileges_entries = None
        if args.privileges is not None:
            if not args.privileges.is_file():
                raise AssembleError('privileged-file expectations are not a file: '
                                    + str(args.privileges))
            privileges_entries = check_privileges(args.privileges)
            privileges_sha = sha256_file(args.privileges)
        contract_sha = contract_pins = None
        if args.contract is not None:
            if not args.contract.is_file():
                raise AssembleError('contract is not a file: ' + str(args.contract))
            contract_pins = check_contract(args.contract)
            contract_sha = sha256_file(args.contract)
        busybox = None
        if args.busybox is not None:
            if not args.busybox.is_file():
                raise AssembleError('busybox is not a file: ' + str(args.busybox))
            info = build_runtime.read_elf(args.busybox)
            if info['machine'] != build_runtime.MACHINE_AARCH64 or info['interp'] is not None:
                raise AssembleError('the BusyBox is not a static aarch64 ELF: ' + str(args.busybox))
            busybox = sha256_file(args.busybox)

        out.mkdir(parents=True)
        copy_tree(runtime, out, args.source_date_epoch)
        library = out / 'usr/lib/liuqin'
        library.mkdir(parents=True, exist_ok=True)
        for name, _ in RAM_SCRIPTS:
            shutil.copyfile(scripts / name, library / name)
            (library / name).chmod(0o755)
        markers = {'etc/liuqin-installer': 'liuqin\n', 'etc/liuqin-storage-mode': 'readonly\n'}
        (out / 'etc').mkdir(parents=True, exist_ok=True)
        for relative, content in markers.items():
            (out / relative).write_text(content)
            (out / relative).chmod(0o644)
        if args.contract is not None:
            shutil.copyfile(args.contract, out / 'etc/liuqin-fedora-root.contract')
            (out / 'etc/liuqin-fedora-root.contract').chmod(0o644)
        if args.privileges is not None:
            shutil.copyfile(args.privileges, out / 'etc/liuqin-installer-privileges')
            (out / 'etc/liuqin-installer-privileges').chmod(0o644)
        files = {}
        for item in sorted(out.rglob('*')):
            if item.is_file():
                files[item.relative_to(out).as_posix()] = sha256_file(item)
        manifest = {
            'device': args.device,
            'role': 'ram-installer',
            'upstream_commit': UPSTREAM_COMMIT,
            'source_date_epoch': args.source_date_epoch,
            'runtime_files': runtime_files,
            'markers': markers,
            'contract': None if contract_sha is None else {
                'path': '/etc/liuqin-fedora-root.contract',
                'sha256': contract_sha,
                'pinned_files': contract_pins,
            },
            'privileged_expectations': None if privileges_sha is None else {
                'path': '/etc/liuqin-installer-privileges',
                'sha256': privileges_sha,
                'entries': privileges_entries[0],
                'has_setuid_setgid': privileges_entries[1],
                'has_capabilities': privileges_entries[2],
                'derived_from': 'the assembled rootfs (setuid/setgid modes and '
                                'security.capability xattrs), not hardcoded',
            },
            'busybox': None if busybox is None else {
                'sha256': busybox,
                'note': 'static aarch64 BusyBox from the boot-builder pipeline; the overlay does '
                        'not copy it because the ramdisk provides /bin/busybox',
            },
            'required_boot_builder': {
                'why': 'installer.img is a boot.img assembled by the boot-builder pipeline '
                       '(scripts/build-initramfs.sh installer branch + scripts/build-bootimg.sh); '
                       'this overlay is not bootable on its own',
                'static_busybox': 'required: /bin/busybox and the applet symlinks the RAM init '
                                  'and the device scripts use',
                'initramfs_init': 'required: the project initramfs/init with the installer markers',
                'boot_image_inputs': ['kernel Image', 'raw DTB', 'mkbootimg.py at the pinned '
                                      'AOSP commit', 'stock ROM DTBO/vendor_boot inputs for the '
                                      'ABL overlay'],
                'env': {'INSTALLER_RUNTIME': str(out)},
            },
            'files': files,
            'script_descriptions': {name: description for name, description in RAM_SCRIPTS},
        }
        entry = out / 'installer-image.json'
        entry.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        entry.chmod(0o644)
        files['installer-image.json'] = sha256_file(entry)
        total = len(files)
    except (AssembleError, OSError) as error:
        sys.exit('assemble-installer: ' + str(error))
    print(f'Fedora RAM-installer overlay: {total} files, contract pins '
          f'{contract_pins if contract_pins is not None else "none"},'
          f' busybox {"recorded" if busybox else "MISSING (boot-builder dependency)"}')
    print('installer.img assembly: scripts/build-initramfs.sh (INSTALLER_RUNTIME=' + str(out) +
          ') then scripts/build-bootimg.sh; no device access')
    return 0


if __name__ == '__main__':
    sys.exit(main())
