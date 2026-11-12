#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check REAL public/private artifacts and the local-preparation roundtrip.

No devices, mounts, system changes or network. Temporary prepared files are
private and deleted on completion. These are offline checks, not installation
or hardware acceptance.
"""
import argparse
import gzip
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('preparation', PROJECT / 'tools/release/prepare-image.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def metadata(member):
    # hdrcharset describes PAX header encoding, not an inode attribute.
    # Python adds BINARY for non-UTF8 capability xattrs; compare all logical
    # xattr values (including the original surrogateescaped bytes) instead.
    pax = {k: v for k, v in member.pax_headers.items() if k != 'hdrcharset'}
    return (member.uid, member.gid, member.mode, member.type, member.linkname,
            member.devmajor, member.devminor, member.mtime, member.uname, member.gname, pax)


def read_tree(path):
    records = {}
    special = {}
    with tarfile.open(path, 'r|gz') as archive:
        for member in archive:
            name = p.safe_name(member.name)
            assert name not in records, 'duplicate archive path'
            data = archive.extractfile(member).read() if member.isreg() else b''
            records[name] = (metadata(member), p.digest(data))
            if name in ('etc/passwd', 'etc/shadow', 'usr/share/liuqin/public-image.json'):
                special[name] = data
    return records, special


def assert_directories(records):
    for name, owner, mode in (
        ('var', (0, 0), 0o755), ('var/lib', (0, 0), 0o755),
        ('var/log', (0, 0), 0o755), ('var/cache', (0, 0), 0o755),
        ('var/tmp', (0, 0), 0o1777), ('run', (0, 0), 0o755), ('tmp', (0, 0), 0o1777),
        ('home/user', (1000, 1000), 0o700), ('home/user/.var', (1000, 1000), 0o755),
        ('home/user/.var/app', (1000, 1000), 0o755),
    ):
        m = records[name][0]
        assert m[:3] == (*owner, mode) and m[3] == tarfile.DIRTYPE, name
    contexts = records['var'][0][-1]
    assert 'var_t' in contexts.get('SCHILY.xattr.security.selinux', ''), 'target /var SELinux context absent'
    assert records['usr/lib/clock-epoch'][0][7] > 1700000000, 'trusted clock-epoch mtime was zeroed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    parser.add_argument('--private-bundle', required=True, type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--roundtrip', action='store_true')
    args = parser.parse_args()
    manifest = p.load_verified(args.base)
    private_before = {n: p.file_digest(args.private_bundle / n)
                      for n in ('rootfs.tar.gz', 'boot.img', 'installer.img')}
    assert manifest['desktop_user'] == 'user'
    original, _ = read_tree(args.private_bundle / 'rootfs.tar.gz')
    public, public_special = read_tree(args.base / 'rootfs.base.tar.gz')
    removed = {p.safe_name(r['tar']['name']) for r in manifest['rootfs_restore']}
    if 'stock_audio_source' in manifest:
        audio = [r for r in manifest['rootfs_restore'] if r.get('origin') == 'stock-audio']
        assert len(audio) == 8 and len({r['source'] for r in audio}) == 5
        assert all(p.safe_name(r['tar']['name']) not in public for r in audio)
        print('PASS: all eight stock speaker files removed; five local originals required', flush=True)
    assert set(original) - removed == set(public), 'unexpected added/removed rootfs members'
    for name, value in public.items():
        assert original[name] == value, 'content or metadata changed during export: ' + name
    assert_directories(public)
    try:
        assert_directories({k: v for k, v in public.items() if k != 'var'})
    except KeyError:
        pass
    else:
        raise AssertionError('missing /var was not detected')
    print('PASS: complete rootfs member/content/owner/mode/xattr comparison, including /var and ~/.var', flush=True)
    assert not any(n.endswith('/authorized_keys') or '/.xwechat/' in n or '/Zotero/' in n for n in public)
    users = [r.split(':') for r in public_special['etc/passwd'].decode().splitlines()]
    assert [(r[0], r[5]) for r in users if r[2] == '1000'] == [('user', '/home/user')]
    shadow = dict((r.split(':')[0], r.split(':')[1]) for r in public_special['etc/shadow'].decode().splitlines())
    assert shadow['user'].startswith(('!', '*')) and shadow['root'].startswith(('!', '*'))
    for filename, records in manifest['ramdisk_restore'].items():
        private_bytes = (args.private_bundle / filename).read_bytes()
        base_bytes = (args.base / filename.replace('.img', '.base.img')).read_bytes()
        _, kernel, ramdisk, dtb = p.boot_parts(private_bytes)
        _, public_kernel, public_ramdisk, public_dtb = p.boot_parts(base_bytes)
        assert kernel == public_kernel and dtb == public_dtb
        assert p.replace_ramdisk(private_bytes, ramdisk) == private_bytes
        entries = p.read_cpio(public_ramdisk)
        originals = p.read_cpio(ramdisk)
        for r in records:
            assert r['name'] not in entries
            entries[r['name']] = (r['fields'], p.local_payload(args.firmware, r))
        assert originals == entries, 'ramdisk restoration changed content or metadata'
        assert p.read_cpio(p.write_cpio(entries)) == entries
        image = gzip.decompress(kernel) if kernel[:2] == b'\x1f\x8b' else kernel
        assert image.count(bytes.fromhex(manifest['kernel_build_id'])) == 1
        assert 'etc/liuqin-kernel-ram-test' not in entries, 'RAM-test image must not be released'
        assert b'no slot-success metadata update' not in originals['init'][1]
        print('PASS:', filename, 'kernel/DTB identity, CPIO removal/restoration, Build ID and persistent init', flush=True)
    for name in ('../escape', '/absolute', 'ok/../../escape'):
        try:
            p.safe_name(name)
        except ValueError:
            pass
        else:
            raise AssertionError('unsafe name accepted')
    with tempfile.TemporaryDirectory(prefix='liuqin-public-image-test-') as tmp:
        temp = Path(tmp)
        recipe = manifest['rootfs_restore'][0]
        fake = temp / p.safe_name(recipe['source'])
        fake.parent.mkdir(parents=True)
        fake.write_bytes(b'wrong firmware')
        try:
            p.local_payload(temp, recipe)
        except ValueError:
            pass
        else:
            raise AssertionError('changed firmware accepted')
        print('PASS: wrong firmware and path escapes rejected', flush=True)
        if args.roundtrip:
            password = secrets.token_urlsafe(18)
            p.getpass.getpass = lambda prompt: password
            out = temp / 'private-prepared'
            p.prepare(SimpleNamespace(base=args.base, firmware=args.firmware, check=False, out=out))
            prepared, special = read_tree(out / 'rootfs.tar.gz')
            assert set(prepared) == set(original)
            for name in prepared:
                assert prepared[name][0] == original[name][0], 'restored metadata changed: ' + name
                if name not in ('etc/shadow', 'usr/share/liuqin/public-image.json'):
                    assert prepared[name] == original[name], 'restored content changed: ' + name
            assert_directories(prepared)
            shadows = dict((r.split(':')[0], r.split(':')[1]) for r in special['etc/shadow'].decode().splitlines())
            assert shadows['user'].startswith('$6$') and shadows['root'] == shadow['root']
            assert json.loads(special['usr/share/liuqin/public-image.json'])['requires_local_preparation'] is False
            subprocess.run(['python3', str(PROJECT / 'installer/install.py'), '--bundle', str(out),
                            '--check', '--layout', 'linux-only'], check=True, stdout=subprocess.DEVNULL)
            denied = subprocess.run(['python3', str(PROJECT / 'installer/install.py'), '--bundle', str(out),
                                     '--check', '--layout', 'dual'], capture_output=True, text=True)
            assert denied.returncode != 0 and 'this release supports only' in denied.stderr
            fakebin = temp / 'bin'
            fakebin.mkdir()
            (fakebin / 'fastboot').symlink_to(PROJECT / 'tests/installer/fake-fastboot')
            fixture = temp / 'fastboot.txt'
            fixture.write_text('product=liuqin\nunlocked=yes\nserial=TEST_SERIAL\ncurrent-slot=a\n'
                               'userdata=0x1000000000\nboot_a=0xc000000\nboot_b=0xc000000\n'
                               'max-download-size=0x30000000\n')
            fake_log = temp / 'fastboot.log'
            env = dict(os.environ, PATH=str(fakebin) + ':' + os.environ['PATH'],
                       FAKE_FASTBOOT_FIXTURE=str(fixture), FAKE_FASTBOOT_LOG=str(fake_log),
                       FAKE_FASTBOOT_REFUSE_WRITES='1')
            rehearsal = subprocess.run(['python3', str(PROJECT / 'installer/install.py'),
                                        '--bundle', str(out), '--layout', 'linux-only',
                                        '--serial', 'TEST_SERIAL', '--backup', str(temp / 'backups'),
                                        '--erase-userdata', '--allow-unverified', '--dry-run'],
                                       env=env, capture_output=True, text=True)
            assert rehearsal.returncode == 0, rehearsal.stderr
            assert 'DRY-RUN' in rehearsal.stdout
            assert all(' getvar ' in line for line in fake_log.read_text().splitlines())
            print('PASS: full private preparation roundtrip, individual password, installer check, dual-boot rejection', flush=True)
            print('PASS: real installer dry-run consumes prepared metadata; fake Fastboot observed queries only', flush=True)
    print('All real-artifact public image checks passed (offline only)')
    assert private_before == {n: p.file_digest(args.private_bundle / n) for n in private_before}, 'private inputs changed during verification'


if __name__ == '__main__':
    main()
