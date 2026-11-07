#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Self-test for the bundle acceptance runner (tests/release/accept-bundle.py).

Builds a small but structurally complete synthetic bundle in a temporary
directory (Android boot images with cpio initramfs, a real ext4 root.img made
with mkfs.ext4 -d, a rootfs.tar.gz, manifests, SHA256SUMS), runs the
acceptance runner against it and checks both the accepted path and several
failure detections.  No device, no network, nothing outside the temporary
directory.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
RUNNER = Path(__file__).resolve().parent / 'accept-bundle.py'
FAKE_FASTBOOT = PROJECT / 'tests/installer/fake-fastboot'
AARCH64_ELF = PROJECT / 'out/tn0051-installer/runtime/usr/sbin/getcap'
PAGE = 4096
failures = []


def check(name, condition, detail=''):
    if condition:
        print('PASS: ' + name)
    else:
        failures.append(name + (': ' + detail if detail else ''))
        print('FAIL: ' + name + (': ' + detail if detail else ''))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def cpio_newc(entries):
    out = bytearray()
    ino = 1
    for name, data in entries.items():
        encoded = name.encode()
        fields = (ino, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(encoded) + 1, 0)
        out += b'070701' + b''.join(f'{value:08x}'.encode() for value in fields)
        out += encoded + b'\0'
        out += b'\0' * ((-len(out)) % 4)
        out += data
        out += b'\0' * ((-len(out)) % 4)
        ino += 1
    trailer = b'TRAILER!!!'
    fields = (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(trailer) + 1, 0)
    out += b'070701' + b''.join(f'{value:08x}'.encode() for value in fields)
    out += trailer + b'\0'
    out += b'\0' * ((-len(out)) % 4)
    return bytes(out)


def boot_image(kernel, ramdisk_gz, dtb, cmdline=b''):
    header = bytearray(PAGE)
    header[:8] = b'ANDROID!'

    def put(offset, value):
        header[offset:offset + 4] = value.to_bytes(4, 'little')

    put(8, len(kernel))
    put(12, 0x10008000)
    put(16, len(ramdisk_gz))
    put(20, 0x11000000)
    put(24, 0)
    put(28, 0)
    put(32, 0x10000100)
    put(36, PAGE)
    put(40, 2)
    header[608:608 + 512] = cmdline.ljust(512, b'\0')
    put(1644, 1660)
    put(1648, len(dtb))
    put(1652, 0x01F00000)
    padding = lambda data: data + b'\0' * ((-len(data)) % PAGE)
    return bytes(header) + padding(kernel) + padding(ramdisk_gz) + dtb


def make_dtb(marker):
    body = bytearray(256)
    body[0:4] = (0xD00DFEED).to_bytes(4, 'big')
    body[4:8] = len(body).to_bytes(4, 'big')
    body[8:12] = (0x38).to_bytes(4, 'big')
    body[60:64] = b'\0\0\0\0'
    body[64:64 + len(marker)] = marker
    return bytes(body)


