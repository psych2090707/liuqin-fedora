#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Windows-only: run install.py --dry-run with a compiled fake Fastboot.

The POSIX ``fake-fastboot`` simulator cannot be executed by CreateProcess on
Windows, so this test compiles a tiny C# console program with the .NET
Framework compiler already present on Windows runners.  It answers the same
read-only getvar queries, records every command, and refuses writes.  No
device, USB or admin access is involved.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / 'gpt-stock'
failures = []


def check(name, condition, detail=''):
    if condition:
        print('PASS: ' + name)
    else:
        failures.append(name + (': ' + detail if detail else ''))
        print('FAIL: ' + name + (': ' + detail if detail else ''))


if os.name != 'nt':
    print('SKIP: Windows-only fake Fastboot dry-run (POSIX simulator covers the other hosts)')
    raise SystemExit(0)

CSHARP = r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

class FakeFastboot
{
    static int Main(string[] args)
    {
        string log = Environment.GetEnvironmentVariable("FAKE_FASTBOOT_LOG");
        if (!String.IsNullOrEmpty(log))
            File.AppendAllText(log, String.Join(" ", args) + "\n");
        if (args.Length >= 2 && args[0] == "-s")
            args = args.Skip(2).ToArray();
        if (args.Length >= 2 && args[0] == "getvar")
        {
            string product = Environment.GetEnvironmentVariable("FAKE_PRODUCT") ?? "liuqin";
            var values = new Dictionary<string, string>
            {
                { "product", product },
                { "unlocked", "yes" },
                { "battery-soc-ok", "yes" },
                { "battery-voltage", "4200" },
                { "current-slot", "a" },
                { "partition-size:userdata", "0x1000000000" },
                { "partition-size:boot_a", "0xc000000" },
                { "partition-size:boot_b", "0xc000000" },
                { "max-download-size", "0x30000000" },
            };
            string value;
            Console.WriteLine(args[1] + ": " +
                (values.TryGetValue(args[1], out value) ? value : "unknown"));
            return 0;
        }
        string[] mutating = { "boot", "flash", "erase", "format", "flashall",
                              "update", "reboot", "reboot-bootloader", "oem" };
        if (args.Length > 0 && mutating.Contains(args[0]))
        {
            if (Environment.GetEnvironmentVariable("FAKE_FASTBOOT_REFUSE_WRITES") == "1")
            {
                Console.WriteLine("REFUSED " + String.Join(" ", args));
                return 1;
            }
            Console.WriteLine("WROTE " + String.Join(" ", args));
        }
        return 0;
    }
}
'''


def compile_fake(directory):
    source = directory / 'fake_fastboot.cs'
    source.write_text(CSHARP)
    executable = directory / 'fastboot.exe'
    candidates = [
        Path(os.environ.get('WINDIR', r'C:\Windows')) /
        r'Microsoft.NET\Framework64\v4.0.30319\csc.exe',
        Path(os.environ.get('WINDIR', r'C:\Windows')) /
        r'Microsoft.NET\Framework\v4.0.30319\csc.exe',
    ]
    compiler = next((path for path in candidates if path.is_file()), None)
    if compiler is None:
        raise RuntimeError('csc.exe was not found; Windows runner needs .NET Framework 4')
    result = subprocess.run([str(compiler), '/nologo', '/out:' + str(executable), str(source)],
                            capture_output=True, text=True)
    if result.returncode != 0 or not executable.is_file():
        raise RuntimeError('could not compile the fake Fastboot: ' + result.stdout + result.stderr)
    return executable


def make_bundle(directory):
    directory.mkdir(parents=True)
    files = {}
    for name in ('boot.img', 'installer.img', 'rootfs.tar.gz'):
        (directory / name).write_bytes(name.encode())
        files[name] = hashlib.sha256(name.encode()).hexdigest()
    (directory / 'bundle.json').write_text(json.dumps({
        'device': 'liuqin', 'status': 'OFFLINE_ASSEMBLED',
        'kernel_release': '6.17.0-liuqin-test', 'files': files}) + '\n')


def run(install, bundle, fake, gpt, log, backup, product=None):
    env = os.environ.copy()
    env['FAKE_FASTBOOT_LOG'] = str(log)
    env['FAKE_FASTBOOT_REFUSE_WRITES'] = '1'
    if product:
        env['FAKE_PRODUCT'] = product
    if log.exists():
        log.unlink()
    return subprocess.run([
        sys.executable, str(install), '--bundle', str(bundle),
        '--layout', 'linux-only', '--serial', 'TEST_SERIAL',
        '--backup', str(backup), '--erase-userdata', '--allow-unverified',
        '--simulate-gpt', str(gpt), '--dry-run', '--fastboot', str(fake),
    ], env=env, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='liuqin-windows-dry-run-') as temporary:
    work = Path(temporary)
    bundle = work / 'bundle'
    make_bundle(bundle)
    fake = compile_fake(work)
    log = work / 'fastboot.log'
    good = run(PROJECT / 'installer/install.py', bundle, fake, FIXTURE, log,
               work / 'backup-good')
    lines = log.read_text().splitlines() if log.exists() else []
    check('Windows fake Fastboot: the dry-run completes',
          good.returncode == 0 and 'DRY-RUN COMPLETE' in good.stdout,
          good.stdout[-800:] + good.stderr[-800:])
    check('Windows fake Fastboot: the rehearsal runs only read-only queries',
          lines and all(' getvar ' in (' ' + line + ' ') for line in lines) and
          not any(line.startswith(('WROTE', 'REFUSED')) for line in lines),
          '\n'.join(lines[:10]))

    bad = run(PROJECT / 'installer/install.py', bundle, fake, FIXTURE, log,
              work / 'backup-bad', product='not-liuqin')
    check('Windows fake Fastboot: a wrong model is refused before any write',
          bad.returncode != 0 and 'Fastboot device check failed' in bad.stderr and
          not any(line.startswith(('WROTE', 'REFUSED'))
                  for line in (log.read_text().splitlines() if log.exists() else [])),
          bad.stderr[-800:])

if failures:
    sys.exit('Windows dry-run test failures:\n' + '\n'.join('  ' + item for item in failures))
print('PASS: Windows fake Fastboot dry-run and model refusal; no device access')
