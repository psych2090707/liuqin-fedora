#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Offline checks for the suspend-log observers (no tablet, no framework).

Run from the project root:
    python3 -B -m unittest discover -s tests/suspend-log -p 'test_*.py' -v

Cases map to the spontaneous-wake runbook S3:
N1-N3 notification recording, I1 IRQ kept without post wake flag,
T1-T2 clock/window handling, S1-S2 screen-latest classification.
"""
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools" / "suspend-log"


def load(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, str(TOOLS / filename))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


notify = load("liuqin_notify_log_under_test", "liuqin-notify-log")
collector = load("liuqin_suspend_log_under_test", "liuqin-suspend-log")


class FakeClock:
    def __init__(self, start_ns=1_700_000_000_000_000_000):
        self.now_ns = start_ns

    def __call__(self):
        return {
            "realtime_ns": self.now_ns,
            "boottime_ns": self.now_ns + 5_000_000_000,
            "monotonic_ns": self.now_ns + 1_000_000_000,
        }

    def advance(self, seconds):
        self.now_ns += int(seconds * 1e9)


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def snapshot(boottime=1000.0, monotonic=500.0, realtime=1_700_000_000.0,
             success="7", boot_id="boot-1", interrupts=None,
             wake_enabled=None, wakeup_sources=None):
    return {
        "phase": "pre",
        "collected_boottime_ns": int(boottime * 1e9),
        "collected_monotonic_ns": int(monotonic * 1e9),
        "collected_realtime_ns": int(realtime * 1e9),
        "boot_id": boot_id,
        "release": "test-release",
        "build_id": "b" * 40,
        "suspend_stats": {"success": success, "fail": "0"},
        "interrupts": interrupts or {},
        "wake_enabled_irqs": wake_enabled or {},
        "wakeup_sources": wakeup_sources or {},
        "rtc": {"wakealarm": "", "proc_driver_rtc": ""},
        "power_supply": {"qcom-battmgr-usb": {"online": "0"}},
        "pm_wakeup_irq": "",
        "mem_sleep": "s2idle [deep]",
        "dmesg": "",
    }


def irq(total, desc="test"):
    return {"total": total, "counts": [total], "desc": desc}


class NotificationTests(unittest.TestCase):
    def test_n1_single_notify_is_saved_immediately(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = FakeClock()
            recorder = notify.Recorder(tmp, clock=clock, boot_id="boot-test")
            notify.handle_fdo(
                recorder,
                ["Test App", 0, "", "Summary line", "SECRET BODY", [], {}, -1],
            )
            rows = read_jsonl(recorder.notify_path)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["app"], "Test App")
            self.assertEqual(rows[0]["summary"], "Summary line")
            self.assertEqual(rows[0]["protocol"], "fdo")
            self.assertEqual(rows[0]["boot_id"], "boot-test")
            self.assertNotIn("body", rows[0])
            self.assertNotIn("SECRET BODY", recorder.notify_path.read_text())

    def test_n2_gtk_add_notification(self):
        with tempfile.TemporaryDirectory() as tmp:
            recorder = notify.Recorder(tmp, clock=FakeClock(), boot_id="boot-test")
            notify.handle_gtk(
                recorder,
                ["org.example.App", "note-1",
                 {"title": "GTK title", "body": "SECRET BODY"}],
            )
            rows = read_jsonl(recorder.notify_path)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["protocol"], "gtk")
            self.assertEqual(rows[0]["app"], "org.example.App")
            self.assertEqual(rows[0]["summary"], "GTK title")
            self.assertNotIn("SECRET BODY", recorder.notify_path.read_text())

    def test_n4_forwarded_shell_copy_is_not_double_counted(self):
        with tempfile.TemporaryDirectory() as tmp:
            recorder = notify.Recorder(tmp, clock=FakeClock(), boot_id="boot-test")
            notify.handle_fdo(
                recorder,
                ["notify-send", 0, "", "same", "body", [],
                 {"sender-pid": 42}, -1],
            )
            notify.handle_fdo(
                recorder,
                ["notify-send", 0, "", "same", "body", [],
                 {"sender-pid": 42, "x-shell-sender": ":1.44"}, -1],
            )
            rows = read_jsonl(recorder.notify_path)
            self.assertEqual(len(rows), 1)
            self.assertNotIn("x-shell-sender", rows[0])

    def test_n3_first_row_keeps_first_receipt_clock(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = FakeClock()
            recorder = notify.Recorder(tmp, clock=clock, boot_id="boot-test")
            notify.handle_fdo(recorder, ["A", 0, "", "first", "", [], {}, -1])
            first = read_jsonl(recorder.notify_path)[0]["boottime_ns"]
            self.assertEqual(len(read_jsonl(recorder.notify_path)), 1)
            clock.advance(60)
            notify.handle_fdo(recorder, ["A", 0, "", "second", "", [], {}, -1])
            rows = read_jsonl(recorder.notify_path)
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["boottime_ns"], first)
            self.assertEqual(rows[1]["boottime_ns"] - first, 60_000_000_000)

    def test_same_content_inside_one_second_is_deduplicated(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = FakeClock()
            recorder = notify.Recorder(tmp, clock=clock, boot_id="boot-test")
            notify.handle_fdo(recorder, ["A", 0, "", "same", "", [], {}, -1])
            clock.advance(0.2)
            notify.handle_fdo(recorder, ["A", 0, "", "same", "", [], {}, -1])
            self.assertEqual(len(read_jsonl(recorder.notify_path)), 1)
            clock.advance(2.0)
            notify.handle_fdo(recorder, ["A", 0, "", "same", "", [], {}, -1])
            self.assertEqual(len(read_jsonl(recorder.notify_path)), 2)


class ScreenEventTests(unittest.TestCase):
    def test_only_listed_properties_are_stored(self):
        props = notify.pick(
            "org.freedesktop.UPower.Device",
            {"Online": True, "Percentage": 50, "SerialNumber": "12345",
             "Model": "secret-model"},
        )
        self.assertEqual(props, {"Online": True, "Percentage": 50})

    def test_screen_row_carries_boot_id_and_three_clocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            recorder = notify.Recorder(tmp, clock=FakeClock(), boot_id="boot-test")
            recorder.screen("org.freedesktop.UPower", "org.freedesktop.UPower",
                            {"OnBattery": True}, "system",
                            "/org/freedesktop/UPower", "change")
            rows = read_jsonl(recorder.screen_path)
            self.assertEqual(len(rows), 1)
            for key in ("boot_id", "realtime_ns", "boottime_ns", "monotonic_ns"):
                self.assertIn(key, rows[0])
            self.assertEqual(rows[0]["props"], {"OnBattery": True})


class IrqTests(unittest.TestCase):
    def test_i1_irq_kept_when_post_wake_flag_is_revoked(self):
        pre = snapshot(
            interrupts={"15": irq(100, "ipcc_0")},
            wake_enabled={"15": "ipcc_0"},
        )
        post = snapshot(
            boottime=1001.0, monotonic=501.0, success="8",
            interrupts={"15": irq(101, "ipcc_0")},
            wake_enabled={},
        )
        rows = collector.irq_delta(pre, post)
        self.assertEqual([row["irq"] for row in rows], ["15"])
        row = rows[0]
        self.assertEqual(row["delta"], 1)
        self.assertTrue(row["wake_enabled_pre"])
        self.assertFalse(row["wake_enabled_post"])
        report = collector.build_report(pre, post, "suspend", Path("/tmp/event"))
        text = collector.render(report)
        self.assertIn("WAKE-pre", text)
        self.assertNotIn("更像 PON/AOSS", text)
        self.assertNotIn("没有 wake-enabled IRQ 的计数变化", text)


class MetricsTests(unittest.TestCase):
    def test_t1_window_residency_and_running_time(self):
        pre = snapshot(boottime=1000.0, monotonic=500.0, success="7")
        post = snapshot(boottime=1064.0, monotonic=510.0, success="8")
        measure = collector.metrics(pre, post)
        self.assertEqual(measure["window_s"], 64.0)
        self.assertEqual(measure["awake_window_s"], 10.0)
        self.assertEqual(measure["suspend_estimate_s"], 54.0)
        report = collector.build_report(pre, post, "suspend", Path("/tmp/event"))
        self.assertEqual(report["duration_s"], 64.0)
        self.assertEqual(report["suspend_estimate_s"], 54.0)
        self.assertEqual(report["awake_window_s"], 10.0)
        self.assertIs(report["real_sleep"], True)
        text = collector.render(report)
        self.assertIn("suspend_estimate=54.000s", text)
        self.assertIn("awake_window=10.000s", text)

    def test_t2_missing_clock_is_unknown(self):
        pre = snapshot()
        post = snapshot(boottime=1064.0, monotonic=510.0, success="8")
        del post["collected_monotonic_ns"]
        measure = collector.metrics(pre, post)
        self.assertFalse(measure["clocks_valid"])
        self.assertIsNone(measure["suspend_estimate_s"])
        report = collector.build_report(pre, post, "suspend", Path("/tmp/event"))
        self.assertIsNone(report["real_sleep"])
        self.assertIn("real_sleep=unknown", collector.render(report))

    def test_t2_cross_boot_is_unknown(self):
        pre = snapshot()
        post = snapshot(boottime=1064.0, monotonic=510.0, success="8",
                        boot_id="boot-2")
        measure = collector.metrics(pre, post)
        self.assertTrue(measure["cross_boot"])
        self.assertIsNone(measure["suspend_estimate_s"])
        report = collector.build_report(pre, post, "suspend", Path("/tmp/event"))
        self.assertIsNone(report["real_sleep"])
        self.assertIn("real_sleep=unknown", collector.render(report))

    def test_t2_post_without_pre_snapshot_is_unknown(self):
        post = snapshot(boottime=1064.0, monotonic=510.0, success="8")
        report = collector.build_report(None, post, "suspend", Path("/tmp/event"))
        self.assertIsNone(report["duration_s"])
        self.assertIsNone(report["suspend_estimate_s"])
        self.assertIsNone(report["real_sleep"])
        self.assertFalse(report["pre_present"])
        text = collector.render(report)
        self.assertIn("missing pre snapshot", text)
        self.assertIn("real_sleep=unknown", text)

    def test_pm_wakeup_irq_available_but_empty_is_reported(self):
        pre = snapshot(success="7")
        post = snapshot(boottime=1064.0, monotonic=510.0, success="8")
        post["pm_wakeup_irq_available"] = True
        report = collector.build_report(pre, post, "suspend", Path("/tmp/event"))
        text = collector.render(report)
        self.assertIn("接口可用，但本次没有记录到唤醒 IRQ", text)
        self.assertIn("available=yes", text)

    def test_success_must_increase_for_real_sleep(self):
        pre = snapshot(success="7")
        post = snapshot(boottime=1064.0, monotonic=510.0, success="7")
        report = collector.build_report(pre, post, "suspend", Path("/tmp/event"))
        self.assertIs(report["real_sleep"], False)


class ScreenLatestTests(unittest.TestCase):
    def setUp(self):
        self.base = datetime(2026, 10, 29, 12, 0, 0)
        self.intervals = [{"entry": self.base, "exit": self.base + timedelta(seconds=10)}]

    def test_s1_slow_resume_is_not_screen_only(self):
        when = self.base + timedelta(seconds=18)  # 8 s after PM exit
        kind, detail = collector.classify_panel_on(
            when, self.base - timedelta(seconds=5), self.intervals)
        self.assertEqual(kind, "resume")
        self.assertIn("slow resume", detail)
        self.assertNotIn("screen-only", detail)

    def test_s1_fast_resume_is_resume(self):
        when = self.base + timedelta(seconds=13)
        kind, detail = collector.classify_panel_on(
            when, self.base - timedelta(seconds=5), self.intervals)
        self.assertEqual(kind, "resume")
        self.assertIn("after PM suspend exit", detail)

    def test_panel_on_without_suspend_is_screen_only(self):
        kind, detail = collector.classify_panel_on(
            self.base + timedelta(seconds=60),
            self.base + timedelta(seconds=50),
            self.intervals,
        )
        self.assertEqual(kind, "screen-only")
        self.assertIn("no suspend exit", detail)

    def test_missing_journal_coverage_is_unknown(self):
        kind, detail = collector.classify_panel_on(
            self.base + timedelta(seconds=60),
            self.base - timedelta(seconds=1),
            self.intervals,
            journal_start=self.base,
        )
        self.assertEqual(kind, "unknown")
        self.assertIn("coverage", detail)

    def test_s2_notification_after_panel_on_is_not_a_cause(self):
        self.assertEqual(collector.notification_relation(3.0),
                         "after panel on (not a cause)")
        self.assertEqual(collector.notification_relation(-1.5),
                         "before panel on (candidate)")
        self.assertIsNone(collector.notification_relation(12.0))

    def test_interval_pairing(self):
        intervals = collector.suspend_intervals(
            [self.base, self.base + timedelta(minutes=5)],
            [self.base + timedelta(seconds=30)],
        )
        self.assertEqual(intervals[0]["exit"],
                         self.base + timedelta(seconds=30))
        self.assertIsNone(intervals[1]["exit"])


if __name__ == "__main__":
    unittest.main()
