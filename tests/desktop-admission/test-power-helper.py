#!/usr/bin/env python3
"""Run the GNOME helper against command mocks; never contact a desktop/device."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
HELPER = PROJECT / 'overlays/gnome/usr/libexec/liuqin/gnome-power-key-action'
with tempfile.TemporaryDirectory(prefix='liuqin-power-helper-') as tmp:
    work = Path(tmp)
    state = work / 'state'
    state.mkdir()
    config = work / 'config.json'
    calls = work / 'calls.jsonl'
    mock = work / 'mock.py'
    mock.write_text('''#!/usr/bin/python3
import json, os, subprocess, sys
from pathlib import Path
config = json.loads(Path(CONFIG).read_text())
with open(CALLS, 'a') as f: f.write(json.dumps(sys.argv) + '\\n')
name=Path(sys.argv[0]).name
a=sys.argv[1:]
if name=='loginctl':
 if a[0]=='show-seat': print('1')
 elif a[0]=='show-session':
  prop=next(x.split('=',1)[1] for x in a if x.startswith('--property='))
  print({'Active':'yes','Class':'user','User':'1000','Name':'user'}[prop])
elif name=='getent': print('user:x:1000:1000::/home/user:/bin/bash')
elif name=='id': print(config.get('uid', 1000))
elif name=='chown': sys.exit(0)
elif name=='setpriv':
 a=a[a.index('--')+1:]
 if a[:2]==['/usr/bin/test','-S']: sys.exit(0)
 sys.exit(subprocess.run(a).returncode)
elif name=='gdbus':
 method=a[a.index('--method')+1]
 if method.endswith('NameHasOwner'): print('(true,)' if config['owner'] else '(false,)')
 elif method.endswith('Properties.Set'):
  if config.get('set_fail'): sys.exit(2)
  print('()')
 elif method.endswith('GetActive'): print('(true,)' if config['active'] else '(false,)')
 elif method.endswith('GetActiveTime'): print('(uint32 %s,)' % config['active_age'])
 elif method.endswith('Properties.Get'): print('(<%s>,)' % config['mode'])
 else: print('()')
elif name=='clock': print('1000000')
'''.replace('CONFIG', repr(str(config))).replace('CALLS', repr(str(calls))))
    mock.chmod(0o755)
    env = dict(os.environ, LIUQIN_STATE_DIR=str(state))
    for key in ('LOGINCTL', 'GETENT', 'SETPRIV', 'GDBUS', 'MONOTONIC_MS', 'ID', 'CHOWN'):
        link = work / ('clock' if key == 'MONOTONIC_MS' else key.lower())
        link.symlink_to(mock)
        env['LIUQIN_' + key] = str(link)

    def run(label, active, mode, prior, action, target, owner=True, active_age=100,
            set_fail=False, state_dir_missing=False, uid=1000):
        config.write_text(json.dumps(dict(active=active, mode=mode, owner=owner,
                                          active_age=active_age, set_fail=set_fail,
                                          uid=uid)))
        calls.write_text('')
        if state_dir_missing:
            for child in state.iterdir():
                child.unlink()
            state.rmdir()
        else:
            file = state / 'display-state'
            file.unlink(missing_ok=True)
            if prior:
                file.write_text(prior + '\n')
        r = subprocess.run(['sh', str(HELPER), action], env=env, capture_output=True, text=True)
        expect = 0 if owner and not set_fail else (1 if owner else 3)
        assert r.returncode == expect, (label, r.returncode, r.stderr)
        args = [json.loads(x) for x in calls.read_text().splitlines()]
        dbus = [a for a in args if Path(a[0]).name == 'gdbus']
        sets = [a for a in dbus if 'org.freedesktop.DBus.Properties.Set' in a]
        locks = [a for a in args if Path(a[0]).name == 'loginctl' and 'lock-session' in a]
        activates = [a for a in dbus if 'org.gnome.ScreenSaver.SetActive' in a]
        if target is None:
            assert not locks and not activates and (set_fail or not sets), (label, args)
        else:
            assert len(sets) == 1 and sets[0][-1] == f'<{target}>', (label, sets)
            if action.startswith('ensure-'):
                assert not locks and not activates, (label, args)
            elif target == 0:
                assert not locks and not activates, (label, args)
            else:
                assert len(locks) == 1 and locks[0][-1] == '1' and len(activates) == 1
        if action == 'short':
            assert (state / 'power-key-action').exists(), (label, 'missing marker')
        if uid == 0:
            names = [Path(a[0]).name for a in args]
            assert 'setpriv' in names and 'chown' in names, (label, names)
        print('PASS:', label)
        return r

    def state_text():
        return (state / 'display-state').read_text().strip()

    run('active unlocked screen blanks and locks selected session', False, 0, None, 'short', 3)
    run('idle wake key already lit panel: do not blank again', True, 0, None, 'short', 0)
    run('manual blank wake survives an already-on DPMS', True, 0, 'off', 'short', 0)
    run('second intentional press in same lock cycle can blank', True, 0, 'on-locked 900000', 'short', 3)
    run('next idle cycle must not reuse prior locked-on state', True, 0,
        'on-locked 900000', 'short', 0, active_age=10)
    run('legacy state without cycle metadata safely wakes', True, 0, 'on-locked', 'short', 0)
    run('long hold preserves no-action policy', False, 0, None, 'long', None)
    run('non-GNOME session is left alone', False, 0, None, 'short', None, owner=False)

    run('lid ensure-off sets DPMS 3 without locking', False, 0, None, 'ensure-off', 3)
    assert state_text().startswith('off'), state_text()
    run('lid ensure-off is idempotent', False, 0, 'off', 'ensure-off', 3)
    assert state_text().startswith('off'), state_text()
    run('lid ensure-off creates a missing runtime directory', False, 0, None,
        'ensure-off', 3, state_dir_missing=True)
    assert (state / 'display-state').exists()
    run('lid ensure-on sets DPMS 0 without unlocking', True, 0, None, 'ensure-on', 0)
    assert state_text() == 'on-locked 900000', state_text()
    run('failed ensure-off reports failure and does not cache success', False, 0, None,
        'ensure-off', None, set_fail=True)
    assert not (state / 'display-state').exists()
    run('ensure actions still require a GNOME session', False, 0, None,
        'ensure-off', None, owner=False)
    run('root helper switches to the session user for D-Bus', False, 0, None,
        'ensure-off', 3, uid=0)

