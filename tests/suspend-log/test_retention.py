"""Deletion regressions in isolated directories; never collect hardware state."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from argparse import Namespace

SOURCE = Path(__file__).resolve().parents[2] / "tools/suspend-log/liuqin-suspend-log"
loader = importlib.machinery.SourceFileLoader("retention_collector", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
c = importlib.util.module_from_spec(spec)
loader.exec_module(c)


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)
        self.events = self.state / "events"
        self.events.mkdir()

    def event(self, n, *, wall=100, legacy=False, boot="01234567"):
        name = f"{boot}-{n:010d}"
        if legacy:
            path = self.events / name
            path.mkdir()
        else:
            path = c.reserve_event_dir(self.events, name)
        (path / "report.json").write_text(json.dumps({"post": {"collected_realtime_ns": wall}}))
        (path / "early-wake").mkdir()
        (path / "early-wake/events.jsonl").write_text("evidence")
        return path

    def test_new_record_with_1973_date_outlives_future_dated_old_record(self):
        old = self.event(1, wall=2**60)
        new = self.event(2, wall=1, boot="abcdef01")
        os.utime(new, ns=(0, 0))
        c.prune(self.state, 1)
        self.assertFalse(old.exists())
        self.assertEqual((new / "early-wake/events.jsonl").read_text(), "evidence")

    def test_unknown_legacy_chronology_is_never_guessed_for_deletion(self):
        old = [self.event(n, wall=100-n, legacy=True) for n in range(35)]
        c.prune(self.state, 1)
        self.assertTrue(all(p.exists() for p in old))

    def test_latest_does_not_call_an_arbitrary_legacy_name_the_newest(self):
        legacy = self.event(1, legacy=True)
        (legacy / "report.txt").write_text("old evidence")
        self.assertEqual(c.do_latest(Namespace(state_dir=self.state)), 1)

    def test_pinned_old_event_does_not_consume_ordinary_quota(self):
        pinned = self.event(1)
        c.protect_event(pinned, "important failure")
        old, new = self.event(2), self.event(3)
        c.prune(self.state, 1)
        self.assertTrue(pinned.exists())
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_incomplete_and_malformed_reports_are_preserved(self):
        a, b = self.event(1), self.event(2)
        (a / "report.json").unlink()
        (b / "report.json").write_text("{broken")
        self.event(3)
        c.prune(self.state, 1)
        self.assertTrue(a.exists() and b.exists())

    def test_orphan_and_broken_protection_marker_still_protect(self):
        a, b = self.event(1), self.event(2)
        (a / "orphan-pre.json").write_text("evidence")
        (b / "protected.json").write_text("{broken")
        self.event(3)
        c.prune(self.state, 1)
        self.assertTrue(a.exists() and b.exists())

    def test_counter_corruption_missing_and_regression_stop_deletion(self):
        a, b = self.event(1), self.event(2)
        counter = self.state / "event-sequence.json"
        for content in ("{broken", None, '{"version":1,"last":1}'):
            if content is None:
                counter.unlink()
            else:
                counter.write_text(content)
            self.assertIn("error", c.prune(self.state, 1))
            self.assertTrue(a.exists() and b.exists())

    def test_duplicate_sequence_stops_deletion(self):
        a, b = self.event(1), self.event(2)
        (b / "sequence.json").write_bytes((a / "sequence.json").read_bytes())
        self.assertIn("error", c.prune(self.state, 1))
        self.assertTrue(a.exists() and b.exists())

    def test_sequence_write_interruption_makes_gap_without_reuse(self):
        first = self.event(1)
        original = c.write_atomic
        def interrupted(path, text, mode=0o600):
            if Path(path).name == "sequence.json":
                raise OSError("disk full after counter commit")
            original(path, text, mode)
        with patch.object(c, "write_atomic", side_effect=interrupted):
            incomplete = c.reserve_event_dir(self.events, "01234567-0000000002")
        last = self.event(3)
        c.prune(self.state, 1)
        self.assertFalse(first.exists())
        self.assertTrue(incomplete.exists())
        self.assertEqual(json.loads((last / "sequence.json").read_text())["sequence"], 3)

    def test_corrupt_pending_record_is_not_overwritten_or_removed(self):
        pending = self.state / "pending.json"
        pending.write_text("incomplete forensic evidence")
        args = Namespace(state_dir=self.state, sleep_op="suspend", keep=1)
        with self.assertRaises(ValueError):
            c.do_post(args)
        self.assertEqual(pending.read_text(), "incomplete forensic evidence")

    def test_symlink_and_unknown_directories_are_not_removed(self):
        target = self.state / "outside"
        target.mkdir()
        (self.events / "01234567-0000000001").symlink_to(target, target_is_directory=True)
        unknown = self.events / "do-not-touch"
        unknown.mkdir()
        self.event(2)
        c.prune(self.state, 1)
        self.assertTrue(target.exists() and unknown.exists())

    def test_zero_keep_is_emergency_stop_not_delete_all(self):
        a, b = self.event(1), self.event(2)
        c.prune(self.state, 0)
        self.assertTrue(a.exists() and b.exists())

    def test_capacity_failure_keeps_protected_evidence(self):
        a = self.event(1)
        c.protect_event(a, "important")
        with patch.object(c, "MAX_STATE_BYTES", 1):
            with self.assertRaises(OSError):
                c.check_capacity(self.state)
        self.assertTrue(a.exists())

    def test_cli_lock_contention_fails_without_deleting(self):
        a, b = self.event(1), self.event(2)
        with c.mutation_lock(self.state):
            r = subprocess.run([sys.executable, str(SOURCE), "prune", "--keep", "1",
                                "--state-dir", str(self.state)], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(a.exists() and b.exists())

    def test_pre_without_post_protects_orphan_on_next_pre(self):
        args = Namespace(state_dir=self.state, sleep_op="suspend", keep=1)
        snapshot = {"boot_id": "01234567-1111-2222-3333-444444444444",
                    "collected_boottime_ns": 10**9}
        with patch.object(c, "collect", return_value=snapshot), \
                patch.object(c, "early_wake_enabled", return_value=False):
            c.do_pre(args)
            old = json.loads((self.state / "pending.json").read_text())["id"]
            c.do_pre(args)
        self.assertTrue((self.events / old / "protected.json").exists())
        self.assertTrue((self.events / old / "orphan-pre.json").exists())


if __name__ == "__main__":
    unittest.main()
