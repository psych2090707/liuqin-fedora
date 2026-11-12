#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Render the real keyboard extension in an isolated headless GNOME Shell.

Reuses the established integration fixture. No windows, input simulation,
real desktop D-Bus connection or tablet access. Screenshots are captured by
Shell itself at the keyboard actor's bounds; no redrawing or image editing.
Requires GNOME Shell 51. Keep logs/provenance separate from public images.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--variant', action='append', choices=('light', 'dark'),
                        help='render selected variants (default: both)')
    parser.add_argument('--accent', default='purple', choices=(
        'blue', 'teal', 'green', 'yellow', 'orange', 'red', 'pink', 'purple', 'slate'))
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.evidence = args.evidence.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    args.evidence.mkdir(parents=True, exist_ok=True)
    source = PROJECT / 'overlays/gnome-local/keyboard/extension'
    version = subprocess.check_output(['gnome-shell', '--version'], text=True).strip()
    report = {'renderer': version, 'accent': args.accent,
              'fixture': 'tests/desktop-admission/keyboard-render',
              'device_screenshot': False, 'sample_candidates': True,
              'images': {}, 'extension_sha256': {}}
    for path in sorted(source.iterdir()):
        if path.is_file():
            with path.open('rb') as stream:
                report['extension_sha256'][path.name] = hashlib.file_digest(stream, 'sha256').hexdigest()
    for variant in args.variant or ('light', 'dark'):
        with tempfile.TemporaryDirectory(prefix='liuqin-keyboard-render-') as temporary:
            work = Path(temporary)
            extensions = work / 'data/gnome-shell/extensions'
            extensions.mkdir(parents=True)
            shutil.copytree(source, extensions / 'liuqin-tablet-keyboard@liuqin')
            shutil.copytree(PROJECT / 'tests/desktop-admission/keyboard-render', extensions / 'kbint@local')
            runtime = work / 'runtime'
            runtime.mkdir(mode=0o700)
            env = dict(os.environ, XDG_CONFIG_HOME=str(work / 'config'),
                       XDG_DATA_HOME=str(work / 'data'), XDG_CACHE_HOME=str(work / 'cache'),
                       XDG_RUNTIME_DIR=str(runtime), KBINT_OUT=str(args.out / ('keyboard-' + variant + '.png')),
                       KBINT_TEXT='ni hao |', KBINT_MODE='osk', KBINT_BOUNDS='keyboard',
                       XDG_CURRENT_DESKTOP='GNOME')
            for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
                env.pop(key, None)
            # All settings below belong to this private D-Bus/XDG environment.
            script = '''set -eu
            gsettings set org.gnome.shell enabled-extensions "['liuqin-tablet-keyboard@liuqin','kbint@local']"
            gsettings set org.gnome.shell disable-user-extensions false
            gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
            gsettings set org.gnome.desktop.interface color-scheme "$1"
            gsettings set org.gnome.desktop.interface accent-color "$2"
            gsettings set org.gnome.desktop.interface font-name 'Noto Sans 11'
            exec gnome-shell --headless --wayland --no-x11 --virtual-monitor 1152x720
            '''
            completed = subprocess.run(['dbus-run-session', '--', 'bash', '-c', script, 'keyboard-render',
                                        'prefer-' + variant, args.accent],
                                       env=env, capture_output=True, text=True, timeout=60)
            log = completed.stdout + completed.stderr
            (args.evidence / (variant + '.log')).write_text(log + '\nprocess_returncode=' + str(completed.returncode) + '\n')
            output = args.out / ('keyboard-' + variant + '.png')
            # The dummy display's shutdown can make dbus-run-session return
            # nonzero after a completed render. Require all fixture phases and
            # the saved screenshot instead of treating teardown as acceptance.
            if 'kbint: FAIL' in log or 'JS ERROR' in log or not output.is_file():
                raise RuntimeError('Keyboard render failed; inspect ' + str(args.evidence / (variant + '.log')))
            checks = [line for line in log.splitlines() if 'kbint:' in line]
            assert any('pills=5' in line for line in checks), checks
            assert any('suggestions=5 selected=0' in line for line in checks), checks
            assert any('phase2 selected=2' in line for line in checks), checks
            assert any('phase3 hidden=true' in line for line in checks), checks
            assert any('saved ' in line for line in checks), checks
            report['images'][output.name] = {'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                                            'bytes': output.stat().st_size,
                                            'process_returncode': completed.returncode,
                                            'teardown_clean': completed.returncode == 0,
                                            'integration_checks': [line.replace(str(args.out), '<output>') for line in checks]}
            print('Rendered', output, flush=True)
            if completed.returncode:
                print('Headless Shell teardown exited', completed.returncode,
                      'after capture/checks; recorded as unclean, not a stability pass.', flush=True)
    (args.evidence / 'render.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
