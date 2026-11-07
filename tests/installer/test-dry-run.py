#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline dry-run tests for the Fedora host installer.

A PATH-injected Fastboot simulator (tests/installer/fake-fastboot) answers the
read-only queries; the installer runs with --dry-run, which is the only mode
these tests can reach because every mutating Fastboot command needs
--yes-write-device and that is never passed.  Assertions cover the refusal
branches required by the installer dry-run work: wrong device, locked bootloader, too-small
userdata, boot partition size mismatch, unrecognised GPT and the
partition-table restore/rollback path.

No device, no real fastboot, no adb: the simulator appends to a log file and a
fake fastboot binary found on PATH is the only "device" involved.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
INSTALL = PROJECT / 'installer/install.py'
SIMULATOR = Path(__file__).resolve().parent / 'fake-fastboot'
BOOT_BYTES = 201326592  # the pinned 192 MiB boot partition
PINNED = json.loads((PROJECT / 'installer/lib/liuqin-rom-images.json').read_text())
STOCK_START = None
failures = []


def check(name, condition, detail=''):
    if condition:
        print('PASS: ' + name)
    else:
        failures.append(name + (': ' + detail if detail else ''))
        print('FAIL: ' + name + (': ' + detail))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_fixture(path, **values):
    defaults = {
        'product': 'liuqin', 'unlocked': 'yes', 'serial': 'TEST_SERIAL',
        'current-slot': 'a', 'userdata': '0x1000000000',
        'boot_a': hex(BOOT_BYTES), 'boot_b': hex(BOOT_BYTES),
        'max-download-size': '0x30000000',
    }
    defaults.update(values)
    path.write_text(''.join(f'{key}={value}\n' for key, value in defaults.items()))


def make_bundle(directory, status='OFFLINE_ASSEMBLED', kernel_release='6.17.0-liuqin-test',
                fedora=None):
    directory.mkdir(parents=True, exist_ok=True)
    files = {}
    for name in ('boot.img', 'installer.img', 'rootfs.tar.gz'):
        (directory / name).write_bytes((name + '-fixture').encode())
        files[name] = sha(directory / name)
    manifest = {'device': 'liuqin', 'status': status, 'kernel_release': kernel_release,
                'files': files}
    if fedora is not None:
        manifest['fedora'] = fedora
    (directory / 'bundle.json').write_text(json.dumps(manifest) + '\n')
    return files


