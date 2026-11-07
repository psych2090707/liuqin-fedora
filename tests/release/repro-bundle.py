#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproducibility probe for an assembled liuqin bundle (task-22).

Re-runs the key assembly stages of task-14 against the staged inputs and compares
byte hashes with the shipped bundle:

  1. rootfs.tar.gz  — same deterministic tar+gzip command over the staged
                      flat rootfs tree (expect byte-identical);
  2. boot initramfs — scripts/build-initramfs.sh over the same rootfs manifest
                      and kernel metadata (expect byte-identical);
  3. boot.img       — scripts/build-bootimg.sh over the rebuilt initramfs with
                      the same kernel payload / DTB source;
  4. root.img       — mkfs.ext4 -d over the same tree with the bundle's UUID and
                      size (expected to differ: superblock timestamps, SELinux
                      xattrs and inode times are not pinned by the current
                      command); plus a controlled small-image experiment that
                      isolates the timestamp/`SOURCE_DATE_EPOCH` behaviour.

Everything is read from the bundle and out/image-build/<name>/ (read-only);
all new files go below --out (default out/bundle-acceptance/repro-<name>/).
No device and no network access.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[2]
ENVIRONMENT = dict(os.environ, LC_ALL='C', LANG='C')
BOOT_PARTITION_BYTES = 201326592


def sha256_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(command, timeout=3600, env=None):
    try:
        return subprocess.run([str(item) for item in command], capture_output=True, text=True,
                              timeout=timeout, env=env or ENVIRONMENT)
    except (OSError, subprocess.SubprocessError) as error:
        return subprocess.CompletedProcess([str(item) for item in command], 127, '',
                                           f'{type(error).__name__}: {error}')


def sudo(command, timeout=3600):
    return run(['sudo', '-n', *[str(item) for item in command]], timeout=timeout)


class Probe:
    def __init__(self):
        self.results = []

    def add(self, ident, status, detail, extra=None):
        row = {'id': ident, 'status': status, 'detail': detail}
        if extra:
            row.update(extra)
        self.results.append(row)
        print(f'[{status}] {ident}: {detail}', flush=True)

    def ok(self, ident, condition, detail, extra=None):
        self.add(ident, 'PASS' if condition else 'FAIL', detail, extra if condition is not None else None)
        return condition

    def skip(self, ident, detail):
        self.add(ident, 'SKIP', detail)


def build_info(bundle, work):
    """The recorded input metadata for the boot stages."""
    for path in (bundle / 'manifests/image-build-info.json', work / 'image-build-info.json'):
        if path.is_file():
            try:
                return json.loads(path.read_text()), path
            except ValueError:
                pass
    return {}, None


def find_rootfs_tree(bundle, work):
    candidates = [
        work / 'rootfs/root',
        Path(str(bundle.resolve())).parent.parent / 'out/rootfs/rootfs',
        PROJECT / 'out/rootfs/rootfs',
    ]
    for candidate in candidates:
        if (candidate / 'etc/os-release').is_file():
            return candidate
    return None


def repro_rootfs_tar(probe, bundle, work, out, tree):
    tarball = bundle / 'rootfs.tar.gz'
    if not tarball.is_file() or tree is None:
        probe.skip('rootfs.tar.gz', 'bundle tarball or staged rootfs tree is unavailable')
        return
    destination = out / 'repro-rootfs.tar.gz'
    command = ('tar -C ' + str(tree) +
               ' --numeric-owner --acls --xattrs --xattrs-include=\'*\''
               " --sort=name --mtime='@0' --owner=0 --group=0 -cf - . | gzip -n -9")
    started = time.monotonic()
    destination.write_bytes(b'')
    result = run(['sudo', '-n', 'sh', '-c', command + ' > "' + str(destination) + '"'],
                 timeout=1800)
    elapsed = time.monotonic() - started
    if result.returncode != 0 or not destination.is_file():
        probe.add('rootfs.tar.gz', 'FAIL', 're-pack failed: ' + (result.stderr or '')[:300])
        return
    expected = sha256_file(tarball)
    actual = sha256_file(destination)
    probe.ok('rootfs.tar.gz', expected == actual,
             f'sha256 {"matches" if expected == actual else "differs"} '
             f'({actual[:16]}… vs bundle {expected[:16]}…, {elapsed:.1f}s)',
             {'bundle_sha256': expected, 'repro_sha256': actual, 'seconds': round(elapsed, 1)})


