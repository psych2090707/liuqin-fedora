#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the Fedora installer RAM-image runtime.

Derived from upstream xiaomipad-6pro-mainline commit
f5a535f5c1c980f042b58cb77467ff8f02a5518e tools/lib/build-installer-runtime.py
(MIT): the same job (seven distribution binaries plus every shared library
they need, their ELF interpreter, /etc/mke2fs.conf and a static liuqin-reboot),
the same manifest idea, but sourced from **Fedora aarch64 packages** instead of
an Ubuntu root and with a small dependency-free ELF reader instead of pyelftools.

Input is an unpacked Fedora aarch64 root tree (see scripts/build-installer.sh:
it produces one with a Fedora container, or points at an mkosi rootfs / a
directory of extracted RPMs).  Output is the directory tree that the installer
RAM image copies to / before booting:

    usr/bin/tar  usr/bin/install
    usr/sbin/mkfs.ext4  usr/sbin/e2fsck  usr/sbin/e2label  usr/sbin/getcap
    usr/sbin/sgdisk  usr/sbin/liuqin-reboot
    lib/<interpreter>  lib64/<every shared library>
    etc/mke2fs.conf  etc/passwd  etc/group
    runtime-files.json  runtime-packages.txt

No device is opened and nothing outside --root/--out is written.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

UPSTREAM_COMMIT = 'f5a535f5c1c980f042b58cb77467ff8f02a5518e'

# The RAM-install tools, at the paths the device-side scripts use.  The second
# element lists where the Fedora package tree may actually keep the file:
# Fedora is merged-/usr, so /usr/sbin/* and /usr/bin/* are one directory and
# either name may be the real entry.
TOOLS = (
    ('usr/bin/tar', ('usr/bin/tar',)),
    ('usr/bin/install', ('usr/bin/install',)),
    ('usr/sbin/mkfs.ext4', ('usr/sbin/mkfs.ext4', 'usr/bin/mkfs.ext4')),
    ('usr/sbin/e2fsck', ('usr/sbin/e2fsck', 'usr/bin/e2fsck')),
    ('usr/sbin/e2label', ('usr/sbin/e2label', 'usr/bin/e2label')),
    ('usr/sbin/getcap', ('usr/sbin/getcap', 'usr/bin/getcap')),
    ('usr/sbin/sgdisk', ('usr/sbin/sgdisk', 'usr/bin/sgdisk')),
)
# Where a Fedora aarch64 root keeps shared libraries.  Fedora uses /usr/lib64
# on every 64-bit architecture, including aarch64; the others are fallbacks.
LIBRARY_DIRS = ('usr/lib64', 'lib64', 'usr/lib', 'lib', 'usr/lib/aarch64-linux-gnu')
MACHINE_AARCH64 = 0xB7
PT_LOAD, PT_DYNAMIC, PT_INTERP = 1, 2, 3
DT_NEEDED, DT_STRTAB, DT_STRSZ = 1, 5, 10


class ElfError(Exception):
    """An input that cannot be treated as an aarch64 dynamic executable."""


