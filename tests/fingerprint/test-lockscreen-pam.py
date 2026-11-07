#!/usr/bin/env python3
"""KDE lock screen fingerprint PAM redirect (TN0064): apply/revert/refusal."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
# Fedora 44 plasma-workspace-6.7.5-1 /etc/pam.d/kde-fingerprint
FEDORA_KDE_FINGERPRINT = '''auth        substack      fingerprint-auth
auth        include       postlogin

account     required      pam_nologin.so
account     include       fingerprint-auth

password    include       fingerprint-auth

session     required      pam_selinux.so close
session     required      pam_loginuid.so
session     required      pam_selinux.so open
session     optional      pam_keyinit.so force revoke
session     required      pam_namespace.so
session     include       fingerprint-auth
session     include       postlogin
'''


def load():
    spec = importlib.util.spec_from_file_location(
        'lockscreen_pam', PROJECT / 'packaging/mobile/fingerprint/lockscreen-pam.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LockscreenPam(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.stage = Path(cls.temp.name) / 'support'
        subprocess.run(['python3', str(PROJECT / 'packaging/mobile/fingerprint/stage-payload.py'),
                        str(PROJECT / 'upstream/xiaomipad-6pro-mainline/device/fingerprint/oem'),
                        str(cls.stage)], check=True, capture_output=True)
        cls.module = load()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def root(self, temporary, content=FEDORA_KDE_FINGERPRINT):
        root = Path(temporary)
        pam = root / 'etc/pam.d'
        pam.mkdir(parents=True)
        (pam / 'kde-fingerprint').write_text(content)
        stack = self.stage / 'payload/etc/pam.d/liuqin-kde-fingerprint-auth'
        (pam / stack.name).write_text(stack.read_text())
        return root

    def test_staged_stack_mirrors_authselect_without_timeout(self):
        lines = [line for line in (self.stage / 'payload/etc/pam.d/liuqin-kde-fingerprint-auth')
                 .read_text().splitlines() if line and not line.startswith('#')]
        self.assertEqual([next(t for t in line.split() if t.endswith('.so')) for line in lines],
                         ['pam_env.so', 'pam_fprintd.so', 'pam_deny.so'])
        self.assertTrue(lines[1].endswith('pam_fprintd.so timeout=-1'))
        self.assertIn('[success=done default=bad]', lines[1])
        tool = self.stage / 'payload/usr/bin/liuqin-fingerprint-lockscreen'
        self.assertTrue(tool.is_file() and tool.stat().st_mode & 0o111)

    def test_apply_revert_only_touch_the_auth_substack(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.root(temporary)
            service = root / 'etc/pam.d/kde-fingerprint'
            service.chmod(0o644)
            self.assertEqual(self.module.run(root, 'check'), 'original')
            self.assertEqual(self.module.run(root, 'apply'), 'applied')
            applied = service.read_text()
            self.assertEqual(applied.splitlines()[0],
                             'auth        substack      liuqin-kde-fingerprint-auth')
            self.assertEqual(applied.splitlines()[1:], FEDORA_KDE_FINGERPRINT.splitlines()[1:])
            self.assertEqual(service.stat().st_mode & 0o777, 0o644)
            self.assertEqual(self.module.run(root, 'apply'), 'applied')
            self.assertEqual(service.read_text(), applied)
            self.assertEqual(self.module.run(root, 'revert'), 'original')
            self.assertEqual(service.read_text(), FEDORA_KDE_FINGERPRINT)

    def test_unknown_service_and_missing_stack_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.root(temporary, FEDORA_KDE_FINGERPRINT.replace(
                'auth        substack      fingerprint-auth', 'auth sufficient pam_fprintd.so'))
            with self.assertRaisesRegex(ValueError, 'unexpected'):
                self.module.run(root, 'apply')
        with tempfile.TemporaryDirectory() as temporary:
            root = self.root(temporary)
            (root / 'etc/pam.d/liuqin-kde-fingerprint-auth').unlink()
            with self.assertRaisesRegex(ValueError, 'stack missing'):
                self.module.run(root, 'apply')
            self.assertEqual((root / 'etc/pam.d/kde-fingerprint').read_text(), FEDORA_KDE_FINGERPRINT)

    def test_fprintd_patch_targets_verify_only(self):
        patch = (PROJECT / 'packaging/mobile/patches/fingerprint/'
                 '0005-fprintd-recheck-verify-after-transient-logind-inactivity.patch').read_text()
        added = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+'))
        self.assertIn('g_strcmp0 (action, "net.reactivated.fprint.device.verify") == 0', added)
        self.assertIn('LIUQIN_TRANSIENT_WAIT_MS 5000', added)
        self.assertIn('LIUQIN_TRANSIENT_SETTLE_MS 1000', added)
        self.assertIn('state == LIUQIN_DISPLAY_NONE', added)
        self.assertIn('POLKIT_CHECK_AUTHORIZATION_FLAGS_NONE', added)
        self.assertNotIn('get_is_authorized (result) = ', added)
        spec = (PROJECT / 'packaging/mobile/specs/fprintd-oem.spec').read_text()
        self.assertIn('< %{SOURCE5}', spec)
        self.assertIn('< %{SOURCE6}', spec)

    def test_fprintd_claim_defers_only_busy_open(self):
        patch = (PROJECT / 'packaging/mobile/patches/fingerprint/'
                 '0006-fprintd-defer-claim-while-device-is-suspended.patch').read_text()
        added = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+'))
        self.assertIn('g_error_matches (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_BUSY)', added)
        self.assertIn('retries >= LIUQIN_OPEN_RETRIES', added)
        self.assertIn('LIUQIN_OPEN_RETRIES 40', added)


if __name__ == '__main__':
    unittest.main()
