#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Collect reviewed local source inputs for the 45/7.3.1 release.

This copies source materials only. It excludes Git databases, vendor firmware,
factory data and compiled output. Original inputs are never modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

PROJECT = Path(__file__).resolve().parents[2]
BINARY_SUFFIXES = {'.img', '.bin', '.mbn', '.elf', '.dtb', '.dtbo', '.ko', '.o', '.a', '.so', '.rpm'}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def ignore(directory, names):
    omitted = []
    for name in names:
        path = Path(directory) / name
        if 'mkbootimg' in Path(directory).parts and name in ('tests', 'testdata'):
            omitted.append(name)
        elif name in ('.git', '__pycache__', 'target', 'node_modules', 'firmware', 'cache', 'out'):
            omitted.append(name)
        elif path.suffix in BINARY_SUFFIXES or name.endswith('.pyc') or name.startswith('id_ed25519'):
            omitted.append(name)
    return omitted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    if args.out.exists():
        parser.error('output exists; choose a new directory')
    args.out.mkdir(parents=True)
    copies = [
        ('upstream/xiaomipad-6pro-mainline', 'upstream-device'),
        ('out/f45/rpms-mobile/work/SOURCES', 'mobile-sources'),
        ('packaging', 'packaging'),
        ('out/f45/gnome-rpm/SOURCES', 'gnome-sources'),
        ('out/f45/clock-rpm/SOURCES', 'clock-sources'),
        ('cache/upstream-v0.6.0/mkbootimg', 'aosp-mkbootimg'),
        ('out/github-publication/sources/rust-vendor', 'rust-vendor'),
        ('rust', 'rust-project'),
        ('kernel/experiments/linux-7.3.1', 'kernel-adaptation'),
    ]
    for original, name in copies:
        source = PROJECT / original
        if not source.is_dir():
            raise ValueError('source input missing: ' + original)
        # Cargo's exported package checksums cover its test/data files too.
        # Preserve those official crate archives exactly; generic build-output
        # filtering would remove legitimate inputs and break offline rebuilds.
        shutil.copytree(source, args.out / name, symlinks=True,
                        ignore=None if name == 'rust-vendor' else ignore)
    topology = PROJECT / 'out/audio-topology/build-info.json'
    topology_candidates = sorted(Path('/var/tmp/liuqin-pack-cache').glob('audioreach-topology-*.tar'))
    if len(topology_candidates) != 1:
        raise ValueError('expected the single retained AudioReach topology source archive')
    topology_tar = topology_candidates[0]
    shutil.copy2(topology_tar, args.out / topology_tar.name)
    shutil.copy2(topology, args.out / 'audio-topology-build-info.json')
    busybox = PROJECT / 'out/github-publication/sources/inputs/busybox-1.36.1.tar.bz2'
    if sha(busybox) != 'b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314':
        raise ValueError('BusyBox source checksum mismatch')
    shutil.copy2(busybox, args.out / busybox.name)
    for name in ('busybox-1.36.1.config', 'busybox-build-info.json'):
        shutil.copy2(PROJECT / 'out/boot/toolchain' / name, args.out / name)
    kernel = json.loads((PROJECT / 'out/kernel-7.3.1/pen-ui5/build-info.json').read_text())
    public_kernel = {k: kernel[k] for k in ('kernel_release', 'gnu_build_id', 'patches',
                                          'config_sha256', 'compiler', 'module_count')}
    (args.out / 'kernel-build.json').write_text(json.dumps(public_kernel, indent=2) + '\n')
    shutil.copy2(PROJECT / 'out/kernel-7.3.1/pen-ui5/dist/config', args.out / 'kernel-final.config')
    rust_licenses = Path('/opt/rust-1.99.1/share/doc/rust')
    shutil.copytree(rust_licenses / 'licenses', args.out / 'rust-toolchain-licenses')
    shutil.copy2(rust_licenses / 'COPYRIGHT-library.html', args.out / 'Rust-COPYRIGHT-library.html')
    origins = {
        'upstream_device_commit': subprocess.check_output([
            'git', '-C', str(PROJECT / 'upstream/xiaomipad-6pro-mainline'), 'rev-parse', 'HEAD'], text=True).strip(),
        'kernel_base': 'linux-7.3.1.tar.xz (separate release attachment)',
        'kernel_build_id': kernel['gnu_build_id'],
        'mobile_sources': 'original source archives and the exact staged patches used by the local RPM build',
        'vendor_firmware_included': False,
    }
    (args.out / 'source-origins.json').write_text(json.dumps(origins, indent=2) + '\n')
    files = sorted(p for p in args.out.rglob('*') if p.is_file() and not p.is_symlink())
    (args.out / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.relative_to(args.out)}\n' for p in files))
    print(f'Collected {len(files)} local source files with licenses; vendor firmware excluded')


if __name__ == '__main__':
    main()
