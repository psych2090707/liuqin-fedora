#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Daily bridge tests with a fake debugfs. Never arms actual hardware."""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / "tools/suspend-log" / filename))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


bridge = load("daily_early_wake_bridge", "liuqin-early-wake-log")
collector = load("daily_early_wake_collector", "liuqin-suspend-log")
BUILD = "b" * 40
BOOT = "01234567-1111-2222-3333-444444444444"


class FakeInterface:
    def __init__(self, state="idle", cycle=0):
        self.state, self.cycle = state, cycle
        self.arm_count = 0
        self.corrupt = False
        self.change_on_read = False
        self.events_reads = 0

    def read(self, name):
        if name == "status":
            values = dict(version=1, state=self.state, cycle=self.cycle, attempt=0,
                          build_id="0" * 40 if self.state == "idle" else BUILD,
                          buffer_bytes=88000, phase_count=3 if self.state == "sealed" else 0,
                          phase_dropped=0, cpu_dropped=0)
            return "".join(f"{k}={v}\n" for k, v in values.items()).encode()
        if name == "events":
            self.events_reads += 1
            if self.corrupt:
                return b'{"kind":"header"}\n'
            header = dict(kind="header", version=1, state="sealed", cycle=self.cycle, build_id=BUILD)
            body = [dict(kind="phase", cycle=self.cycle, seq=i + 1, phase=p)
                    for i, p in enumerate(("CYCLE_BEGIN", "ENTER_SKIPPED", "CYCLE_END"))]
            footer = dict(kind="footer", phase_count=3, phase_dropped=0, cpu_dropped=0)
            if self.change_on_read:
                header["noise"] = self.events_reads
            return ("\n".join(json.dumps(x) for x in [header, *body, footer]) + "\n").encode()
        raise AssertionError(name)

    def arm(self):
        self.arm_count += 1
        self.cycle += 1
        self.state = "armed"


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)
        self.event = self.state / "events/01234567-0000000100"
        self.event.mkdir(parents=True)
        self.fake = FakeInterface()
        self.recorder = bridge.Recorder(self.state, self.event, BOOT, BUILD, self.fake)

    def test_default_idle_arms_once_and_adopts_existing_arm(self):
        self.assertEqual(self.recorder.pre()["cycle"], 1)
        self.assertEqual(self.fake.arm_count, 1)
        self.assertTrue(self.recorder.pre()["adopted"])
        self.assertEqual(self.fake.arm_count, 1)

    def test_post_saves_repeated_sealed_bytes_and_pointer_before_rearm(self):
        self.recorder.pre()
        self.fake.state = "sealed"
        result = self.recorder.capture(self.event / "early-wake", 1)
        self.assertEqual(result["state"], "saved")
        self.assertEqual(self.fake.events_reads, 2)
        raw = (self.event / "early-wake/events.jsonl").read_bytes()
        self.assertEqual(raw, self.fake.read("events"))
        pointer = json.loads(self.recorder.pointer.read_text())
        self.assertEqual(pointer["events_sha256"], bridge.digest(raw))
        self.assertEqual((self.event / "early-wake/events.jsonl").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.recorder.pre()["cycle"], 2)
        self.assertFalse((self.event / "early-wake-previous").exists())

    def test_missing_post_recovers_sealed_before_arm(self):
        self.fake.state, self.fake.cycle = "sealed", 1
        result = self.recorder.pre()
        self.assertEqual(result["cycle"], 2)
        self.assertEqual(result["recovered_previous"]["cycle"], 1)
        self.assertTrue((self.event / "early-wake-previous/events.jsonl").exists())

    def test_corrupt_saved_copy_is_not_trusted_and_kernel_copy_recovered(self):
        self.fake.state, self.fake.cycle = "sealed", 1
        self.recorder.capture(self.event / "early-wake", 1)
        (self.event / "early-wake/events.jsonl").write_text("corrupt saved copy")
        result = self.recorder.pre()
        self.assertEqual(result["recovered_previous"]["state"], "saved")
        self.assertEqual((self.event / "early-wake/events.jsonl").read_text(), "corrupt saved copy")

    def test_malformed_buffer_refuses_rearm(self):
        self.fake.state, self.fake.cycle, self.fake.corrupt = "sealed", 1, True
        with self.assertRaises(ValueError):
            self.recorder.pre()
        self.assertEqual(self.fake.arm_count, 0)
        self.assertEqual(self.fake.state, "sealed")

    def test_changed_export_refuses_rearm(self):
        self.fake.state, self.fake.cycle, self.fake.change_on_read = "sealed", 1, True
        with self.assertRaisesRegex(ValueError, "changed"):
            self.recorder.pre()
        self.assertEqual(self.fake.arm_count, 0)

    def test_disk_write_failure_refuses_rearm(self):
        self.fake.state, self.fake.cycle = "sealed", 1
        with patch.object(bridge, "atomic_json", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.recorder.pre()
        self.assertEqual(self.fake.arm_count, 0)

    def test_conflicting_archive_not_overwritten(self):
        self.fake.state, self.fake.cycle = "sealed", 1
        destination = self.event / "early-wake-previous"
        destination.mkdir()
        (destination / "status.txt").write_text("older evidence")
        with self.assertRaisesRegex(ValueError, "different evidence"):
            self.recorder.pre()
        self.assertEqual((destination / "status.txt").read_text(), "older evidence")
        self.assertEqual(self.fake.arm_count, 0)

    def test_partial_identical_archive_completed_without_erasing(self):
        self.fake.state, self.fake.cycle = "sealed", 1
        destination = self.event / "early-wake-previous"
        destination.mkdir()
        raw = self.fake.read("status")
        (destination / "status.txt").write_bytes(raw)
        self.recorder.pre()
        self.assertEqual((destination / "status.txt").read_bytes(), raw)
        self.assertTrue((destination / "capture.json").exists())

    def test_wrong_cycle_busy_or_build_id_never_erase(self):
        self.fake.state, self.fake.cycle = "sealed", 1
        with self.assertRaises(ValueError):
            self.recorder.capture(self.event / "early-wake", 2)
        self.fake.state = "recording"
        with self.assertRaises(ValueError):
            self.recorder.pre()
        self.fake.state = "sealed"
        self.recorder.build_id = "c" * 40
        with self.assertRaises(ValueError):
            self.recorder.pre()
        self.assertEqual(self.fake.arm_count, 0)


def snapshot(phase, boottime):
    return dict(phase=phase, boot_id=BOOT, build_id=BUILD, release="test",
                collected_realtime_ns=(10000 + boottime)*10**9,
                collected_boottime_ns=boottime*10**9, collected_monotonic_ns=boottime*10**9,
                interrupts={}, wakeup_sources={}, suspend_stats={"success": "0"},
                mem_sleep="s2idle [deep]", rtc={}, power_supply={}, dmesg="")


class CollectorIntegrationTests(unittest.TestCase):
    def test_selftest_and_non_suspend_never_enable_real_bridge(self):
        args = Namespace(sleep_op="suspend", state_dir=collector.DEFAULT_STATE)
        with patch.object(collector, "read_text", return_value="1"), patch.object(collector.os, "geteuid", return_value=0):
            with patch.dict(os.environ, {}, clear=True):
                self.assertTrue(collector.early_wake_enabled(args, collector.DEFAULT_STATE))
                self.assertFalse(collector.early_wake_enabled(args, Path("/tmp/not-real-state")))
                args.sleep_op = "hibernate"
                self.assertFalse(collector.early_wake_enabled(args, collector.DEFAULT_STATE))
                args.sleep_op = "suspend"
                with patch.dict(os.environ, {"LIUQIN_SUSPEND_LOG_STATE": str(collector.DEFAULT_STATE)}):
                    self.assertFalse(collector.early_wake_enabled(args, collector.DEFAULT_STATE))

    def test_pre_association_durable_and_post_capture_before_active_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            args = Namespace(state_dir=state, sleep_op="suspend", keep=30)
            calls = []

            def collect(phase):
                calls.append("collect-" + phase)
                return snapshot(phase, 100 if phase == "pre" else 110)

            def bridge_call(phase, root, directory, pre, cycle=None):
                calls.append("bridge-" + phase)
                pending = json.loads((root / "pending.json").read_text())
                self.assertEqual(pending["id"], directory.name)
                self.assertTrue((directory / "pre.json").is_file())
                if phase == "pre":
                    return dict(state="armed", cycle=1)
                self.assertEqual(cycle, 1)
                return dict(state="saved", cycle=1, path="events/" + directory.name + "/early-wake")

            with patch.dict(os.environ, {}, clear=True), patch.object(collector, "early_wake_enabled", return_value=True), \
                    patch.object(collector, "collect", side_effect=collect), \
                    patch.object(collector, "early_wake_call", side_effect=bridge_call):
                collector.do_pre(args)
                event_id = json.loads((state / "pending.json").read_text())["id"]
                collector.do_post(args)
            self.assertEqual(calls, ["collect-pre", "bridge-pre", "bridge-post", "collect-post"])
            report = json.loads((state / "events" / event_id / "report.json").read_text())
            self.assertEqual(report["early_wake"]["state"], "saved")
            self.assertFalse((state / "pending.json").exists())
            self.assertEqual(len(list((state / "events").iterdir())), 1)

    def test_helper_failure_still_records_normal_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = Namespace(state_dir=Path(tmp), sleep_op="suspend", keep=30)
            with patch.dict(os.environ, {}, clear=True), patch.object(collector, "early_wake_enabled", return_value=True), \
                    patch.object(collector, "collect", side_effect=lambda phase: snapshot(phase, 100)), \
                    patch.object(collector, "early_wake_call", return_value={"state": "error", "error": "unavailable"}):
                collector.do_pre(args)
                collector.do_post(args)
            reports = list((Path(tmp) / "events").glob("*/report.json"))
            self.assertEqual(len(reports), 1)
            self.assertEqual(json.loads(reports[0].read_text())["early_wake"]["state"], "error")

    def test_bridge_files_pruned_with_parent_event_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            for i in range(35):
                event = state / "events" / f"01234567-{i:010d}"
                (event / "early-wake").mkdir(parents=True)
                (event / "early-wake/events.jsonl").write_text("sealed")
                (event / "report.json").write_text(json.dumps({"post": {"collected_realtime_ns": i+1}}))
            collector.prune(state, 30)
            self.assertEqual(len(list((state / "events").iterdir())), 30)
            self.assertEqual(len(list((state / "events").glob("*/early-wake/events.jsonl"))), 30)


if __name__ == "__main__":
    unittest.main()
