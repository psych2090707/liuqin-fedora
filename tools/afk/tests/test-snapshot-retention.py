#!/usr/bin/env python3
"""Exercise real snapshot retention with a clock that moves backwards."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[3] / "overlays/afk/files/usr/local/sbin/afk-boot-snapshot"


class SnapshotRetention(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="afk snapshot ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.logs = self.root / "logs"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in {
            "id": "echo 0",
            "date": 'echo "$MOCK_CLOCK"',
            "cat": 'if [ "$1" = /proc/sys/kernel/random/boot_id ]; then echo "$MOCK_BOOT"; else exec /usr/bin/cat "$@"; fi',
            "dmesg": "echo mock-kernel-log",
            "journalctl": "echo mock-journal",
            "systemctl": "echo mock-units",
        }.items():
            p = self.bin / name
            p.write_text("#!/bin/bash\n" + body + "\n")
            p.chmod(0o755)

    def capture(self, boot, clock="20261018T000030Z", *args, check=True):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   AFK_LOG_ROOT=str(self.logs), MOCK_CLOCK=clock,
                   MOCK_BOOT=f"{boot:08x}-0000-0000-0000-000000000000")
        return subprocess.run(["bash", str(SCRIPT), *args], env=env,
                              capture_output=True, text=True, check=check)

    def snapshots(self):
        return sorted((self.logs / "boots").iterdir())

    def test_backwards_clock_keeps_last_twelve_captures(self):
        for i in range(1, 16):
            # Old directories were written after clock correction; the next
            # boot creates its new directory before its clock is corrected.
            if (self.logs / "boots").exists():
                for p in self.snapshots():
                    os.utime(p, (4070908800 - i, 4070908800 - i))
            self.capture(i, f"20261018T0000{60-i:02d}Z")
        self.assertEqual(len(self.snapshots()), 12)
        self.assertEqual({p.name[-8:] for p in self.snapshots()},
                         {f"{i:08x}" for i in range(4, 16)})
        for p in self.snapshots():
            self.assertIn("mock-kernel-log", (p / "dmesg.txt").read_text())

    def test_future_legacy_snapshots_and_unrelated_directory(self):
        boots = self.logs / "boots"
        boots.mkdir(parents=True)
        for i in range(12):
            p = boots / f"20990101T0000{i:02d}Z-boot-{i:08x}"
            p.mkdir()
            os.utime(p, (4070908800, 4070908800))
        unrelated = boots / "user evidence"
        unrelated.mkdir()
        self.capture(99)
        self.assertTrue(unrelated.is_dir())
        self.assertTrue(any(p.name.endswith("-00000063") for p in self.snapshots()))
        self.assertEqual(len(self.snapshots()), 13)  # 12 managed + unrelated

    def test_idempotence_and_force(self):
        self.capture(1)
        self.capture(1)
        self.assertEqual(len(self.snapshots()), 1)
        self.capture(1, "20261018T000020Z", "--force")
        self.assertEqual(len(self.snapshots()), 2)

    def test_concurrent_captures_have_unique_order(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(self.capture, range(1, 9)))
        self.assertEqual(len(self.snapshots()), 8)
        self.assertEqual(len({p.name.split("-")[0] for p in self.snapshots()}), 8)

    def test_corrupt_counter_fails_without_pruning(self):
        self.capture(1)
        before = self.snapshots()
        (self.logs / ".snapshot-sequence").write_text("invalid\n")
        result = self.capture(2, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.snapshots())

    def test_stale_or_missing_counter_recovers_from_existing_snapshots(self):
        self.capture(1)
        (self.logs / ".snapshot-sequence").write_text("0\n")
        self.capture(2, "20261018T000020Z")
        (self.logs / ".snapshot-sequence").unlink()
        self.capture(3, "20261018T000010Z")
        self.assertEqual([p.name.split("-")[0] for p in self.snapshots()],
                         [f"s{i:020d}" for i in range(1, 4)])


if __name__ == "__main__":
    unittest.main()