def read_elf(path):
    """Return {'machine': int, 'interp': str|None, 'needed': [str]}.

    A deliberately small ELF64 reader: the installer image tools are dynamic
    AArch64 executables, and the only facts needed are the program interpreter
    and the DT_NEEDED list.  No third-party dependency, no locale-dependent
    readelf output.
    """
    with path.open('rb') as stream:
        data = stream.read()
    if len(data) < 64 or data[:4] != b'\x7fELF':
        raise ElfError('not an ELF file: ' + str(path))
    if data[4] != 2 or data[5] != 1:
        raise ElfError('not a 64-bit little-endian ELF: ' + str(path))
    machine = int.from_bytes(data[18:20], 'little')
    phoff = int.from_bytes(data[32:40], 'little')
    phentsize = int.from_bytes(data[54:56], 'little')
    phnum = int.from_bytes(data[56:58], 'little')
    segments = []
    for index in range(phnum):
        base = phoff + index * phentsize
        fields = data[base:base + 56]
        p_type, _, p_offset, p_vaddr, _, p_filesz = (
            int.from_bytes(fields[0:4], 'little'), int.from_bytes(fields[4:8], 'little'),
            int.from_bytes(fields[8:16], 'little'), int.from_bytes(fields[16:24], 'little'),
            int.from_bytes(fields[24:32], 'little'), int.from_bytes(fields[32:40], 'little'))
        segments.append((p_type, p_offset, p_vaddr, p_filesz))
    interpreter = None
    dynamic = None
    for p_type, p_offset, p_vaddr, p_filesz in segments:
        if p_type == PT_INTERP and p_filesz:
            interpreter = data[p_offset:p_offset + p_filesz].split(b'\0', 1)[0].decode()
        elif p_type == PT_DYNAMIC:
            dynamic = (p_offset, p_filesz)
    needed = []
    if dynamic is not None:
        offset, size = dynamic
        strtab_vaddr = strsz = None
        entries = []
        for index in range(size // 16):
            base = offset + index * 16
            tag = int.from_bytes(data[base:base + 8], 'little', signed=True)
            value = int.from_bytes(data[base + 8:base + 16], 'little')
            entries.append((tag, value))
            if tag == DT_STRTAB:
                strtab_vaddr = value
            elif tag == DT_STRSZ:
                strsz = value
        if strtab_vaddr is not None and strsz is not None:
            strtab_offset = None
            for p_type, p_offset, p_vaddr, p_filesz in segments:
                if p_type == PT_LOAD and p_vaddr <= strtab_vaddr < p_vaddr + p_filesz:
                    strtab_offset = p_offset + (strtab_vaddr - p_vaddr)
                    break
            if strtab_offset is not None:
                table = data[strtab_offset:strtab_offset + strsz]
                for tag, value in entries:
                    if tag == DT_NEEDED and value < len(table):
                        needed.append(table[value:table.index(b'\0', value)].decode())
    return {'machine': machine, 'interp': interpreter, 'needed': needed}


def resolve_within_root(root, relative):
    """Resolve symlinks *inside* the package root, never against the host /.

    A Fedora package tree keeps /bin -> usr/bin, /lib64 -> usr/lib64 and the
    e2fsprogs /usr/bin/e2label -> tune2fs hardlink/symlink layout, so the real
    bytes have to be found without ever letting an absolute symlink escape to
    the host filesystem.
    """
    parts = [part for part in str(relative).split('/') if part not in ('', '.')]
    current = Path()
    pending = list(parts)
    hops = 0
    while pending:
        part = pending.pop(0)
        if part == '..':
            current = current.parent
            continue
        candidate = root / current / part
        if candidate.is_symlink():
            hops += 1
            if hops > 40:
                raise ElfError('symlink loop under the package root: ' + str(relative))
            target = os.readlink(candidate)
            if target.startswith('/'):
                current = Path()
            pending = [piece for piece in target.split('/') if piece not in ('', '.')] + pending
            continue
        current = current / part
        if not (root / current).exists():
            return None
    return root / current


def require(root, relative, kind='file'):
    found = resolve_within_root(root, relative)
    if found is None or not (found.is_file() if kind == 'file' else found.is_dir()):
        raise ElfError('missing from the package root: /' + relative +
                       ' (Fedora packages tar/coreutils/e2fsprogs/libcap/gdisk are required)')
    return found


def library_path(root, name):
    for directory in LIBRARY_DIRS:
        found = resolve_within_root(root, directory + '/' + name)
        if found is not None and found.is_file():
            return found
    raise ElfError('shared library not found in the package root: ' + name)


def build(root, out, reboot_source, cross_compile):
    """Copy the tools, their interpreter and their library closure into out."""
    if out.exists():
        raise ElfError('output must be a new directory: ' + str(out))
    files = {}
    libraries = {}
    pending = []
    for target, candidates in TOOLS:
        source = next((found for found in (resolve_within_root(root, candidate)
                                           for candidate in candidates) if found is not None), None)
        if source is None:
            raise ElfError('missing from the package root: /' + target +
                           ' (Fedora packages tar/coreutils/e2fsprogs/libcap/gdisk are required)')
        pending.append(('tool', target, source))
    while pending:
        kind, relative, source = pending.pop()
        if kind == 'tool':
            if relative in files:
                continue
        else:
            name = relative
            if name in libraries:
                continue
            libraries[name] = source
        info = read_elf(source)
        if info['machine'] != MACHINE_AARCH64:
            raise ElfError('expected an aarch64 ELF: ' + str(source))
        if kind == 'tool':
            files[relative] = source
        interpreter = info['interp']
        if interpreter is not None:
            name = Path(interpreter).name
            if name not in libraries:
                pending.append(('lib', name, library_path(root, name)))
        for needed in info['needed']:
            if needed not in libraries:
                pending.append(('lib', needed, library_path(root, needed)))
    files['etc/mke2fs.conf'] = require(root, 'etc/mke2fs.conf')
    out.mkdir(parents=True)
    manifest = {}
    for relative, source in sorted(files.items()):
        destination = out / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o644 if relative == 'etc/mke2fs.conf' else 0o755)
        manifest[relative] = hashlib.sha256(destination.read_bytes()).hexdigest()
    # Shared libraries and the ELF interpreter keep the soname/loader path they
    # are looked up by, not the path they happened to live at in the package.
    for name, source in sorted(libraries.items()):
        relative = ('lib/' if name.startswith('ld-') else 'lib64/') + name
        destination = out / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o755)
        manifest[relative] = hashlib.sha256(destination.read_bytes()).hexdigest()
    # liuqin-reboot is the static helper upstream builds from
    # device/charger-mode/liuqin-charger-mode-exit.c (MIT); it reboots the
    # tablet back into Fastboot after the RAM installer finishes.
    reboot = out / 'usr/sbin/liuqin-reboot'
    reboot.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([cross_compile + 'gcc', '-Os', '-static', '-s', str(reboot_source),
                    '-o', str(reboot)], check=True)
    manifest['usr/sbin/liuqin-reboot'] = hashlib.sha256(reboot.read_bytes()).hexdigest()
    (out / 'etc/passwd').write_text('root:x:0:0:root:/root:/bin/sh\n')
    (out / 'etc/group').write_text('root:x:0:\n')
    manifest['etc/passwd'] = hashlib.sha256((out / 'etc/passwd').read_bytes()).hexdigest()
    manifest['etc/group'] = hashlib.sha256((out / 'etc/group').read_bytes()).hexdigest()
    packages = root / 'pkg-versions.txt'
    if packages.is_file():
        shutil.copyfile(packages, out / 'runtime-packages.txt')
    info = {'upstream_commit': UPSTREAM_COMMIT, 'source': 'Fedora aarch64 packages',
            'tool': 'installer/build-runtime.py', 'files': manifest}
    (out / 'runtime-info.json').write_text(json.dumps(info, indent=2, sort_keys=True) + '\n')
    return manifest