def repro_boot(probe, bundle, work, out):
    ramdisk_source = work / 'boot/initramfs/liuqin-firstboot.cpio.gz'
    kernel_out = work / 'kernel-out'
    if not kernel_out.is_dir():
        kernel_out = PROJECT / 'out/kernel'
    if not ramdisk_source.is_file():
        probe.skip('boot.img', 'staged initramfs is unavailable (out/image-build/<name>/boot)')
        return
    info, info_path = build_info(bundle, work)
    rebuilt_ramdisk_dir = out / 'repro-initramfs'
    arguments = [PROJECT / 'scripts/build-initramfs.sh', '--out', rebuilt_ramdisk_dir,
                 '--kernel-out', kernel_out,
                 '--rootfs-manifest', work / 'rootfs.files.sha256',
                 '--allow-missing-pins', '--source-date-epoch', '0']
    if (work / 'boot/initramfs/liuqin-firstboot.cpio.gz').is_file():
        arguments += ['--allow-missing-firmware']
    result = run(arguments, timeout=3600)
    (out / 'repro-initramfs.log').write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        probe.add('boot initramfs', 'FAIL', 'rebuild failed: ' + result.stderr.strip()[-400:])
        return
    rebuilt = rebuilt_ramdisk_dir / 'initramfs/liuqin-firstboot.cpio.gz'
    if not rebuilt.is_file():
        probe.add('boot initramfs', 'FAIL', 'rebuilt initramfs is missing')
        return
    expected = sha256_file(ramdisk_source)
    actual = sha256_file(rebuilt)
    probe.ok('boot initramfs', expected == actual,
             f'ramdisk sha256 {"matches" if expected == actual else "differs"} '
             f'({actual[:16]}… vs {expected[:16]}…)')

    boot_out = out / 'repro-boot'
    result = run([PROJECT / 'scripts/build-bootimg.sh', '--kernel-out', kernel_out,
                  '--ramdisk', rebuilt, '--out', boot_out, '--strict-kernel',
                  '--dtb-source', 'upstream-artifact'], timeout=1800)
    (out / 'repro-bootimg.log').write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        probe.add('boot.img', 'FAIL', 'build-bootimg failed: ' + result.stderr.strip()[-400:])
        return
    image = boot_out / 'boot-liuqin-dev.img'
    if not image.is_file():
        probe.add('boot.img', 'FAIL', 'rebuilt boot.img is missing')
        return
    expected = sha256_file(bundle / 'boot.img')
    actual = sha256_file(image)
    probe.ok('boot.img', expected == actual,
             f'boot.img sha256 {"matches" if expected == actual else "differs"} '
             f'({actual[:16]}… vs bundle {expected[:16]}…; kernel payload '
             f'{info.get("kernel_payload", "unrecorded")}, dtb '
             f'{info.get("dtb_source", "unrecorded")})',
             {'bundle_sha256': expected, 'repro_sha256': actual,
              'kernel_payload': info.get('kernel_payload'), 'dtb_source': info.get('dtb_source')})


def image_uuid_and_block(image):
    result = run(['dumpe2fs', '-h', image])
    uuid = re.search(r'Filesystem UUID:\s*(\S+)', result.stdout or '')
    block = re.search(r'Block size:\s*(\d+)', result.stdout or '')
    return (uuid.group(1) if uuid else None, int(block.group(1)) if block else None)


