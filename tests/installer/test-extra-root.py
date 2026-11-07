#!/usr/bin/env python3
"""Regression for TN0050's real parent-RO and hidden-home injection failures."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('installer_extra_root', ROOT / 'installer/install.py')
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class ExtraRoot(unittest.TestCase):
    def test_parent_gate_and_real_home_are_opened_then_relocked(self):
        for fail_extract in (False, True):
            with self.subTest(fail_extract=fail_extract):
                writable, mounts, calls = set(), {}, []

                def remote(command, timeout=60):
                    calls.append(command)
                    if 'blockdev --setrw ' in command:
                        writable.add(command.split()[-1])
                    elif 'blockdev --setro ' in command:
                        writable.remove(command.split()[-1])
                    elif command.startswith('mount -t ext4 '):
                        device, target = command.split()[-2:]
                        if '/dev/sda' not in writable or device not in writable:
                            raise RuntimeError('kernel parent/partition read-only gate')
                        mounts[target] = device
                    elif command.startswith('/usr/bin/tar '):
                        self.assertEqual(mounts.get('/run/fedora/home'), '/dev/sda37',
                                         'keys must land on the partition mounted at /home after boot')
                        if fail_extract:
                            raise RuntimeError('simulated extraction failure')
                    elif command.startswith('umount '):
                        mounts.pop(command.split()[-1])
                    elif 'blockdev --getro ' in command:
                        device = command.split('--getro ', 1)[1].split(')', 1)[0]
                        self.assertNotIn(device, writable)
                    return b''

                with patch.object(INSTALLER, 'partition_node', side_effect=['/dev/sda36', '/dev/sda37']):
                    if fail_extract:
                        with self.assertRaisesRegex(RuntimeError, 'extraction failure'):
                            INSTALLER.inject_extra_root(remote, 'http://host')
                    else:
                        INSTALLER.inject_extra_root(remote, 'http://host')
                self.assertEqual(writable, set())
                self.assertEqual(mounts, {})
                self.assertLess(calls.index('umount /run/fedora/home'), calls.index('umount /run/fedora'))

    def test_cross_disk_home_is_refused_before_any_remote_write(self):
        with patch.object(INSTALLER, 'partition_node', side_effect=['/dev/sda36', '/dev/sdb37']):
            with self.assertRaisesRegex(RuntimeError, 'same UFS disk'):
                INSTALLER.inject_extra_root(lambda *a: self.fail('unexpected write'), 'http://host')


if __name__ == '__main__':
    unittest.main()
