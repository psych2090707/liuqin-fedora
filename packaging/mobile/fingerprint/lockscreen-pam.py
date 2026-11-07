#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Point the KDE lock screen fingerprint service at the liuqin PAM stack.

kscreenlocker 6.7 treats PAM_AUTHINFO_UNAVAIL from its fingerprint service as
permanent for the running lock screen. pam_fprintd returns exactly that after
its default 30 second timeout, so fingerprint unlock silently stops working
30 seconds after locking. liuqin-kde-fingerprint-auth keeps authselect's
fingerprint-auth flow but lets pam_fprintd wait without a timeout.

Only the single "auth substack fingerprint-auth" line of kde-fingerprint is
switched; account/password/session stay on authselect's fingerprint-auth.
Unknown file contents are refused. --revert restores the original line.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess

SERVICE = 'etc/pam.d/kde-fingerprint'
STACK = 'etc/pam.d/liuqin-kde-fingerprint-auth'
ORIGINAL = re.compile(r'^auth(\s+)substack(\s+)fingerprint-auth\s*$')
APPLIED = re.compile(r'^auth(\s+)substack(\s+)liuqin-kde-fingerprint-auth\s*$')


def state(lines):
    original = [i for i, line in enumerate(lines) if ORIGINAL.match(line)]
    applied = [i for i, line in enumerate(lines) if APPLIED.match(line)]
    if len(original) + len(applied) != 1:
        raise ValueError('unexpected kde-fingerprint auth stack; review it manually')
    return ('original', original[0]) if original else ('applied', applied[0])


def run(root, action):
    root = Path(root).resolve()
    service = root / SERVICE
    stack = root / STACK
    if service.is_symlink() or not service.is_file():
        raise ValueError('kde-fingerprint PAM service missing or redirected')
    if not stack.is_file() or 'pam_fprintd.so timeout=-1' not in stack.read_text():
        raise ValueError('liuqin-kde-fingerprint-auth stack missing')
    if action == 'apply' and root == Path('/'):
        current = subprocess.run(['authselect', 'current', '--raw'], capture_output=True,
                                 text=True, check=True).stdout.split()
        if 'with-fingerprint' not in current:
            raise ValueError('authselect with-fingerprint is not enabled')
    text = service.read_text()
    lines = text.split('\n')
    current, index = state(lines)
    wanted = {'apply': 'applied', 'revert': 'original'}.get(action, current)
    if current == wanted:
        print(f'lockscreen_fingerprint_pam={current}')
        return current
    if wanted == 'applied':
        lines[index] = ORIGINAL.sub(r'auth\1substack\2liuqin-kde-fingerprint-auth', lines[index])
    else:
        lines[index] = APPLIED.sub(r'auth\1substack\2fingerprint-auth', lines[index])
    status = service.stat()
    temporary = service.with_name(service.name + '.liuqin-new')
    if temporary.exists():
        raise ValueError('preserve existing temporary file')
    try:
        temporary.write_text('\n'.join(lines))
        os.chmod(temporary, status.st_mode & 0o7777)
        if os.geteuid() == 0:
            os.chown(temporary, status.st_uid, status.st_gid)
        temporary.replace(service)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'lockscreen_fingerprint_pam={wanted}')
    return wanted


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path('/'))
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--apply', action='store_true')
    group.add_argument('--revert', action='store_true')
    args = parser.parse_args()
    run(args.root, 'apply' if args.apply else 'revert' if args.revert else 'check')