def write_tree(root, release):
    # flat install contract: the delivered root is FLAT (partition root == rootfs root).
    native = root

    def text(relative, content, mode=0o644):
        path = native / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(mode)

    text('etc/os-release', 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=44\n')
    text('etc/liuqin-fedora-root', 'liuqin-fedora-root-v1\n')
    text('etc/fstab', 'LABEL=LIUQIN_HOME\t/home\text4\tdefaults,nofail\t0\t2\n')
    text('etc/liuqin/image-contract', 'LOGIN_MANAGER=plasmalogin\n')
    text('etc/machine-id', '\n')
    text('usr/lib/systemd/system/plasmalogin.service',
         '[Unit]\nDescription=Plasma Login\n[Install]\nAlias=display-manager.service\n')
    text('usr/share/liuqin/kernel.release', release + '\n')
    text('usr/share/liuqin/rootfs.files.sha256', (''.join(f'{"0" * 64}  /f{i}\n'
                                                           for i in range(20000))))
    text(f'usr/lib/modules/{release}/kernel/drivers/dummy.ko', 'fixture module\n')
    symbols = native / 'etc/systemd/system'
    symbols.mkdir(parents=True, exist_ok=True)
    os.symlink('/usr/lib/systemd/system/plasmalogin.service',
               symbols / 'display-manager.service')
    (symbols / 'graphical.target.wants').mkdir(exist_ok=True)
    os.symlink('/usr/lib/systemd/system/plasmalogin.service',
               symbols / 'graphical.target.wants/plasmalogin.service')
    binary = native / 'usr/bin/plasmalogin'
    binary.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(AARCH64_ELF, binary)
    binary.chmod(0o755)


def resign(bundle):
    lines = []
    for path in sorted(bundle.rglob('*')):
        if path.is_file() and path.name != 'SHA256SUMS':
            lines.append(f'{sha(path)}  {path.relative_to(bundle).as_posix()}')
    (bundle / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')


def build_fixture(work):
    bundle = work / 'bundle'
    bundle.mkdir()
    release = '6.17.0-rc1-gfe81794b5e1b'
    tree = work / 'tree'
    write_tree(tree, release)
    root_img = bundle / 'root.img'
    subprocess.run(['truncate', '-s', '64M', str(root_img)], check=True)
    subprocess.run(['mkfs.ext4', '-q', '-F', '-L', 'LIUQIN_ROOT', '-b', '4096', '-m', '0',
                    '-U', '11111111-2222-3333-4444-555555555555', '-d', str(tree),
                    str(root_img)], check=True)
    # flat install contract: the archive root is the rootfs root; the installer extracts it
    # directly onto the partition root (no native-root/ level).
    with (bundle / 'rootfs.tar.gz').open('wb') as stream:
        subprocess.run(['tar', '-czf', '-', '-C', str(tree), '.'],
                       stdout=stream, check=True)

    marker_sha = sha(tree / 'etc/liuqin-fedora-root')
    contract = ('LIUQIN_FEDORA_ROOT_CONTRACT_V2\n' +
                '# fixture v2 topology contract (topology contract)\n' +
                f'marker /etc/liuqin-fedora-root 0644 {marker_sha}\n' +
                'file /usr/lib/systemd/system/plasmalogin.service\n' +
                'exec /usr/lib/systemd/system/plasmalogin\n' +
                'exec /usr/lib/systemd/systemd\n' +
                'exec /usr/bin/plasmashell\n' +
                'exec /usr/bin/kwin_wayland\n' +
                'exec /usr/bin/startplasma-wayland\n' +
                'exec /usr/libexec/kscreenlocker_greet\n' +
                'file /usr/share/liuqin/kernel.release\n' +
                'file /usr/share/liuqin/kernel-modules.manifest\n' +
                'resolve /etc/systemd/system/default.target graphical.target\n' +
                'display-manager plasmalogin.service\n')
    persistent = gzip_bytes(cpio_newc({
        '/init': b'#!/bin/sh\nexit 0\n',
        '/bin/busybox': b'\x7fELF\x02\x01\x01' + b'\0' * 100,
        '/etc/liuqin-fedora-root.contract': contract.encode(),
    }))
    kernel = b'\x1f\x8b\x08\x00' + b'\0' * 1000
    (bundle / 'boot.img').write_bytes(boot_image(kernel, persistent, make_dtb(b'boot')))

    installer = gzip_bytes(cpio_newc({
        '/etc/liuqin-installer': b'liuqin\n',
        '/etc/liuqin-storage-mode': b'readonly\n',
        '/usr/lib/liuqin/install-root.sh': b'#!/bin/sh\nexit 0\n',
        '/usr/sbin/mkfs.ext4': b'\x7fELF' + b'\0' * 60,
        '/usr/sbin/sgdisk': b'\x7fELF' + b'\0' * 60,
        '/bin/busybox': b'\x7fELF' + b'\0' * 60,
    }))
    (bundle / 'installer.img').write_bytes(boot_image(kernel, installer, make_dtb(b'inst')))

    manifests = bundle / 'manifests'
    manifests.mkdir()
    (manifests / 'rootfs.files.sha256').write_text(
        ''.join(f'{sha(bundle / "root.img")}  /f{i}\n' for i in range(50)))
    packages = [f'{name}\t1.0-1.fc44\taarch64\t1000'
                for name in ('fedora-release', 'plasma-workspace', 'plasmalogin',
                             'systemd', 'NetworkManager', 'kwin')]
    packages += [f'fixture-package-{index}\t1.0-1.fc44\taarch64\t1000'
                 for index in range(600)]
    (manifests / 'rootfs.packages.txt').write_text('\n'.join(packages) + '\n')
    (manifests / 'kernel-modules.manifest').write_text(
        ''.join(f'{"c" * 64}  /usr/lib/modules/{release}/kernel/x{index}.ko\n'
                for index in range(120)))
    (manifests / 'image-build-info.json').write_text(
        json.dumps({'format': 'liuqin-image-build-info/1', 'kernel_release': release}))

    files = {name: sha(bundle / name) for name in
             ('boot.img', 'installer.img', 'rootfs.tar.gz', 'root.img')}
    lock_candidates = [PROJECT / 'kernel/source.json', PROJECT / 'kernel/fedora/source.json']
    commit = '0' * 40
    for candidate in lock_candidates:
        if candidate.is_file():
            commit = json.loads(candidate.read_text())['commit']
            break
    manifest = {
        'format': 'liuqin-bundle/1',
        'device': 'liuqin',
        'name': bundle.name,
        'status': 'OFFLINE_BUILT',
        'device_ready': False,
        'offline_only': True,
        'device_ready_reasons': ['fixture bundle, never booted on hardware'],
        'fedora': {'release': '44', 'contract': '/etc/liuqin-fedora-root.contract',
                   'contract_version': 2,
                   'rootfs_manifest': sha(manifests / 'rootfs.files.sha256'),
                   'runtime_manifest': 'd' * 64},
        'kernel_commit': commit,
        'kernel_release': release,
        'files': files,
        'redistribution': 'private-local-only',
    }
    (bundle / 'bundle.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (bundle / 'LICENSE').write_text('MIT License\nfixture\n')
    (bundle / 'NOTICE').write_text('liuqin firmware is not redistributable and is not '
                                   'included in public releases.\n')
    (bundle / 'VERIFICATION.md').write_text('# fixture verification\n' + 'x' * 700 + '\n')
    resign(bundle)
    return bundle


def gzip_bytes(data):
    import gzip
    import io
    stream = io.BytesIO()
    with gzip.GzipFile(fileobj=stream, mode='wb', mtime=0) as archive:
        archive.write(data)
    return stream.getvalue()


def run_runner(bundle, out, skip_external=True):
    arguments = [sys.executable, str(RUNNER), '--bundle', str(bundle), '--out', str(out),
                 '--fake-fastboot', str(FAKE_FASTBOOT)]
    if skip_external:
        arguments.append('--skip-external')
    return subprocess.run(arguments, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='liuqin-accept-selftest-') as temporary:
    work = Path(temporary)
    bundle = build_fixture(work)
    before = {path: sha(path) for path in bundle.rglob('*') if path.is_file()}
    out = work / 'out'
    accepted = run_runner(bundle, out)
    check('acceptance runner accepts the synthetic complete bundle', accepted.returncode == 0,
          accepted.stdout[-2000:] + accepted.stderr[-2000:])
    report = {}
    if (out / 'acceptance.json').is_file():
        report = json.loads((out / 'acceptance.json').read_text())
    failed_rows = [row for row in report.get('checks', []) if row['status'] == 'FAIL']
    check('acceptance report has no FAIL', report.get('counts', {}).get('FAIL') == 0,
          json.dumps(report.get('counts')) + ' ' + json.dumps(failed_rows)[:800])
    spec = importlib.util.spec_from_file_location('acceptance', RUNNER)
    acceptance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(acceptance)
    acceptance.VERIFY_BUNDLE = work / 'unavailable-external-verifier'
    optional_report = acceptance.Report()
    acceptance.section_g_verification(optional_report, bundle, {}, out)
    check('retired QEMU evidence is not an acceptance requirement',
          any(row['id'] == 'G2 historical qemu validation' and row['status'] == 'INFO'
              for row in optional_report.rows), str(optional_report.rows))
    check('acceptance verdict is an offline rehearsal (device_ready=false)',
          'OFFLINE_ACCEPTED' in str(report.get('verdict')) and
          report.get('phase6_candidate') is False,
          str(report.get('verdict')) + ' phase6=' + str(report.get('phase6_candidate')))
    check('acceptance report is written as markdown and json',
          (out / 'ACCEPTANCE.md').is_file() and (out / 'acceptance.json').is_file())
    after = {path: sha(path) for path in bundle.rglob('*') if path.is_file()}
    changed = sorted(str(path) for path in set(before) | set(after)
                     if before.get(path) != after.get(path))
    check('acceptance runner left the bundle untouched', before == after,
          'changed: ' + ', '.join(changed[:5]))

    # A corrupted payload must fail (SHA256SUMS / bundle.json hashes).
    corrupt = work / 'bundle-corrupt'
    shutil.copytree(bundle, corrupt)
    with (corrupt / 'boot.img').open('ab') as stream:
        stream.write(b'\x00corrupted')
    result = run_runner(corrupt, work / 'out-corrupt')
    corrupt_report = json.loads((work / 'out-corrupt/acceptance.json').read_text())
    check('a corrupted payload fails acceptance', result.returncode == 1 and
          corrupt_report['counts']['FAIL'] > 0, result.stdout[-1500:])

    # A missing root.img must fail.
    missing = work / 'bundle-missing'
    shutil.copytree(bundle, missing)
    (missing / 'root.img').unlink()
    resign(missing)
    result = run_runner(missing, work / 'out-missing')
    check('a missing root.img fails acceptance', result.returncode == 1,
          result.stdout[-1200:])

    # A kernel release that does not match the image must fail the release-chain
    # checks, even with a re-signed bundle.
    divergent = work / 'bundle-divergent'
    shutil.copytree(bundle, divergent)
    manifest = json.loads((divergent / 'bundle.json').read_text())
    manifest['kernel_release'] = '6.17.0-not-the-image'
    (divergent / 'bundle.json').write_text(json.dumps(manifest, indent=2) + '\n')
    resign(divergent)
    result = run_runner(divergent, work / 'out-divergent')
    divergent_report = json.loads((work / 'out-divergent/acceptance.json').read_text())
    failed_ids = {row['id'] for row in divergent_report['checks'] if row['status'] == 'FAIL'}
    check('a divergent kernel release fails the release-chain checks',
          result.returncode == 1 and 'C1 root.img kernel release' in failed_ids,
          str(sorted(failed_ids)))
    check('the runner reports a non-candidate verdict for failures',
          'NOT_ACCEPTED' in divergent_report['verdict'], divergent_report['verdict'])

if failures:
    sys.exit('bundle acceptance self-test failures:\n' + '\n'.join('  ' + item
                                                                   for item in failures))
print('PASS: bundle acceptance runner self-test (synthetic bundle; no device access)')
