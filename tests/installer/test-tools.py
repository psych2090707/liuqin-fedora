#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for the installer tooling and the test simulator.

Covers build-runtime.py --verify, assemble-installer.py (contract v2 embedding
and validation), the shell syntax of every shipped script and the fake-fastboot
simulator itself.  The two duplicate v1 entry points (installer/make-bundle.py,
installer/make-root-contract.py) were removed under ADR-0004 D1: bundle.json is
produced only by scripts/build-image.sh and the admission contract only by
tools/build-root-contract.py, both exercised against real products by
tests/installer/install-simulation.sh.

No device access; all work happens in temporary directories.
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
INSTALLER = PROJECT / 'installer'
TESTS = Path(__file__).resolve().parent
PYTHON = sys.executable
failures = []


def check(name, condition, detail=''):
    if condition:
        print('PASS: ' + name)
    else:
        failures.append(name + (': ' + detail if detail else ''))
        print('FAIL: ' + name + (': ' + detail if detail else ''))


def run(arguments, env=None, cwd=None):
    return subprocess.run([str(item) for item in arguments], capture_output=True, text=True,
                          env=env, cwd=cwd)


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


with tempfile.TemporaryDirectory(prefix='liuqin-tools-test-') as temporary:
    work = Path(temporary)

    # --- build-runtime.py --verify and assemble-installer.py --------------
    runtime = PROJECT / 'out/installer/runtime'
    overlay = PROJECT / 'out/installer/image-overlay'
    if runtime.is_dir():
        verified = run([PYTHON, INSTALLER / 'build-runtime.py', '--verify', runtime])
        check('the built Fedora installer runtime verifies', verified.returncode == 0,
              verified.stdout + verified.stderr)
        broken = work / 'runtime-broken'
        shutil.copytree(runtime, broken)
        with (broken / 'usr/bin/tar').open('ab') as stream:
            stream.write(b'\x00tampered')
        tampered = run([PYTHON, INSTALLER / 'build-runtime.py', '--verify', broken])
        check('build-runtime --verify refuses a tampered runtime', tampered.returncode != 0 and
              'hash mismatch' in tampered.stderr, tampered.stderr)
        assembled = work / 'overlay'
        result = run([PYTHON, INSTALLER / 'assemble-installer.py', '--runtime', runtime,
                      '--out', assembled, '--source-date-epoch', '0'])
        image = json.loads((assembled / 'installer-image.json').read_text()) \
            if (assembled / 'installer-image.json').is_file() else {}
        check('assemble-installer builds the RAM-installer overlay',
              result.returncode == 0 and
              (assembled / 'etc/liuqin-installer').read_text() == 'liuqin\n' and
              (assembled / 'etc/liuqin-storage-mode').read_text() == 'readonly\n' and
              (assembled / 'usr/lib/liuqin/install-root.sh').is_file() and
              image.get('role') == 'ram-installer' and
              image.get('required_boot_builder', {}).get('boot_image_inputs'),
              result.stdout + result.stderr)
        again = run([PYTHON, INSTALLER / 'assemble-installer.py', '--runtime', runtime,
                     '--out', assembled, '--source-date-epoch', '0'])
        check('assemble-installer refuses to overwrite an overlay', again.returncode != 0 and
              'new directory' in again.stderr, again.stderr)
        bad_contract = work / 'bad.contract'
        bad_contract.write_text('not a contract\n')
        bad = run([PYTHON, INSTALLER / 'assemble-installer.py', '--runtime', runtime,
                   '--out', work / 'overlay-bad', '--contract', bad_contract])
        check('assemble-installer refuses a malformed root contract', bad.returncode != 0,
              bad.stderr)
        v1_contract = work / 'v1.contract'
        v1_contract.write_text('LIUQIN_FEDORA_ROOT_CONTRACT_V1\n' +
                               '0' * 64 + '  /etc/fstab\n')
        v1 = run([PYTHON, INSTALLER / 'assemble-installer.py', '--runtime', runtime,
                  '--out', work / 'overlay-v1', '--contract', v1_contract])
        check('assemble-installer refuses the obsolete v1 contract',
              v1.returncode != 0 and 'CONTRACT_V2' in v1.stderr, v1.stderr)
        real_contract = PROJECT / 'out/boot/initramfs/liuqin-fedora-root.contract'
        if real_contract.is_file() and real_contract.read_text().startswith(
                'LIUQIN_FEDORA_ROOT_CONTRACT_V2'):
            with_contract = work / 'overlay-contract'
            result = run([PYTHON, INSTALLER / 'assemble-installer.py', '--runtime', runtime,
                          '--out', with_contract, '--contract', real_contract])
            embedded = with_contract / 'etc/liuqin-fedora-root.contract'
            image = json.loads((with_contract / 'installer-image.json').read_text()) \
                if (with_contract / 'installer-image.json').is_file() else {}
            check('assemble-installer embeds the real generated contract v2 unchanged',
                  result.returncode == 0 and embedded.is_file() and
                  embedded.read_bytes() == real_contract.read_bytes() and
                  image.get('contract', {}).get('sha256') == sha(real_contract),
                  result.stdout + result.stderr)
        else:
            print('SKIP: no generated contract v2 at out/boot/initramfs yet')
        empty_scripts = work / 'empty-scripts'
        empty_scripts.mkdir()
        missing_scripts = run([PYTHON, INSTALLER / 'assemble-installer.py', '--runtime', runtime,
                               '--out', work / 'overlay-missing', '--scripts', empty_scripts])
        check('assemble-installer refuses a missing device-side script',
              missing_scripts.returncode != 0 and 'missing device-side script' in missing_scripts.stderr,
              missing_scripts.stderr)
    else:
        print('SKIP: out/installer/runtime is not built; run scripts/build-installer.sh first')
    _ = overlay

    # --- fake-fastboot simulator -----------------------------------------
    simulator = TESTS / 'fake-fastboot'
    log = work / 'sim.log'
    fixture = work / 'device.fixture'
    fixture.write_text('product=liuqin\nunlocked=yes\nserial=TEST_SERIAL\n'
                       'boot_a=0xc000000\nmax-download-size=0x30000000\n')
    env = dict(os.environ, FAKE_FASTBOOT_LOG=str(log), FAKE_FASTBOOT_FIXTURE=str(fixture))
    product = run([simulator, '-s', 'TEST_SERIAL', 'getvar', 'product'], env=env)
    size = run([simulator, '-s', 'TEST_SERIAL', 'getvar', 'partition-size:boot_a'], env=env)
    check('fake-fastboot answers the getvar queries the installer parses',
          'product: liuqin' in product.stdout and
          'partition-size:boot_a: 0xc000000' in size.stdout and
          'getvar product' in log.read_text(), product.stdout + size.stdout)
    writing = run([simulator, '-s', 'TEST_SERIAL', 'flash', 'boot_a', '/tmp/x'], env=env)
    check('fake-fastboot records a write and answers OKAY', writing.returncode == 0 and
          'WROTE' in log.read_text(), writing.stdout + writing.stderr)
    refuse_env = dict(env, FAKE_FASTBOOT_REFUSE_WRITES='1')
    refused = run([simulator, '-s', 'TEST_SERIAL', 'flash', 'boot_a', '/tmp/x'], env=refuse_env)
    check('fake-fastboot can refuse writes so a test proves nothing was flashed',
          refused.returncode != 0 and 'REFUSED' in log.read_text(), refused.stdout + refused.stderr)

# --- shell syntax of every shipped script ---------------------------------
scripts = sorted((PROJECT / 'installer/lib').glob('*.sh')) + [
    PROJECT / 'scripts/build-installer.sh',
    PROJECT / 'tests/installer/test-layout-sh.sh',
    PROJECT / 'tests/installer/test-install-root.sh',
    PROJECT / 'tests/installer/run-all.sh',
]
for script in scripts:
    result = run(['sh', '-n', script])
    check('sh -n ' + str(script.relative_to(PROJECT)), result.returncode == 0,
          result.stderr.strip())

if failures:
    sys.exit('tooling test failures:\n' + '\n'.join('  ' + item for item in failures))
print('PASS: installer tooling (runtime, contract v2 overlay, simulator); no device access')
