#!/usr/bin/env python3
"""Session routing without starting IBus, a desktop, or contacting the tablet."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / 'overlays/gnome/etc/profile.d/zz-liuqin-wayland-input.sh'


class InputRouting(unittest.TestCase):
    def routed(self, desktop, kind='wayland'):
        env = dict(os.environ, XDG_CURRENT_DESKTOP=desktop, XDG_SESSION_TYPE=kind,
                   GTK_IM_MODULE='fcitx', QT_IM_MODULE='fcitx', XMODIFIERS='@im=fcitx',
                   QT_IM_MODULES='wayland;fcitx;ibus')
        script = '. "$1"; env'
        result = subprocess.run(['sh', '-c', script, 'test', str(PROFILE)],
                                env=env, capture_output=True, text=True, check=True)
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)

    def test_gnome_has_no_fcitx_fallback(self):
        for name in ('GNOME', 'GNOME:GNOME-Classic'):
            env = self.routed(name)
            self.assertEqual(env['QT_IM_MODULES'], 'wayland;ibus')
            self.assertNotIn('GTK_IM_MODULE', env,
                'GNOME Wayland GTK must use text-input-v3, not GTK IBus')
            self.assertEqual(env['QT_IM_MODULE'], 'ibus')
            self.assertEqual(env['XMODIFIERS'], '@im=ibus')

    def test_recovery_plasma_keeps_native_wayland(self):
        env = self.routed('KDE')
        self.assertNotIn('GTK_IM_MODULE', env)
        self.assertNotIn('QT_IM_MODULE', env)
        self.assertEqual(env['XMODIFIERS'], '@im=fcitx')
        self.assertEqual(env['SDL_IM_MODULE'], 'fcitx')

    def test_unrelated_sessions_unchanged(self):
        self.assertEqual(self.routed('notGNOME')['GTK_IM_MODULE'], 'fcitx')
        self.assertEqual(self.routed('GNOME', 'tty')['GTK_IM_MODULE'], 'fcitx')

    def test_system_defaults_match_gnome_route(self):
        path = ROOT / 'overlays/gnome/etc/environment.d/60-liuqin-input.conf'
        defaults = dict(line.split('=', 1) for line in path.read_text().splitlines()
                        if line and not line.startswith('#'))
        env = self.routed('GNOME')
        self.assertNotIn('GTK_IM_MODULE', env)
        for key, value in defaults.items():
            self.assertEqual(env[key], value)


if __name__ == '__main__':
    unittest.main()
