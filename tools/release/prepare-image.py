#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Export a firmware-free base, or prepare a PRIVATE local install bundle.

This program never contacts, boots or writes a device.  Python 3.11+ is enough
on Linux and Windows: the password hash uses crypt(3), openssl or a portable
SHA-512 crypt fallback, and zstd inputs use Python's zstd module, the
``zstandard`` package or a zstd executable.  Android v2 layout follows AOSP
system/tools/mkbootimg (write_header/write_data).
Only the reviewed v2/4096/no-second/no-recovery format is accepted.
"""
import argparse
import copy
import getpass
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import shutil
import stat
import struct
import subprocess
import tarfile

MAX_BOOT = 201326592
ALLOWED_FIRMWARE = {'regulatory.db', 'regulatory.db.p7s',
                    'qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def zstd_decode(path):
    """Decode a .zst input with whatever this host actually has.

    Windows 11 has no zstd executable by default, so prefer Python's own
    support (3.14+) and the pip-installable ``zstandard`` module before
    falling back to the command.  The caller gets one actionable error
    instead of a missing-binary traceback.
    """
    try:
        from compression import zstd  # Python 3.14+
        return zstd.decompress(path.read_bytes())
    except ImportError:
        pass
    try:
        import zstandard
        with path.open('rb') as stream:
            return zstandard.ZstdDecompressor().stream_reader(stream).read()
    except ImportError:
        pass
    executable = shutil.which('zstd')
    if not executable:
        raise ValueError('zstd input needs Python 3.14+, the zstandard module, or a zstd executable: '
                         + str(path) + ' —— 可运行 `python -m pip install zstandard` 后重试')
    return subprocess.run([executable, '-q', '-d', '-c', str(path)],
                          check=True, capture_output=True).stdout


# crypt(3) base64, used only by the pure-Python SHA-512 fallback below.
_CRYPT64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
_CRYPT_ORDER = (
    (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
    (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
    (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
    (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
    (62, 20, 41), (None, None, 63),
)


def _crypt64(value, length):
    result = []
    for shift in range(0, length * 6, 6):
        result.append(_CRYPT64[(value >> shift) & 0x3f])
    return ''.join(result)


def sha512_crypt(password, salt=None):
    """Ulrich Drepper's SHA-512 crypt ($6$), for hosts without crypt(3).

    Used only to write the prepared image's shadow entry; verified against
    the system crypt/openssl in tests.  Salt is the plain 16-character form.
    """
    salt = salt or ''.join(secrets.choice(_CRYPT64) for _ in range(16))
    if not 1 <= len(salt) <= 16 or any(c not in _CRYPT64 for c in salt):
        raise ValueError('invalid SHA-512 crypt salt')
    raw = password.encode()
    salt_bytes = salt.encode()

    def digest(*parts):
        context = hashlib.sha512()
        for part in parts:
            context.update(part)
        return context.digest()

    alternate = digest(raw, salt_bytes, raw)
    context = hashlib.sha512(raw + salt_bytes)
    remaining = len(raw)
    while remaining > 0:
        context.update(alternate[:min(remaining, 64)])
        remaining -= 64
    remaining = len(raw)
    while remaining > 0:
        context.update(alternate if remaining & 1 else raw)
        remaining >>= 1
    alternate = context.digest()

    # Digest P repeats the password `len(password)` times; digest S repeats
    # the salt 16 + A[0] times and keeps the salt-length prefix.  Both rules
    # are the ones glibc and passlib implement.
    p_bytes = digest(raw * len(raw))
    s_bytes = digest(salt_bytes * (16 + alternate[0]))[:len(salt)]
    p = (p_bytes * ((len(raw) + 63) // 64))[:len(raw)]
    s = (s_bytes * ((len(salt) + 63) // 64))[:len(salt)]

    result = alternate
    for index in range(5000):
        context = hashlib.sha512()
        context.update(p if index & 1 else result)
        if index % 3:
            context.update(s)
        if index % 7:
            context.update(p)
        context.update(result if index & 1 else p)
        result = context.digest()

    encoded = ''.join(_crypt64(((0 if a is None else result[a]) << 16) |
                               ((0 if b is None else result[b]) << 8) |
                               result[c], 4 if a is not None else 2)
                      for a, b, c in _CRYPT_ORDER)
    return '$6$' + salt + '$' + encoded


def password_hash(password):
    """SHA-512 crypt via crypt(3), openssl, or the portable fallback."""
    try:
        import crypt
        hashed = crypt.crypt(password, crypt.mksalt(crypt.METHOD_SHA512))
        if hashed and hashed.startswith('$6$'):
            return hashed
    except (ImportError, AttributeError, OSError):
        pass
    executable = shutil.which('openssl')
    if executable:
        result = subprocess.run([executable, 'passwd', '-6', '-stdin'],
                                input=password + '\n', check=True,
                                capture_output=True, text=True).stdout.strip()
        if result.startswith('$6$'):
            return result
    return sha512_crypt(password)


def read_password_file(path):
    password_file = Path(path)
    if os.name != 'nt' and password_file.stat().st_mode & 0o077:
        raise ValueError('--password-file must not be readable by other users: chmod 600 ' +
                         str(password_file))
    password = password_file.read_text().rstrip('\r\n')
    if '\n' in password or '\r' in password:
        raise ValueError('--password-file must contain one line')
    return password


def safe_name(name):
    name = name.removeprefix('./')
    if name == '.':
        return name
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(p in ('..', '') for p in path.parts):
        raise ValueError('unsafe archive path')
    if '\n' in name or '\r' in name or '\x00' in name:
        raise ValueError('unsafe archive name')
    return str(path)


def boot_parts(data):
    if len(data) > MAX_BOOT or len(data) < 4096 or data[:8] != b'ANDROID!':
        raise ValueError('not a bounded Android boot image')
    value = lambda off: struct.unpack_from('<I', data, off)[0]
    if (value(36), value(40), value(1644), value(24), value(1632)) != (4096, 2, 1660, 0, 0):
        raise ValueError('requires Android v2/4096 without second or recovery payload')
    sizes = (value(8), value(16), value(1648))
    if not all(sizes):
        raise ValueError('empty boot payload')
    offset = 4096
    result = []
    for size in sizes:
        end = offset + size
        aligned = (end + 4095) & ~4095
        if aligned > len(data) or any(data[end:aligned]):
            raise ValueError('truncated payload or nonzero image padding')
        result.append(data[offset:end])
        offset = aligned
    if offset != len(data):
        raise ValueError('unexpected footer or extra payload')
    return bytearray(data[:4096]), *result


def replace_ramdisk(data, ramdisk):
    header, kernel, old_ramdisk, dtb = boot_parts(data)
    struct.pack_into('<I', header, 16, len(ramdisk))
    checksum = hashlib.sha1()
    for payload in (kernel, ramdisk, b'', b'', dtb):
        checksum.update(payload)
        checksum.update(struct.pack('<I', len(payload)))
    header[576:608] = checksum.digest().ljust(32, b'\0')
    result = bytes(header)
    for payload in (kernel, ramdisk, dtb):
        result += payload + b'\0' * (-len(payload) % 4096)
    boot_parts(result)
    return result


def read_cpio(compressed):
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        data = stream.read(512 * 1024 * 1024 + 1)
    if len(data) > 512 * 1024 * 1024:
        raise ValueError('ramdisk decompression limit exceeded')
    result = {}
    offset = 0
    while offset + 110 <= len(data):
        if data[offset:offset + 6] != b'070701':
            raise ValueError('expected newc cpio')
        fields = [int(data[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
        size, namesize = fields[6], fields[11]
        if not 1 <= namesize <= 4096 or offset + 110 + namesize > len(data):
            raise ValueError('invalid cpio name')
        rawname = data[offset + 110:offset + 110 + namesize]
        if rawname[-1:] != b'\0':
            raise ValueError('unterminated cpio name')
        name = rawname[:-1].decode()
        offset = (offset + 110 + namesize + 3) & ~3
        if name == 'TRAILER!!!':
            if size or any(data[offset:]):
                raise ValueError('unexpected cpio trailer content')
            return result
        name = safe_name(name)
        if name in result or offset + size > len(data):
            raise ValueError('duplicate or truncated cpio member')
        result[name] = (fields, data[offset:offset + size])
        offset = (offset + size + 3) & ~3
    raise ValueError('missing cpio trailer')


def write_cpio(entries):
    result = bytearray()
    trailer = ([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 11, 0], b'')
    for name, (fields, payload) in [*entries.items(), ('TRAILER!!!', trailer)]:
        fields = list(fields)
        rawname = name.encode() + b'\0'
        fields[6], fields[11] = len(payload), len(rawname)
        result.extend(b'070701' + ''.join(f'{v:08x}' for v in fields).encode() + rawname)
        result.extend(b'\0' * (-len(result) % 4))
        result.extend(payload)
        result.extend(b'\0' * (-len(result) % 4))
    result.extend(b'\0' * (-len(result) % 512))
    return gzip.compress(result, compresslevel=6, mtime=0)


def firmware_catalog(root, manifest):
    catalog = {}
    for line in manifest.read_text().splitlines():
        expected, name = line.split(None, 1)
        rel = name.removeprefix('/usr/lib/firmware/')
        if rel in ALLOWED_FIRMWARE:
            continue
        path = root / safe_name(rel)
        path.resolve(strict=True).relative_to(root.resolve())
        data = path.read_bytes()
        if digest(data) != expected:
            raise ValueError('firmware source does not match its pinned manifest: ' + rel)
        record = {'source': rel, 'source_sha256': expected, 'decode': None}
        catalog.setdefault(expected, record)
        if rel.endswith('.zst'):
            decoded = zstd_decode(path)
            catalog.setdefault(digest(decoded), dict(record, decode='zstd'))
    return catalog


def tar_metadata(member):
    result = member.get_info()
    result['type'] = member.type.decode('ascii')
    result['pax_headers'] = dict(member.pax_headers)
    return result


def tar_member(record):
    member = tarfile.TarInfo(record['name'])
    for key in ('mode', 'uid', 'gid', 'size', 'mtime', 'linkname', 'uname', 'gname', 'devmajor', 'devminor'):
        setattr(member, key, record[key])
    member.type = record['type'].encode('ascii')
    member.pax_headers = dict(record['pax_headers'])
    return member


def rewrite_tar(source, target, transform, additions=()):
    with tarfile.open(source, 'r|gz') as incoming, target.open('xb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, compresslevel=1, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode='w|', format=tarfile.PAX_FORMAT) as outgoing:
                seen = set()
                for member in incoming:
                    name = safe_name(member.name)
                    if name in seen:
                        raise ValueError('duplicate rootfs archive member: ' + name)
                    seen.add(name)
                    if member.size > 512 * 1024 * 1024:
                        raise ValueError('unexpectedly large rootfs member')
                    data = incoming.extractfile(member).read() if member.isreg() else b''
                    new = transform(member, data)
                    if new is not None:
                        item, payload = new
                        item = copy.copy(item)
                        item.pax_headers = dict(item.pax_headers)
                        if item.isreg():
                            item.size = len(payload)
                        outgoing.addfile(item, io.BytesIO(payload) if item.isreg() else None)
                for member, payload in additions:
                    name = safe_name(member.name)
                    if name in seen:
                        raise ValueError('addition conflicts with a rootfs member')
                    seen.add(name)
                    outgoing.addfile(member, io.BytesIO(payload) if member.isreg() else None)


def new_directory(path):
    if path.exists() or path.is_symlink():
        raise ValueError('output already exists; choose a new directory')
    path.mkdir(parents=True)


def write_checksums(root):
    files = sorted(p for p in root.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
    (root / 'SHA256SUMS').write_text(''.join(f'{file_digest(p)}  {p.name}\n' for p in files))


def export_base(args):
    bundle = args.bundle.resolve(strict=True)
    private = json.loads((bundle / 'bundle.json').read_text())
    provenance = json.loads((args.root / 'usr/share/liuqin/firmware-provenance.json').read_text())
    if private['device'] != 'liuqin' or not provenance['files']:
        raise ValueError('expected a complete private liuqin assembly with firmware provenance')
    catalog = firmware_catalog(args.firmware, args.firmware_manifest)
    root_paths = {r['path'].lstrip('/'): r for r in provenance['files']}
    result = {'format': 'liuqin-public-base/1', 'device': 'liuqin', 'release': '45',
              'desktop': 'gnome', 'desktop_user': args.user,
              'kernel_release': private['kernel_release'], 'kernel_build_id': args.kernel_build_id,
              'requires_local_preparation': True, 'device_ready': False,
              'fresh_install_verified': False, 'dual_boot': 'not verified; not supported',
              'firmware_source': {'repository': 'https://github.com/yzddmr6/xiaomipad-6pro-mainline',
                                  'commit': 'f5a535f5c1c980f042b58cb77467ff8f02a5518e',
                                  'subdirectory': 'device/firmware/usr/lib/firmware'},
              'rootfs_restore': [], 'ramdisk_restore': {}, 'files': {}}
    new_directory(args.out)
    for filename in ('boot.img', 'installer.img'):
        data = (bundle / filename).read_bytes()
        if digest(data) != private['files'][filename]:
            raise ValueError('private boot payload changed')
        _, _, ramdisk, _ = boot_parts(data)
        if replace_ramdisk(data, ramdisk) != data:
            raise ValueError('Android header identity roundtrip failed')
        entries = read_cpio(ramdisk)
        removed = []
        for name, (fields, payload) in list(entries.items()):
            recipe = catalog.get(digest(payload)) if stat.S_ISREG(fields[1]) else None
            if recipe:
                removed.append(dict(recipe, name=name, fields=fields, sha256=digest(payload)))
                del entries[name]
        if not removed:
            raise ValueError('expected vendor firmware in each private ramdisk')
        result['ramdisk_restore'][filename] = removed
        template = filename.replace('.img', '.base.img')
        (args.out / template).write_bytes(replace_ramdisk(data, write_cpio(entries)))
        result['files'][template] = file_digest(args.out / template)

    def strip(member, data):
        name = safe_name(member.name)
        original = root_paths.get(name)
        recipe = catalog.get(digest(data)) if member.isreg() else None
        if original or recipe:
            if member.issym():
                if not original or member.linkname != original.get('symlink_target'):
                    raise ValueError('unrecognized firmware symlink')
                recipe = {'source': original['source_path'].removeprefix('/usr/lib/firmware/'),
                          'source_sha256': original['source_sha256'], 'decode': None}
            elif not member.isreg() or recipe is None:
                raise ValueError('unknown firmware metadata or content: ' + name)
            result['rootfs_restore'].append(dict(recipe, tar=tar_metadata(member), sha256=digest(data)))
            return None
        return member, data

    rewrite_tar(bundle / 'rootfs.tar.gz', args.out / 'rootfs.base.tar.gz', strip)
    removed_names = {safe_name(r['tar']['name']) for r in result['rootfs_restore']}
    if not set(root_paths) <= removed_names:
        raise ValueError('some private firmware paths were not removed')
    result['files']['rootfs.base.tar.gz'] = file_digest(args.out / 'rootfs.base.tar.gz')
    (args.out / 'image.json').write_text(json.dumps(result, indent=2) + '\n')
    write_checksums(args.out)
    print('Exported public base; vendor payloads removed from rootfs and both boot images')


def load_verified(base):
    manifest = json.loads((base / 'image.json').read_text())
    if manifest['format'] != 'liuqin-public-base/1' or manifest['device'] != 'liuqin':
        raise ValueError('unsupported public image manifest')
    for name, expected in manifest['files'].items():
        if '/' in name or name in ('', '.', '..') or file_digest(base / name) != expected:
            raise ValueError('base image checksum mismatch: ' + name)
    return manifest


def local_payload(root, recipe):
    path = root / safe_name(recipe['source'])
    path.resolve(strict=True).relative_to(root.resolve())
    data = path.read_bytes()
    if digest(data) != recipe['source_sha256']:
        raise ValueError('wrong or changed firmware input: ' + recipe['source'])
    if recipe['decode'] == 'zstd':
        data = zstd_decode(path)
    elif recipe['decode'] is not None:
        raise ValueError('unknown firmware encoding')
    if 'sha256' in recipe and digest(data) != recipe['sha256']:
        # Symlink archive records have no data; their source digest is checked
        # above and their original link text is restored below.
        if recipe.get('tar', {}).get('type') != tarfile.SYMTYPE.decode():
            raise ValueError('decoded firmware checksum mismatch')
    return data


def prepare(args):
    manifest = load_verified(args.base)
    recipes = list(manifest['rootfs_restore'])
    for records in manifest['ramdisk_restore'].values():
        recipes.extend(records)
    payloads = {}
    for recipe in recipes:
        key = (recipe['source'], recipe['decode'])
        payloads[key] = local_payload(args.firmware, recipe)
    print('Base and all required local firmware verified. Nothing has been written to a device.')
    if args.check:
        return
    password_file = getattr(args, 'password_file', None)
    if password_file:
        password = read_password_file(password_file)
        if len(password) < 8:
            raise ValueError('the password must have at least 8 characters')
    else:
        password = getpass.getpass('Choose a NEW password for the tablet user: ')
        if len(password) < 8 or password != getpass.getpass('Repeat the password: '):
            raise ValueError('passwords must match and have at least 8 characters')
    hashed = password_hash(password)
    if not hashed.startswith('$6$'):
        raise ValueError('could not produce a SHA-512 password hash')
    password = None
    new_directory(args.out)
    args.out.chmod(0o700)
    for filename, records in manifest['ramdisk_restore'].items():
        data = (args.base / filename.replace('.img', '.base.img')).read_bytes()
        entries = read_cpio(boot_parts(data)[2])
        for record in records:
            if record['name'] in entries:
                raise ValueError('firmware conflicts with a base ramdisk path')
            entries[record['name']] = (record['fields'], payloads[(record['source'], record['decode'])])
        (args.out / filename).write_bytes(replace_ramdisk(data, write_cpio(entries)))
    found_shadow = False

    def personalize(member, data):
        nonlocal found_shadow
        if safe_name(member.name) == 'etc/shadow':
            lines = []
            for line in data.decode().splitlines():
                fields = line.split(':')
                if fields[0] == manifest['desktop_user']:
                    fields[1] = hashed
                    found_shadow = True
                lines.append(':'.join(fields))
            return member, ('\n'.join(lines) + '\n').encode()
        if safe_name(member.name) == 'usr/share/liuqin/public-image.json':
            config = json.loads(data)
            config['requires_local_preparation'] = False
            config['user_password'] = 'set privately by the recipient'
            return member, (json.dumps(config, indent=2) + '\n').encode()
        return member, data

    additions = []
    for record in manifest['rootfs_restore']:
        member = tar_member(record['tar'])
        payload = payloads[(record['source'], record['decode'])] if member.isreg() else b''
        additions.append((member, payload))
    rewrite_tar(args.base / 'rootfs.base.tar.gz', args.out / 'rootfs.tar.gz', personalize, additions)
    if not found_shadow:
        raise ValueError('desktop user was not found in the image shadow file')
    files = {n: file_digest(args.out / n) for n in ('boot.img', 'installer.img', 'rootfs.tar.gz')}
    bundle = {'format': 'liuqin-bundle/1', 'device': 'liuqin', 'name': args.out.name,
              'status': 'OFFLINE_BUILT',
              'kernel_release': manifest['kernel_release'], 'device_ready': False,
              'tested_storage_layout': 'unverified fresh installation; linux-only experimental',
              'offline_only': True, 'project_dirty': False, 'files': files,
              'supported_layouts': ['linux-only'],
              'file_bytes': {n: (args.out / n).stat().st_size for n in files},
              'fedora': {'release': '45', 'contract': '/etc/liuqin-fedora-root.contract'},
              'redistribution': 'private-local-only: user-supplied vendor firmware and personal password hash',
              'requires_local_preparation': False}
    (args.out / 'bundle.json').write_text(json.dumps(bundle, indent=2) + '\n')
    write_checksums(args.out)
    print('PRIVATE local install bundle prepared. Do not upload this directory or share it.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export', help='maintainer: remove vendor firmware from a private build')
    export.add_argument('--bundle', type=Path, required=True)
    export.add_argument('--root', type=Path, required=True)
    export.add_argument('--firmware', type=Path, required=True)
    export.add_argument('--firmware-manifest', type=Path, required=True)
    export.add_argument('--kernel-build-id', required=True)
    export.add_argument('--user', default='user')
    export.add_argument('--out', type=Path, required=True)
    local = commands.add_parser('prepare', help='verify inputs and assemble a PRIVATE local bundle')
    local.add_argument('--base', type=Path, required=True)
    local.add_argument('--firmware', type=Path, required=True,
                       help='locally supplied pinned usr/lib/firmware directory')
    local.add_argument('--out', type=Path)
    local.add_argument('--password-file', type=Path, metavar='FILE',
                       help='read the new tablet password from a private file instead of prompting '
                            '(for an agent; the file must not be world-readable on Unix)')
    local.add_argument('--check', action='store_true', help='only verify, no password prompt or outputs')
    verify = commands.add_parser('verify', help='check the public base payload hashes')
    verify.add_argument('--base', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'export':
            export_base(args)
        elif args.command == 'verify':
            load_verified(args.base)
            print('Public base payload checksums verified')
        else:
            if not args.check and args.out is None:
                parser.error('prepare needs --out unless --check is used')
            prepare(args)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Image preparation stopped: {error}\n')


if __name__ == '__main__':
    main()
