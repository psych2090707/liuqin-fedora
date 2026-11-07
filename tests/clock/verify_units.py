#!/usr/bin/env python3
"""Offline unit syntax/order check in a disposable, non-booted fixture root.

The helper/units can come from an extracted RPM via the optional first argument.
Dependency targets and chronyd are stubs: this does not prove runtime behaviour.
Never starts a unit, invokes the helper, changes host services, or sets a clock.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else None
with tempfile.TemporaryDirectory(prefix='liuqin-clock-units-') as temp:
    root = Path(temp)
    units = root / 'usr/lib/systemd/system'
    units.mkdir(parents=True)
    names = ['liuqin-clock-save.service', 'liuqin-clock-shutdown.service',
             'liuqin-clock-save.timer']
    for name in names:
        origin = source / 'usr/lib/systemd/system' / name if source else repo / 'packaging/clock' / name
        shutil.copyfile(origin, units / name)
    for name in ('sysinit.target', 'basic.target', 'shutdown.target',
                 'multi-user.target', 'timers.target'):
        (units / name).write_text('[Unit]\nDescription=Offline fixture only\nDefaultDependencies=no\n')
    (units / 'chronyd.service').write_text(
        '[Unit]\nDescription=Offline chronyd stub\nAfter=basic.target\n'
        '[Service]\nType=oneshot\nExecStart=/usr/bin/true\n')
    (root / 'etc').mkdir()
    (root / 'etc/os-release').write_text('ID=fedora\nVERSION_ID=44\n')
    for path in ('usr/bin/true', 'usr/libexec/liuqin/liuqin-clock-save'):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        # verify checks executable existence; it never executes this placeholder.
        target.write_text('#!/bin/sh\nexit 125\n')
        target.chmod(0o755)
    cmd = ['systemd-analyze', 'verify', '--man=no', '--generators=no',
           '--root=' + str(root), *('/usr/lib/systemd/system/' + n for n in names)]
    print('fixture-only systemd-analyze verify (no services started)', flush=True)
    subprocess.run(cmd, check=True, env={**os.environ, 'SYSTEMD_LOG_LEVEL': 'warning'})
