#!/usr/bin/env python3
"""Exercise Fedora staging against the upstream runtime's actual consumers."""
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class PackagingIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.stage = Path(cls.temp.name) / 'support'
        subprocess.run(['python3', str(PROJECT / 'packaging/mobile/fingerprint/stage-payload.py'),
                        str(PROJECT / 'upstream/xiaomipad-6pro-mainline/device/fingerprint/oem'),
                        str(cls.stage)], check=True, capture_output=True)
        cls.runtime = cls.stage / 'payload/usr/libexec/liuqin-fingerprint'

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_firmware_consumer_accepts_packaged_manifest(self):
        spec = importlib.util.spec_from_file_location('provision', self.runtime / 'provision_firmware.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        hashes = module.checked_hashes(self.runtime / 'firmware')
        self.assertEqual(len(hashes), 10)
        self.assertEqual(set(p.name for p in (self.runtime / 'firmware').iterdir()), {'SHA256.json', 'NOTICE'})

    def test_module_readiness_matches_fedora(self):
        spec = importlib.util.spec_from_file_location('stable', self.runtime / 'stable_module.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.readiness_services({'deployment_mode': 'installed'}), ('display-manager',))
        self.assertEqual(module.readiness_services({}), ('sshd', 'NetworkManager', 'display-manager'))
        unit = (self.stage / 'payload/usr/lib/systemd/system/liuqin-fpc-stable-module.service').read_text()
        self.assertIn('After=display-manager.service\n', unit)
        self.assertIn('Wants=display-manager.service\n', unit)
        self.assertNotIn('plasmalogin.service', unit)
        self.assertNotIn('iio-sensor-proxy', unit)

    def test_authenticated_provider_resolves_to_rpm_path(self):
        # The upstream runtime is a Python script. Its literal provider path
        # must match the qsee-supplicant spec's flat install destination.
        text = (self.runtime / 'oem_runtime.py').read_text()
        self.assertIn('provider = here / "liuqin-rpmb-supplicant"', text)
        self.assertNotIn('here / "ufs-rpmb-provider"', text)
        spec = (PROJECT / 'packaging/mobile/specs/qsee-supplicant.spec').read_text()
        self.assertIn('%{_libexecdir}/liuqin-fingerprint/liuqin-rpmb-supplicant', spec)

    def test_native_activation_uses_scoped_tod(self):
        text = (self.stage / 'payload/usr/share/doc/liuqin-fingerprint/fprintd-native.conf').read_text()
        self.assertIn('ExecStart=/usr/libexec/liuqin-fingerprint/fprintd\n', text)
        self.assertIn('LD_LIBRARY_PATH=/usr/lib64/liuqin-fingerprint/libfprint-tod', text)
        self.assertIn('UMask=0077', text)
        self.assertTrue((self.stage / 'payload/usr/bin/liuqin-fingerprint-configure').is_file())

    def test_image_binding_checks_kernel_manifest_without_hardware(self):
        spec = importlib.util.spec_from_file_location('stage_image',
            PROJECT / 'packaging/mobile/fingerprint/stage-image.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = self.stage / 'payload'
            import shutil
            shutil.copytree(payload, root, dirs_exist_ok=True)
            (root / 'etc/os-release').write_text('ID=fedora\n')
            release = 'test-matching-kernel'
            kernel = root / 'usr/share/liuqin'
            kernel.mkdir(parents=True)
            (kernel / 'kernel.release').write_text(release + '\n')
            path = f'/usr/lib/modules/{release}/kernel/drivers/misc/fpc1264_spi_diag.ko'
            target = root / path.lstrip('/')
            target.parent.mkdir(parents=True)
            target.write_bytes(b'test module content')
            manifest = kernel / 'kernel-modules.manifest'
            manifest.write_text('0' * 64 + '  ' + path + '\n')
            runtime = root / 'usr/libexec/liuqin-fingerprint'
            for name in ('fprintd', 'liuqin-rpmb-supplicant', 'tod/libfprint-tod-fpc1264-oem.so'):
                file = runtime / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
            library = root / 'usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2'
            library.parent.mkdir(parents=True)
            library.touch()
            with self.assertRaisesRegex(ValueError, 'differs from'):
                module.stage(root)
            self.assertFalse((runtime / 'CANDIDATE.json').exists())
            digest = hashlib.sha256(target.read_bytes()).hexdigest()
            manifest.write_text(digest + '  ' + path + '\n')
            candidate = module.stage(root)
            self.assertEqual(candidate['kernel_module_sha256'], digest)
            self.assertEqual(candidate['enrollment_interface'], 'fprintd')
            self.assertTrue((root / 'etc/systemd/system/fprintd.service.d/60-liuqin-fpc-oem.conf').is_file())
            self.assertFalse((root / 'var/lib/liuqin-fingerprint').exists())
            self.assertFalse((root / 'usr/share/applications/liuqin-fingerprint-accept.desktop').exists())
            module.stage(root)  # Idempotent; a resumed build preserves its binding.
            private = root / 'var/lib/liuqin-fingerprint'
            private.mkdir(parents=True)
            (private / 'owner-state').touch()
            with self.assertRaisesRegex(ValueError, 'private biometric state'):
                module.stage(root)


if __name__ == '__main__':
    unittest.main()
