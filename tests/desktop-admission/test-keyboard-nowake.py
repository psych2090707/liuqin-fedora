#!/usr/bin/env python3
"""Static guard for the desktop-neutral keyboard-MCU wake rule.

The Nanosic keyboard cover pulses its wake line on suspend entry. The workaround
was first kept under overlays/kde and disappeared when the GNOME/F45 image was
assembled. It must stay in the desktop-neutral rootfs.d layer so a future
desktop switch cannot drop it again.
"""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / 'overlays/rootfs/rootfs.d/65-liuqin-keyboard'
RULE = LAYER / 'files/etc/udev/rules.d/71-liuqin-keyboard-nowake.rules'
OLD = ROOT / 'overlays/kde/etc/udev/rules.d/71-liuqin-keyboard-nowake.rules'


class KeyboardNowake(unittest.TestCase):
    def test_rule_is_desktop_neutral(self):
        self.assertTrue(RULE.is_file())
        self.assertFalse(OLD.exists(), 'do not keep a second copy under overlays/kde')
        text = RULE.read_text()
        self.assertIn('SUBSYSTEM=="i2c"', text)
        self.assertIn('ATTR{name}=="liuqin-keyboard"', text)
        self.assertIn('ATTR{power/wakeup}="disabled"', text)

    def test_install_script_is_executable_and_checks_the_rule(self):
        script = LAYER / 'install.sh'
        self.assertTrue(script.is_file())
        self.assertTrue(os.access(script, os.X_OK))
        text = script.read_text()
        self.assertIn('udevadm verify', text)
        self.assertIn('71-liuqin-keyboard-nowake.rules', text)

    @unittest.skipUnless(shutil.which('udevadm'), 'udevadm not available')
    def test_udevadm_verify(self):
        result = subprocess.run(['udevadm', 'verify', str(RULE)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