def sgdisk(*arguments):
    result = subprocess.run(['sgdisk', *[str(item) for item in arguments]],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError('sgdisk failed: ' + ' '.join(str(i) for i in arguments) + '\n' +
                             result.stdout + result.stderr)
    return result.stdout


def load_layout():
    import importlib.util
    spec = importlib.util.spec_from_file_location('liuqin_layout',
                                                  PROJECT / 'installer/lib/liuqin_layout.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_stock_image(layout, path):
    """The factory table restated in 512-byte sectors, so sgdisk can write it."""
    scale = layout.DEVICE_SECTOR_SIZE // 512
    with path.open('wb') as stream:
        stream.truncate(layout.STOCK_TOTAL_SECTORS * layout.DEVICE_SECTOR_SIZE)
    sgdisk('--clear', '--set-alignment=1', '--resize-table=' + str(layout.STOCK_ENTRIES), path)
    arguments = ['--set-alignment=1']
    for number, first, last, name in layout.STOCK_TABLE:
        if name == layout.USERDATA_NAME:
            continue
        arguments += [f'--new={number}:{first * scale}:{(last + 1) * scale - 1}',
                      f'--typecode={number}:8300', f'--change-name={number}:{name}']
    sgdisk(*arguments, path)
    disk = layout.parse_print(sgdisk('-p', path))
    userdata = next(row for row in layout.STOCK_TABLE if row[3] == layout.USERDATA_NAME)
    sgdisk('--set-alignment=1', f'--new={userdata[0]}:{userdata[1] * scale}:{disk.last_usable}',
           f'--typecode={userdata[0]}:0FC63DAF-8483-4772-8E79-3D69D8477DE4',
           f'--change-name={userdata[0]}:{layout.USERDATA_NAME}',
           f'--attributes={userdata[0]}:set:60', path)
    return layout.parse_print(sgdisk('-p', path))


def gpt_fixture(work, layout, mode):
    """A --simulate-gpt directory with the report/info of a stock, split or
    unknown tablet, written by the real sgdisk against a synthetic image."""
    directory = work / ('gpt-' + mode)
    directory.mkdir()
    image = directory / 'sda.img'
    disk = build_stock_image(layout, image)
    if mode == 'unknown':
        sgdisk('--set-alignment=1', '--change-name=35:something_else', image)
    elif mode == 'split':
        info = layout.parse_info(sgdisk('-i', '35', image))
        region = disk.usable_end - disk.by_name(layout.USERDATA_NAME).start
        sizes = layout.resolve_sizes('linux-only', None, None, region)
        plan = layout.plan_layout(disk, 'linux-only', *sizes)
        sgdisk(*layout.sgdisk_arguments(plan, str(image), info))
    (directory / 'report.txt').write_text(sgdisk('-p', image))
    if mode == 'stock':
        (directory / 'info.txt').write_text(sgdisk('-i', '35', image))
    return directory


def run(project, bundle, fakebin, fixture, args, log, extra_env=None):
    env = os.environ.copy()
    env['PATH'] = str(fakebin) + os.pathsep + env.get('PATH', '')
    env['FAKE_FASTBOOT_LOG'] = str(log)
    env['FAKE_FASTBOOT_FIXTURE'] = str(fixture)
    env.update(extra_env or {})
    if log.exists():
        log.unlink()
    return subprocess.run([sys.executable, str(project / 'installer/install.py'),
                           '--bundle', str(bundle), *args],
                          env=env, capture_output=True, text=True)


MUTATING = ('boot', 'flash', 'erase', 'format', 'flashall', 'update', 'reboot',
            'reboot-bootloader', 'oem')


def commands(log):
    """(command words, raw line) for every simulator invocation, '-'s/-s removed."""
    if not log.exists():
        return
    for line in log.read_text().splitlines():
        tokens = line.split()
        if tokens[:1] == ['-s']:
            tokens = tokens[2:]
        yield tokens, line


def no_mutation(log, name):
    for tokens, line in commands(log):
        if line.startswith(('WROTE', 'REFUSED')):
            check(name + ': no write executed', False, 'log line: ' + line)
            return
        if tokens and (tokens[0] in MUTATING or tokens[0].startswith('--set-active')):
            check(name + ': no write executed', False, 'log line: ' + line)
            return
    check(name + ': no write executed', True)


def assert_refused(name, result, fragment, log):
    ok = result.returncode != 0 and fragment in result.stderr
    check(name, ok, f'rc={result.returncode} stderr={result.stderr.strip()[:400]}')
    no_mutation(log, name)


with tempfile.TemporaryDirectory(prefix='liuqin-dry-run-test-') as temporary:
    work = Path(temporary)
    bundle = work / 'bundle'
    make_bundle(bundle)
    layout = load_layout()
    fakebin = work / 'bin'
    fakebin.mkdir()
    simulator = fakebin / 'fastboot'
    shutil.copyfile(SIMULATOR, simulator)
    simulator.chmod(0o755)
    fixture = work / 'device.fixture'
    write_fixture(fixture)
    log = work / 'fastboot.log'
    backup = work / 'backup'

    # --check: local bundle verification only, no Fastboot process at all.
    local = subprocess.run([sys.executable, str(INSTALL), '--bundle', str(bundle), '--check'],
                           capture_output=True, text=True)
    check('--check verifies the local bundle', local.returncode == 0 and
          'Local bundle checksums verified' in local.stdout, local.stdout + local.stderr)
    check('--check invokes no fastboot', not log.exists())
    saved = (bundle / 'boot.img').read_bytes()
    (bundle / 'boot.img').write_bytes(b'corrupted')
    corrupt = subprocess.run([sys.executable, str(INSTALL), '--bundle', str(bundle), '--check'],
                             capture_output=True, text=True)
    check('--check refuses a corrupted bundle', corrupt.returncode != 0 and
          'checksum mismatch' in corrupt.stderr, corrupt.stderr)
    (bundle / 'boot.img').write_bytes(saved)

    # Default mode is local-only, even with a complete-looking write command.
    default = run(project=PROJECT, bundle=bundle, fakebin=fakebin, fixture=fixture, log=log,
                  args=['--serial', 'TEST_SERIAL', '--backup', str(backup),
                        '--erase-userdata', '--layout', 'linux-only', '--allow-unverified',
                        '--yes'])
    check('no mode flag = local checks only', default.returncode == 0 and
          'Default mode: local checks only' in default.stdout, default.stdout + default.stderr)
    check('no mode flag = no fastboot', not log.exists())

    base = ['--serial', 'TEST_SERIAL', '--backup', str(backup), '--erase-userdata',
            '--layout', 'linux-only', '--allow-unverified', '--yes', '--dry-run']

    # The full successful rehearsal.
    result = run(PROJECT, bundle, fakebin, fixture, base, log)
    check('dry-run linux-only succeeds', result.returncode == 0,
          result.stdout[-800:] + result.stderr[-800:])
    check('dry-run prints the complete write sequence',
          all(fragment in result.stdout for fragment in (
              'would boot the RAM installer: fastboot -s TEST_SERIAL boot ',
              'sh /usr/lib/liuqin/install-layout.sh <boot_id> apply persist',
              'install-root.sh', 'ERASE-LIUQIN-USERDATA',
              'DRY-RUN: would run: fastboot -s TEST_SERIAL flash boot_b ',
              'DRY-RUN: would run: fastboot -s TEST_SERIAL --set-active=b',
              'DRY-RUN COMPLETE')),
          result.stdout[-2000:])
    expected_padded = hashlib.sha256(
        (bundle / 'boot.img').read_bytes() +
        bytes(BOOT_BYTES - (bundle / 'boot.img').stat().st_size)).hexdigest()
    check('dry-run reports the zero-filled 192 MiB boot digest',
          expected_padded in result.stdout, 'expected ' + expected_padded)
    check('dry-run creates no backup directory', not backup.exists())
    no_mutation(log, 'dry-run linux-only')
    check('dry-run executed only read-only Fastboot queries',
          log.exists() and all(tokens and tokens[0] == 'getvar' for tokens, _ in commands(log)),
          log.read_text() if log.exists() else 'no log')

    # Refusal branches: each must stop before any write and before booting the
    # RAM installer.
    cases = (
        ('wrong product', {'product': 'pipa'}, 'product', ['--simulate-gpt',
                                                           str(gpt_fixture(work, layout, 'stock'))]),
        ('locked bootloader', {'unlocked': 'no'}, 'unlocked', []),
        ('userdata below 16 GiB', {'userdata': hex(8 * 1024 ** 3)}, '16 GiB', []),
        ('boot_b size mismatch', {'boot_b': hex(BOOT_BYTES + 4096)}, 'boot_b is', []),
        ('max-download-size too small', {'max-download-size': hex(184 * 1024 ** 2)},
         'max-download-size', []),
    )
    for name, values, fragment, extra in cases:
        fixture.write_text('')
        write_fixture(fixture, **values)
        result = run(PROJECT, bundle, fakebin, fixture, base + extra, log)
        assert_refused(name, result, fragment, log)
        write_fixture(fixture)

    # Unrecognised partition table: refuse to change it.
    unknown = gpt_fixture(work, layout, 'unknown')
    result = run(PROJECT, bundle, fakebin, fixture,
                 base + ['--simulate-gpt', str(unknown)], log)
    assert_refused('unrecognised GPT is refused', result, '分区表无法识别', log)
    check('unrecognised GPT points at the restore command',
          '--restore-partition-table' in result.stderr, result.stderr)

    # A split layout needs --keep-home; with it the rehearsal keeps /home.
    split = gpt_fixture(work, layout, 'split')
    result = run(PROJECT, bundle, fakebin, fixture,
                 base + ['--simulate-gpt', str(split)], log)
    assert_refused('split layout without --keep-home is refused', result,
                   'pass --keep-home', log)
    result = run(PROJECT, bundle, fakebin, fixture,
                 ['--serial', 'TEST_SERIAL', '--erase-userdata', '--layout', 'linux-only',
                  '--allow-unverified', '--yes', '--dry-run', '--keep-home', '--no-backup',
                  '--simulate-gpt', str(split)], log)
    check('split layout with --keep-home rehearses the reinstall', result.returncode == 0 and
          'DRY-RUN COMPLETE' in result.stdout and 'KEEP-HOME' in result.stdout,
          result.stdout[-800:] + result.stderr[-800:])
    no_mutation(log, 'split keep-home')

    # Restore/recovery path: a valid saved GPT finishes in dry-run, a corrupt
    # or foreign one is refused locally before any device access.
    saved_dir = work / 'saved-backup'
    (saved_dir / 'gpt').mkdir(parents=True)
    head = b'A' * (6 * 4096)
    tail = b'B' * (6 * 4096)
    (saved_dir / 'gpt/sda-head.bin').write_bytes(head)
    (saved_dir / 'gpt/sda-tail.bin').write_bytes(tail)
    manifest = {'serial': 'TEST_SERIAL', 'disk': '/dev/sda', 'sector_size': 4096,
                'sectors': 61731840,
                'files': {'sda-head.bin': sha(saved_dir / 'gpt/sda-head.bin'),
                          'sda-tail.bin': sha(saved_dir / 'gpt/sda-tail.bin')}}
    (saved_dir / 'gpt/manifest.json').write_text(json.dumps(manifest))
    restore_args = ['--restore-partition-table', str(saved_dir), '--serial', 'TEST_SERIAL',
                    '--allow-unverified', '--dry-run']
    result = run(PROJECT, bundle, fakebin, fixture, restore_args, log)
    check('dry-run restore validates and rehearses the saved GPT', result.returncode == 0 and
          'restore-gpt persist' in result.stdout and 'DRY-RUN COMPLETE' in result.stdout,
          result.stdout[-800:] + result.stderr[-800:])
    no_mutation(log, 'dry-run restore')
    manifest['serial'] = 'ANOTHER_TABLET'
    (saved_dir / 'gpt/manifest.json').write_text(json.dumps(manifest))
    result = run(PROJECT, bundle, fakebin, fixture, restore_args, log)
    assert_refused('restore refuses a backup from another tablet', result, 'serial', log)
    manifest['serial'] = 'TEST_SERIAL'
    (saved_dir / 'gpt/manifest.json').write_text(json.dumps(manifest))
    (saved_dir / 'gpt/sda-head.bin').write_bytes(b'corrupted')
    result = run(PROJECT, bundle, fakebin, fixture, restore_args, log)
    assert_refused('restore refuses a corrupted saved GPT', result, 'manifest', log)

    # Mode/flag combinations that must never reach a device.
    result = run(PROJECT, bundle, fakebin, fixture,
                 ['--serial', 'TEST_SERIAL', '--layout', 'linux-only', '--allow-unverified',
                  '--simulate-gpt', str(split)], log)
    assert_refused('--simulate-gpt requires --dry-run', result, 'only applies to --dry-run', log)
    result = run(PROJECT, bundle, fakebin, fixture, ['--check', '--dry-run'], log)
    assert_refused('--check and --dry-run cannot be combined', result, 'separate actions', log)
    result = run(PROJECT, bundle, fakebin, fixture, ['--check', '--yes-write-device'], log)
    assert_refused('--check cannot be combined with --yes-write-device', result,
                   'never accesses a device', log)

    # A Fedora bundle extension is validated when present.
    fedora_ok = {'fedora_release': 44, 'contract': '/etc/liuqin-fedora-root.contract',
                 'rootfs_manifest': 'a' * 64, 'runtime_manifest': 'b' * 64}
    make_bundle(bundle, fedora=fedora_ok)
    result = subprocess.run([sys.executable, str(INSTALL), '--bundle', str(bundle),
                             '--check'], capture_output=True, text=True)
    check('a well-formed Fedora bundle extension is accepted', result.returncode == 0,
          result.stderr)
    bad = dict(fedora_ok, contract='/etc/liuqin-native-root.contract')
    make_bundle(bundle, fedora=bad)
    result = subprocess.run([sys.executable, str(INSTALL), '--bundle', str(bundle),
                             '--check'], capture_output=True, text=True)
    check('a Fedora bundle naming another contract is refused',
          result.returncode != 0 and 'liuqin-fedora-root.contract' in result.stderr,
          result.stderr)
    make_bundle(bundle)

    # The dry-run needs the kernel release the RAM installer must match.
    manifest = json.loads((bundle / 'bundle.json').read_text())
    manifest.pop('kernel_release')
    (bundle / 'bundle.json').write_text(json.dumps(manifest))
    result = run(PROJECT, bundle, fakebin, fixture,
                 ['--serial', 'TEST_SERIAL', '--backup', str(backup), '--erase-userdata',
                  '--layout', 'linux-only', '--allow-unverified', '--yes', '--dry-run'], log)
    assert_refused('a bundle without kernel_release is refused before the RAM boot', result,
                   'kernel_release', log)
    make_bundle(bundle)

if failures:
    sys.exit('dry-run test failures:\n' + '\n'.join('  ' + item for item in failures))
print('PASS: host installer dry-run flow, refusal branches and restore rehearsal; no device used')
