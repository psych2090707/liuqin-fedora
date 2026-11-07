#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Backport the single-panel part of KDE's lock-screen touch-exit fix.

Plasma 6.7.5 hides the password UI on MouseArea.exited, also emitted when a
touch is released. Plasma 6.8 removed this handler in favor of ActiveScreenMonitor.
Also ignore the first pointer-position event and keep active input independent
of pointer hover. Keep authentication, idle timeout and Escape.
Upstream: KDE/plasma-desktop Plasma/6.8 desktoppackage/contents/lockscreen/LockScreenUi.qml
"""
import argparse
import hashlib
from pathlib import Path
import shutil

RELATIVE = 'usr/share/plasma/shells/org.kde.plasma.desktop/contents/lockscreen/LockScreenUi.qml'
BASE_SHA = '328501780ab06cc0497a25ff48c6f027a1abed8506f0969f39a5f8bc6696181c'
OLD = '''        onExited: {
            uiVisible = false;
        }
'''
NEW = '''        // A touchscreen release also emits exited. Keep the input visible
        // until the existing inactivity timer or Escape hides it.
'''

# Additional touch fixes: the initial position must never hide a just-pressed
# prompt; password entry and the virtual keyboard do not require mouse hover.
TOUCH_REPLACEMENTS = (
    ('property bool blockUI: containsMouse && (mainStack.depth > 1 || mainBlock.mainPasswordBox.text.length > 0 || inputPanel.keyboardActive)',
     'property bool blockUI: (mainStack.depth > 1 || mainBlock.mainPasswordBox.text.length > 0 || inputPanel.keyboardActive)'),
    ('if (uiVisible) {\n                Window.window.requestActivate();',
     'if (uiVisible && Window.window) {\n                Window.window.requestActivate();'),
    ('uiVisible = seenPositionChange;',
     'if (seenPositionChange) { uiVisible = true; }'),
    ('Component.onCompleted: launchAnimation.start();',
     'Component.onCompleted: { launchAnimation.start(); uiVisible = true; }'),
    # The prompt is shown from the start, so uiVisible never changes again.
    # A lock with a grace period ignores that first start; keep asking until
    # authentication has actually started.
    ('        PropertyAnimation {\n            id: launchAnimation',
     '        Timer {\n'
     '            id: graceStartTimer\n'
     '            interval: 1000\n'
     '            repeat: true\n'
     '            running: true\n'
     '            onTriggered: authenticator.startAuthenticating()\n'
     '        }\n'
     '        Connections {\n'
     '            target: authenticator\n'
     '            function onStateChanged() { graceStartTimer.running = false; }\n'
     '        }\n'
     '\n'
     '        PropertyAnimation {\n            id: launchAnimation'),
)


def apply(root, write=False):
    root = Path(root).resolve()
    path = root / RELATIVE
    if path.is_symlink():
        raise ValueError('refuse a redirected lock-screen source')
    content = path.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    # Accept only the reviewed original, our first backport, or the complete fix.
    original = content.replace(NEW.encode(), OLD.encode())
    for before, after in TOUCH_REPLACEMENTS:
        original = original.replace(after.encode(), before.encode())
    if hashlib.sha256(original).hexdigest() != BASE_SHA:
        raise ValueError('unreviewed lock-screen version; use its upstream fix instead')
    fixed = original.replace(OLD.encode(), NEW.encode())
    for before, after in TOUCH_REPLACEMENTS:
        if fixed.count(before.encode()) != 1:
            raise ValueError('unexpected lock-screen handler count')
        fixed = fixed.replace(before.encode(), after.encode())
    if content == fixed:
        print('lockscreen_touch_fix=already-applied')
        return
    if write:
        backup_dir = root / ('var/lib/liuqin-updates/lockscreen' if root == Path('/')
                             else 'usr/share/liuqin/kde-fixes')
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup = backup_dir / 'LockScreenUi.qml.before'
        if backup.exists() and hashlib.sha256(backup.read_bytes()).hexdigest() != BASE_SHA:
            raise ValueError('preserve existing lock-screen backup')
        if not backup.exists():
            shutil.copy2(path, backup)
            backup.write_bytes(original)
        temporary = path.with_name(path.name + '.liuqin-new')
        if temporary.exists():
            raise ValueError('preserve existing temporary file')
        try:
            shutil.copy2(path, temporary)
            temporary.write_bytes(fixed)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    print(f'lockscreen_touch_fix={"applied" if write else "checked"} '
          f'before={digest} after={hashlib.sha256(fixed).hexdigest()}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    apply(args.root, args.apply)
