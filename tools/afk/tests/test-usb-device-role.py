#!/usr/bin/python3
# SPDX-License-Identifier: MIT
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('role', Path(__file__).resolve().parents[3] / 'overlays/afk/files/usr/libexec/liuqin/usb-device-role.py')
role = importlib.util.module_from_spec(spec)
spec.loader.exec_module(role)


class Policy(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for name, data in {
                'etc/liuqin-slpi-disabled': '',
                'sys/class/usb_role/a600000.usb-role-switch/role': 'host',
                'sys/class/typec/port0/data_role': 'host [device]',
                'sys/kernel/config/usb_gadget/liuqin/UDC': 'a600000.usb'}.items():
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(data)
        self.control = self.root / 'sys/class/usb_role/a600000.usb-role-switch/role'

    def tearDown(self):
        self.temp.cleanup()

    def test_mismatch_and_idempotence(self):
        self.assertEqual(role.reconcile(self.root), 'corrected_device')
        self.assertEqual(role.reconcile(self.root), 'already_device')

    def test_real_host_not_overridden(self):
        (self.root / 'sys/class/typec/port0/data_role').write_text('[host] device')
        self.assertEqual(role.reconcile(self.root), 'connector_not_device')
        self.assertEqual(self.control.read_text(), 'host')

    def test_unbound_gadget_not_activated(self):
        (self.root / 'sys/kernel/config/usb_gadget/liuqin/UDC').write_text('')
        self.assertEqual(role.reconcile(self.root), 'gadget_not_bound')
        self.assertEqual(self.control.read_text(), 'host')

    def test_missing_safety_marker(self):
        (self.root / 'etc/liuqin-slpi-disabled').unlink()
        self.assertEqual(role.reconcile(self.root), 'unavailable')
        self.assertEqual(self.control.read_text(), 'host')


if __name__ == '__main__':
    unittest.main()