def verify(runtime, qemu=None):
    """Check an existing runtime: hashes, aarch64 machine, and optionally run it."""
    runtime = runtime.resolve()
    info_path = runtime / 'runtime-info.json'
    if not info_path.is_file():
        raise ElfError('no runtime-info.json in ' + str(runtime))
    info = json.loads(info_path.read_text())
    failures = []
    for relative, digest in info.get('files', {}).items():
        path = runtime / relative
        if not path.is_file():
            failures.append('missing: ' + relative)
            continue
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            failures.append('hash mismatch: ' + relative)
    expected = {target for target, _ in TOOLS} | {'usr/sbin/liuqin-reboot',
                                                  'etc/mke2fs.conf', 'etc/passwd', 'etc/group'}
    for relative in sorted(expected - set(info.get('files', {}))):
        failures.append('not in the manifest: ' + relative)
    if failures:
        raise ElfError('runtime verification failed:\n  ' + '\n  '.join(failures))
    if qemu is not None:
        for relative, _ in TOOLS:
            result = subprocess.run([qemu, '-L', str(runtime), str(runtime / relative),
                                     '--help'], stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, text=True)
            # sgdisk/e2fsck print help to stderr and exit non-zero; only the
            # loader failing ("Could not open", "error while loading") matters.
            output = result.stderr
            if 'error while loading' in output or 'Could not open' in output:
                failures.append('cannot execute ' + relative + ': ' + output.strip()[:300])
        if failures:
            raise ElfError('runtime execution verification failed:\n  ' + '\n  '.join(failures))
        print('PASS: runtime tools execute under ' + qemu + ' (aarch64 user emulation)')
    return len(info.get('files', {}))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, help='unpacked Fedora aarch64 root tree')
    parser.add_argument('--out', type=Path, help='new output directory for the runtime')
    parser.add_argument('--reboot-source', type=Path,
                        help='liuqin-charger-mode-exit.c (default: lib/liuqin-charger-mode-exit.c '
                             'next to this program)')
    parser.add_argument('--cross-compile', default=os.environ.get('CROSS_COMPILE', 'aarch64-linux-gnu-'),
                        help='cross toolchain prefix for the static liuqin-reboot helper')
    parser.add_argument('--verify', type=Path, metavar='RUNTIME',
                        help='verify an existing runtime instead of building one')
    parser.add_argument('--qemu', help='with --verify: execute each tool under this user emulator')
    args = parser.parse_args(argv)
    try:
        if args.verify is not None:
            count = verify(args.verify, args.qemu)
            print('PASS: Fedora installer runtime verified: ' + str(count) +
                  ' files; no device access')
            return
        if args.root is None or args.out is None:
            parser.error('--root and --out are required (or --verify RUNTIME)')
        reboot_source = args.reboot_source or Path(__file__).resolve().parent / 'lib/liuqin-charger-mode-exit.c'
        if not reboot_source.is_file():
            parser.error('reboot helper source is missing: ' + str(reboot_source))
        manifest = build(args.root.resolve(), args.out.resolve(), reboot_source.resolve(),
                         args.cross_compile)
    except (ElfError, OSError, subprocess.SubprocessError) as error:
        sys.exit('build-installer-runtime: ' + str(error))
    print('Installer runtime: ' + str(len(manifest)) + ' files from Fedora aarch64 packages;'
          ' no device access')


if __name__ == '__main__':
    main()