def repro_root_img(probe, bundle, work, out, tree, full):
    if tree is None or not (bundle / 'root.img').is_file():
        probe.skip('root.img', 'bundle root.img or staged rootfs tree is unavailable')
        return
    source = bundle / 'root.img'
    uuid, block = image_uuid_and_block(source)
    size = source.stat().st_size
    if not full:
        probe.skip('root.img', 'full 5+ GiB rebuild disabled (use --full-root-img)')
    else:
        destination = out / 'repro-root.img'
        if destination.exists():
            destination.unlink()
        started = time.monotonic()
        truncate = sudo(['truncate', '-s', str(size), destination])
        if truncate.returncode != 0:
            probe.add('root.img', 'FAIL', 'cannot create the repro image: ' + truncate.stderr[:200])
        else:
            mkfs = sudo(['mkfs.ext4', '-q', '-F', '-L', 'LIUQIN_ROOT', '-b', str(block or 4096),
                         '-m', '0', '-U', uuid, '-d', tree, destination], timeout=3600)
            elapsed = time.monotonic() - started
            (out / 'repro-rootimg.log').write_text(mkfs.stdout + mkfs.stderr)
            expected = sha256_file(source)
            actual = sha256_file(destination) if destination.is_file() else ''
            probe.ok('root.img', expected == actual,
                     f'root.img {"byte-identical" if expected == actual else "differs"} '
                     f'with the same UUID/tree/size ({elapsed:.1f}s)'
                     if mkfs.returncode == 0 else 'mkfs failed: ' + mkfs.stderr.strip()[-300:],
                     {'bundle_sha256': expected, 'repro_sha256': actual,
                      'uuid': uuid, 'size': size, 'seconds': round(elapsed, 1)})
            destination.unlink(missing_ok=True)

    # Controlled experiment: isolate whether mkfs itself is deterministic on the
    # same tree/UUID, and whether SOURCE_DATE_EPOCH pins the timestamps.
    experiment = out / 'mkfs-experiment'
    experiment.mkdir(exist_ok=True)
    small_tree = experiment / 'tree'
    (small_tree / 'etc').mkdir(parents=True, exist_ok=True)
    (small_tree / 'etc/hello').write_text('liuqin reproducibility fixture\n')
    image_a = experiment / 'a.img'
    image_b = experiment / 'b.img'
    fixed_uuid = '11111111-2222-3333-4444-555555555555'
    results = {}
    for label, env_extra, first, second in (
            ('default', {}, image_a, image_b),
            ('SOURCE_DATE_EPOCH=0', {'SOURCE_DATE_EPOCH': '0'},
             experiment / 'c.img', experiment / 'd.img')):
        for target in (first, second):
            target.unlink(missing_ok=True)
            with target.open('wb') as stream:
                stream.truncate(64 * 1024 * 1024)
            environment = dict(ENVIRONMENT, **env_extra)
            sub = subprocess.run(['mkfs.ext4', '-q', '-F', '-L', 'LIUQIN_ROOT', '-b', '4096',
                                  '-m', '0', '-U', fixed_uuid, '-d', str(small_tree), str(target)],
                                 capture_output=True, text=True, env=environment)
            if sub.returncode != 0:
                results[label] = 'mkfs failed: ' + sub.stderr.strip()[:200]
                break
        else:
            results[label] = 'identical' if sha256_file(first) == sha256_file(second) else 'differs'
    probe.add('root.img mkfs determinism', 'INFO',
              'same tree+UUID: timestamps ' + results.get('default', 'unavailable') +
              '; with SOURCE_DATE_EPOCH=0: ' + results.get('SOURCE_DATE_EPOCH=0', 'unavailable'),
              {'experiment': results})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--out', type=Path,
                        help='probe output directory (default out/bundle-acceptance/repro-<name>)')
    parser.add_argument('--work', type=Path,
                        help='task-14 staging directory (default out/image-build/<bundle-name>)')
    parser.add_argument('--skip-boot', action='store_true')
    parser.add_argument('--skip-rootfs-tar', action='store_true')
    parser.add_argument('--skip-root-img', action='store_true')
    parser.add_argument('--full-root-img', action='store_true',
                        help='also rebuild the whole 5+ GiB root.img (slow, needs disk)')
    args = parser.parse_args(argv)
    bundle = args.bundle.resolve()
    if not (bundle / 'bundle.json').is_file():
        parser.error('not a bundle directory: ' + str(bundle))
    name = json.loads((bundle / 'bundle.json').read_text()).get('name', bundle.name)
    out = (args.out or (PROJECT / 'out/bundle-acceptance' / ('repro-' + bundle.name))).resolve()
    work = (args.work or (PROJECT / 'out/image-build' / name)).resolve()
    out.mkdir(parents=True, exist_ok=True)
    tree = find_rootfs_tree(bundle, work)
    probe = Probe()
    started = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    if not args.skip_rootfs_tar:
        repro_rootfs_tar(probe, bundle, work, out, tree)
    if not args.skip_boot:
        repro_boot(probe, bundle, work, out)
    if not args.skip_root_img:
        repro_root_img(probe, bundle, work, out, tree, args.full_root_img)

    counts = {}
    for row in probe.results:
        counts[row['status']] = counts.get(row['status'], 0) + 1
    manifest = {
        'format': 'liuqin-bundle-reproducibility/1',
        'bundle': str(bundle),
        'work': str(work),
        'rootfs_tree': str(tree) if tree else None,
        'generated': started,
        'counts': counts,
        'results': probe.results,
    }
    (out / 'reproducibility.json').write_text(json.dumps(manifest, indent=2) + '\n')
    lines = ['# Bundle reproducibility probe', '',
             f'- bundle: `{bundle}`', f'- staging: `{work}`',
             f'- rootfs tree: `{tree}`', f'- generated: `{started}`', '',
             '| id | status | detail |', '|---|---|---|']
    for row in probe.results:
        lines.append(f'| {row["id"]} | {row["status"]} | '
                     f'{row["detail"].replace("|", "\\|")} |')
    lines += ['', '## Interpretation', '',
              '- `rootfs.tar.gz` and the boot stages use pinned metadata '
              '(`--sort=name --mtime=@0 --owner=0`, `SOURCE_DATE_EPOCH=0`, `gzip -n`),'
              ' so they are expected to be byte-reproducible.',
              '- `root.img` is currently **not reproducible**: `mkfs.ext4 -d` stamps the'
              ' superblock/inode times and SELinux xattrs depend on the host. The'
              ' recommended release recipe is in `BUILD.md`.',
              '']
    (out / 'reproducibility.md').write_text('\n'.join(lines))
    print('\nreproducibility results: ' + json.dumps(counts), flush=True)
    print('report: ' + str(out / 'reproducibility.md'), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
