#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Transport interruption and evidence preservation regressions, no device."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


capture = module("capture", TOOLS / "capture-crash.py")
archive = module("archive", TOOLS / "crash-forensics/archive.py")


class CrashForensics(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="afk evidence ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_disconnect_keeps_partial_line_and_reconnects_new_boot(self):
        counts = {}

        def transport(script):
            kind = "journal" if "journalctl" in script else "kmsg" if "dmesg" in script else "state"
            counts[kind] = counts.get(kind, 0) + 1
            number = counts[kind]
            body = (f"import os,time; os.write(1,b'AFK_ID boot=boot{number} uptime=1 release=fixture\\n'); "
                    "os.write(1,b'partial-final-record'); " +
                    ("raise SystemExit(255)" if number == 1 else "time.sleep(20)"))
            return [sys.executable, "-c", body]

        c = capture.Capture(self.root / "capture", "fixture", 3.2, 1024**2, transport)
        self.assertEqual(c.run(), 0)
        for kind in ("kmsg", "journal", "state"):
            self.assertEqual(counts[kind], 2)
            self.assertTrue((c.output / f"{kind}-00001.stdout").read_bytes().endswith(b"partial-final-record"))
            self.assertIn("boot2", c.identities[f"{kind}-00002"])
        m = json.loads((c.output / "manifest.json").read_text())
        for name, data in m["files"].items():
            self.assertEqual(hashlib.sha256((c.output / name).read_bytes()).hexdigest(), data["sha256"])
        events = [json.loads(x) for x in (c.output / "events.jsonl").read_text().splitlines()]
        self.assertTrue(all("host_monotonic_ns" in e for e in events))

    def test_remote_reader_failure_is_not_a_successful_capture(self):
        def transport(script):
            return [sys.executable, "-c", "print('AFK_ID boot=fixture'); raise SystemExit(1)"]
        c = capture.Capture(self.root / "failure", "fixture", 5, 1024**2, transport)
        self.assertEqual(c.run(), 1)
        self.assertIn("reader failed", c.error)

    def test_unreachable_device_reports_incomplete(self):
        c = capture.Capture(self.root / "unreachable", "fixture", 0.3, 1024**2,
                            lambda _: [sys.executable, "-c", "raise SystemExit(255)"])
        self.assertEqual(c.run(), 1)
        self.assertIn("never connected", c.error)

    def fixture(self):
        root = self.root / "device"
        boot = root / "proc/sys/kernel/random/boot_id"
        boot.parent.mkdir(parents=True)
        boot.write_text("11111111-1111-1111-1111-111111111111")
        pstore = root / "sys/fs/pstore"
        pstore.mkdir(parents=True)
        (pstore / "console-ramoops-0").write_bytes(b"\x00\xffkernel tail without newline")
        return root, boot, pstore

    def test_archive_preserves_binary_source_and_does_not_overwrite_on_clock_rollback(self):
        root, boot, pstore = self.fixture()
        dest = self.root / "archive"
        first = archive.archive(dest, root)
        boot.write_text("22222222-2222-2222-2222-222222222222")
        with patch.object(archive.time, "time_ns", return_value=0):
            second = archive.archive(dest, root)
        third = archive.archive(dest, root)
        self.assertEqual(len(list(dest.iterdir())), 3)
        for output in (first, second, third):
            self.assertEqual((output / "console-ramoops-0").read_bytes(),
                             (pstore / "console-ramoops-0").read_bytes())
            self.assertIsNone(json.loads((output / "metadata.json").read_text())["producer_boot_id"])

    def test_archive_capacity_fails_without_pruning(self):
        root, _, _ = self.fixture()
        dest = self.root / "full"
        archive.archive(dest, root)
        before = sorted(dest.rglob("*"))
        with self.assertRaisesRegex(RuntimeError, "capacity"):
            archive.archive(dest, root, max_bytes=1)
        self.assertEqual(before, sorted(dest.rglob("*")))


if __name__ == "__main__":
    unittest.main()
