#!/usr/bin/env python3
"""Run inside the Fedora builder: install/remove RPM only in a disposable root."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

rpm_path = Path(sys.argv[1]).resolve()
extract_to = Path(sys.argv[2]) if len(sys.argv) > 2 else None


def run(*args):
    p = subprocess.run(args, text=True, capture_output=True, check=True)
    return p.stdout.strip()


assert not run('rpm', '-qp', '--scripts', str(rpm_path)), 'unexpected scriptlets'
assert run('rpm', '-qp', '--qf', '%{ARCH}', str(rpm_path)) == 'noarch'
files = run('rpm', '-qpl', str(rpm_path)).splitlines()
assert '/usr/lib/clock-epoch' not in files, 'runtime clock stamp must not be packaged'
assert not any(x.startswith(('/etc/', '/boot/', '/var/', '/run/')) for x in files)
with tempfile.TemporaryDirectory(prefix='liuqin-clock-rpm-') as temp:
    root = Path(temp)
    epoch = root / 'usr/lib/clock-epoch'
    epoch.parent.mkdir(parents=True)
    epoch.touch()
    stamp_ns = 1_792_281_600_123_456_789
    os.utime(epoch, ns=(stamp_ns, stamp_ns))
    run('rpm', '--root', str(root), '--initdb')
    # No dependency solving, network, scriptlets, or host RPM database writes.
    run('rpm', '--root', str(root), '--nodeps', '-i', str(rpm_path))
    assert epoch.stat().st_mtime_ns == stamp_ns
    assert not run('rpm', '--root', str(root), '--nodeps', '-V', 'liuqin-clock-support')
    helper = root / 'usr/libexec/liuqin/liuqin-clock-save'
    report = {'nevra': run('rpm', '-qp', '--qf', '%{NEVRA}', str(rpm_path)),
              'sha256': hashlib.sha256(rpm_path.read_bytes()).hexdigest(),
              'files': files, 'scripts': 'none',
              'helper_shebang': helper.read_text().splitlines()[0],
              'helper_sha256': hashlib.sha256(helper.read_bytes()).hexdigest(),
              'clock_stamp_unchanged_after_install': True}
    if extract_to:
        # Retain just the reviewed payload, not a throwaway RPM database/root.
        import shutil
        for name in files:
            p = root / name.lstrip('/')
            if p.is_file():
                target = extract_to / name.lstrip('/')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, target)
    run('rpm', '--root', str(root), '--nodeps', '-e', 'liuqin-clock-support')
    assert epoch.stat().st_mtime_ns == stamp_ns
    report['clock_stamp_unchanged_after_remove'] = True
    print(json.dumps(report, ensure_ascii=False, indent=2))
