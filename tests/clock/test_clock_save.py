"""Fixture-only tests: never touch the host epoch, clock, chrony or services."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'liuqin_clock_save', ROOT / 'packaging/clock/liuqin-clock-save.py')
clock_save = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = clock_save
SPEC.loader.exec_module(clock_save)
S = clock_save.SECOND
NOW = 1_793_347_200 * S
BOOT = 90 * S


class ClockSaveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='liuqin-clock-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.epoch = self.root / 'clock-epoch'
        self.epoch.touch(mode=0o644)
        os.utime(self.epoch, ns=(0, 0))
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.boot_id = self.root / 'boot-id'
        self.boot_id.write_text('boot-A\n')
        self.paths = clock_save.Paths(self.epoch, self.runtime, self.boot_id)
        for name, value in (('OWNER', os.geteuid()), ('GROUP', os.getegid())):
            p = patch.object(clock_save, name, value)
            p.start()
            self.addCleanup(p.stop)

    def save(self, *, synced=True, wall=NOW, boot=BOOT, require_sync=False, samples=None):
        ticks = iter(samples) if samples else None
        return clock_save.save(self.paths, require_sync=require_sync,
                               sync_check=lambda: synced,
                               clock=(lambda: next(ticks)) if ticks else lambda: (wall, boot))

    def anchor(self):
        return json.loads((self.runtime / 'anchor.json').read_text())

    def test_synced_stamp_and_anchor_readback(self):
        result = self.save()
        self.assertEqual(result['source'], 'chrony')
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW - S)
        self.assertEqual(self.epoch.stat().st_atime_ns, 0)
        self.assertEqual(self.epoch.read_bytes(), b'')
        self.assertEqual(self.anchor()['boot_id'], 'boot-A')
        self.assertEqual((self.runtime / 'anchor.json').stat().st_mode & 0o777, 0o600)

    def test_never_synced_does_not_touch_epoch(self):
        self.assertEqual(self.save(synced=False)['status'], 'skipped')
        self.assertEqual(self.epoch.stat().st_mtime_ns, 0)
        self.assertFalse((self.runtime / 'anchor.json').exists())

    def test_shutdown_updates_floor_after_new_package_was_signed(self):
        self.save()
        signed = NOW + 30 * S
        self.save(wall=NOW + 40 * S, boot=BOOT + 40 * S)
        self.assertGreater(self.epoch.stat().st_mtime_ns, signed)

    def test_offline_holdover_includes_suspended_time(self):
        self.save()
        result = self.save(synced=False, wall=0, boot=BOOT + 3600 * S)
        self.assertEqual(result['source'], 'holdover')
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW - S + 3600 * S)

    def test_manual_wall_clock_jump_is_not_persisted_in_holdover(self):
        self.save()
        self.save(synced=False, wall=NOW + 10**18, boot=BOOT + 60 * S)
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW - S + 60 * S)

    def test_different_boot_anchor_is_not_trusted(self):
        self.save()
        self.boot_id.write_text('boot-B\n')
        self.assertEqual(self.save(synced=False, boot=BOOT + S)['status'], 'skipped')
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW - S)

    def test_holdover_expires_after_seven_days(self):
        self.save()
        result = self.save(synced=False, boot=BOOT + clock_save.MAX_HOLDOVER + 1)
        self.assertEqual(result['status'], 'skipped')

    def test_backwards_boottime_is_rejected(self):
        self.save()
        self.assertEqual(self.save(synced=False, boot=BOOT - 1)['status'], 'skipped')

    def test_initial_activation_requires_fresh_sync_even_with_anchor(self):
        self.save()
        with self.assertRaisesRegex(ValueError, 'not synchronised'):
            self.save(synced=False, require_sync=True)

    def test_clock_step_during_chrony_check_is_rejected(self):
        samples = [(NOW, BOOT), (NOW + 3600 * S, BOOT + S)]
        self.assertEqual(self.save(samples=samples)['status'], 'skipped')
        self.assertEqual(self.epoch.stat().st_mtime_ns, 0)

    def test_clock_step_can_fall_back_to_existing_anchor(self):
        self.save()
        samples = [(NOW, BOOT), (NOW + 3600 * S, BOOT + S)]
        self.assertEqual(self.save(samples=samples)['source'], 'holdover')
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW)

    def test_bad_rtc_value_is_not_accepted_as_synced_time(self):
        self.assertEqual(self.save(wall=0)['status'], 'skipped')

    def test_future_epoch_is_preserved_for_manual_review(self):
        os.utime(self.epoch, ns=(0, NOW + 3600 * S))
        with self.assertRaisesRegex(ValueError, 'ahead of trusted'):
            self.save()
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW + 3600 * S)
        self.assertFalse((self.runtime / 'anchor.json').exists())

    def test_subsecond_resynchronisation_does_not_move_floor_back(self):
        self.save()
        self.save(wall=NOW - S // 2, boot=BOOT + S)
        self.assertEqual(self.epoch.stat().st_mtime_ns, NOW - S)

    def test_missing_epoch_is_not_created_implicitly(self):
        self.epoch.unlink()
        with self.assertRaises(FileNotFoundError):
            self.save()
        self.assertFalse(self.epoch.exists())

    def test_unknown_nonempty_epoch_is_preserved(self):
        self.epoch.write_text('administrator data')
        with self.assertRaisesRegex(ValueError, 'not empty'):
            self.save()
        self.assertEqual(self.epoch.read_text(), 'administrator data')

    def test_epoch_symlink_is_not_followed(self):
        other = self.root / 'other'
        other.write_text('untouched')
        self.epoch.unlink()
        self.epoch.symlink_to(other)
        with self.assertRaises(OSError):
            self.save()
        self.assertEqual(other.read_text(), 'untouched')

    def test_epoch_hardlink_is_rejected(self):
        os.link(self.epoch, self.root / 'alias')
        with self.assertRaises(ValueError):
            self.save()
        self.assertEqual(self.epoch.stat().st_mtime_ns, 0)

    def test_unsafe_epoch_permissions_are_rejected(self):
        self.epoch.chmod(0o666)
        with self.assertRaises(ValueError):
            self.save()

    def test_unsafe_runtime_directory_is_rejected(self):
        self.runtime.chmod(0o777)
        with self.assertRaises(ValueError):
            self.save()

    def test_invalid_anchor_is_not_rewritten_when_offline(self):
        p = self.runtime / 'anchor.json'
        for contents in ('{bad', 'null', '{}', '{"version":1,"boot_id":"boot-A",'
                         '"epoch_ns":true,"boottime_ns":0}'):
            with self.subTest(contents=contents):
                p.write_text(contents)
                p.chmod(0o600)
                with self.assertRaises(ValueError):
                    self.save(synced=False)
                self.assertEqual(self.epoch.stat().st_mtime_ns, 0)

    def test_failed_stamp_write_does_not_publish_new_anchor(self):
        with patch.object(clock_save.os, 'utime', side_effect=PermissionError('read-only')):
            with self.assertRaises(PermissionError):
                self.save()
        self.assertFalse((self.runtime / 'anchor.json').exists())
        self.assertEqual(self.epoch.stat().st_mtime_ns, 0)

    def test_concurrent_writer_is_rejected_without_waiting(self):
        with (self.runtime / 'lock').open('w') as lock:
            lock_path = self.runtime / 'lock'
            lock_path.chmod(0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            with self.assertRaises(BlockingIOError):
                self.save()
        self.assertEqual(self.epoch.stat().st_mtime_ns, 0)

    def test_chrony_check_uses_one_local_readonly_probe(self):
        with patch.object(clock_save.subprocess, 'run') as run:
            run.return_value.returncode = 0
            self.assertTrue(clock_save.chrony_synced())
            args, kwargs = run.call_args
            self.assertEqual(args[0], ['/usr/bin/chronyc', '-u', 'root', '-n', '-h',
                '/run/chrony/chronyd.sock', 'waitsync', '1', '0.5', '0', '0'])
            self.assertEqual(kwargs['timeout'], 3)
            self.assertNotIn('shell', kwargs)

    def test_chrony_missing_timeout_or_failure_is_not_sync(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired('chronyc', 3)):
            with self.subTest(error=error), patch.object(
                    clock_save.subprocess, 'run', side_effect=error):
                self.assertFalse(clock_save.chrony_synced())
        with patch.object(clock_save.subprocess, 'run') as run:
            run.return_value.returncode = 1
            self.assertFalse(clock_save.chrony_synced())

    def test_units_do_not_wake_or_set_clocks_or_change_chrony(self):
        base = ROOT / 'packaging/clock'
        timer = (base / 'liuqin-clock-save.timer').read_text()
        guard = (base / 'liuqin-clock-shutdown.service').read_text()
        self.assertIn('WakeSystem=false', timer)
        self.assertIn('Persistent=false', timer)
        self.assertIn('After=chronyd.service', guard)
        self.assertIn('RemainAfterExit=yes', guard)
        self.assertIn('ExecStop=/usr/libexec/liuqin/liuqin-clock-save', guard)
        for p in base.glob('*.service'):
            text = p.read_text()
            self.assertIn('ProtectClock=yes', text)
            self.assertIn('CapabilityBoundingSet=CAP_DAC_OVERRIDE', text)
            self.assertIn('ReadWritePaths=/usr/lib/clock-epoch /run/liuqin-clock /run/chrony', text)
            self.assertIn('RestrictAddressFamilies=AF_UNIX', text)
        spec = (base / 'liuqin-clock-support.spec').read_text()
        self.assertNotIn('%post\n', spec)
        self.assertNotIn('%postun\n', spec)
        self.assertNotIn('%ghost', spec)


if __name__ == '__main__':
    unittest.main()
