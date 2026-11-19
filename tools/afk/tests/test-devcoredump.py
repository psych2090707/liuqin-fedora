#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline devcoredump receiver regressions; no device and no real sysfs."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock

TOOLS = Path(__file__).resolve().parents[1]
MODULE = TOOLS / "crash-forensics/devcoredump.py"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


dec = module("devcoredump", MODULE)
capture = module("capture_devcoredump", TOOLS / "capture-devcoredump.py")


class Devcoredump(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="afk devcd ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "device"
        boot = self.root / "proc/sys/kernel/random/boot_id"
        boot.parent.mkdir(parents=True)
        boot.write_text("33333333-3333-3333-3333-333333333333")
        (self.root / "proc/uptime").write_text("42.50 10.00\n")
        (self.root / "sys/class/devcoredump").mkdir(parents=True)
        self.rproc = self.root / "sys/devices/platform/soc@0/2400000.remoteproc/remoteproc2"
        self.rproc.mkdir(parents=True)
        (self.rproc / "name").write_text("slpi\n")
        (self.rproc / "state").write_text("running\n")
        (self.rproc / "coredump").write_text("enabled\n")
        (self.rproc / "recovery").write_text("enabled\n")

    def add_dump(self, name="devcd0", data=b"ELF\x7f payload", rproc="slpi"):
        target = self.rproc
        if rproc != "slpi":
            target = self.root / "sys/devices/platform/soc@0/other.remoteproc/remoteproc3"
            target.mkdir(parents=True, exist_ok=True)
            (target / "name").write_text(rproc + "\n")
        entry = self.root / "sys/class/devcoredump" / name
        entry.mkdir()
        (entry / "data").write_bytes(data)
        (entry / "failing_device").symlink_to(target)
        return entry

    def stream(self, seconds=0.3, **kwargs):
        out = io.BytesIO()
        results = dec.watch(self.root, self.root / "archive", out, seconds=seconds,
                            poll=0.05, **kwargs)
        return out.getvalue(), results

    def test_arrival_is_copied_streamed_and_verified_on_host(self):
        # Nothing exists at first: the dump must be found on a later poll.
        result = {}
        out = io.BytesIO()

        def watcher():
            result["results"] = dec.watch(self.root, self.root / "archive", out,
                                          seconds=0.8, poll=0.05)

        thread = threading.Thread(target=watcher)
        thread.start()
        time.sleep(0.25)
        entry = self.add_dump(data=b"ELF tail without newline \x00\xff")
        thread.join()
        self.assertEqual(len(result["results"]), 1)
        local, = (self.root / "archive").glob("*.elf")
        self.assertEqual(local.read_bytes(), (entry / "data").read_bytes())
        metadata = json.loads(local.with_suffix(".json").read_text())
        self.assertEqual(metadata["bytes"], (entry / "data").stat().st_size)
        self.assertEqual(metadata["sha256"],
                         hashlib.sha256((entry / "data").read_bytes()).hexdigest())
        self.assertFalse(metadata["released"])
        begin = [json.loads(line) for line in out.getvalue().splitlines()][0]
        self.assertEqual(begin["rproc_state"]["coredump"], "enabled")
        self.assertEqual(begin["rproc_state"]["state"], "running")
        # The receiver never writes or unlinks the source.
        self.assertEqual((entry / "data").read_bytes(), b"ELF tail without newline \x00\xff")

        stream = self.root / "stream.jsonl"
        stream.write_bytes(b"AFK_ID boot=fixture uptime=1 release=fixture\n" +
                           out.getvalue())
        host = self.root / "host"
        with stream.open("rb") as f, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dec.receive(f, host), 0)
        copy, = host.glob("*.elf")
        self.assertEqual(copy.read_bytes(), (entry / "data").read_bytes())
        self.assertTrue(json.loads(copy.with_suffix(".json").read_text())["sha256_verified"])

    def test_other_remoteproc_is_ignored(self):
        self.add_dump(data=b"adsp data", rproc="adsp")
        out, results = self.stream()
        self.assertEqual(results, [])
        self.assertFalse((self.root / "archive").exists() and
                         list((self.root / "archive").glob("*.elf")))
        records = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(records[0]["kind"], "ignored")
        self.assertEqual(records[-1]["kind"], "session-end")
        self.assertEqual(records[-1]["dumps"], 0)

    def test_cap_keeps_prefix_and_marks_truncation(self):
        entry = self.add_dump(data=b"0123456789")
        out, results = self.stream(max_bytes=4)
        local, = (self.root / "archive").glob("*.elf")
        self.assertEqual(local.read_bytes(), b"0123")
        self.assertTrue(results[0]["truncated"])
        self.assertEqual(results[0]["bytes"], 4)
        end = [json.loads(line) for line in out.splitlines()][-2]
        self.assertEqual(end["kind"], "dump-end")
        self.assertTrue(end["truncated"])
        self.assertEqual(end["sha256"], hashlib.sha256(b"0123").hexdigest())

    def test_read_timeout_keeps_partial_without_fake_success(self):
        self.add_dump(data=b"0123456789")
        now = [0.0]

        def clock():
            return now[0]

        def reader(fd, offset, count):
            if offset == 0:
                return b"abc"
            now[0] = 10.0  # the next read stalls past the deadline
            return b"def"

        out = io.BytesIO()
        results = dec.watch(self.root, self.root / "archive", out, seconds=1,
                            max_bytes=100, read_timeout=5, poll=0.05,
                            reader=reader, clock=clock, sleep=lambda _: None)
        self.assertEqual(results[0]["bytes"], 6)
        self.assertIn("read timeout", results[0]["error"])
        end = [json.loads(line) for line in out.getvalue().splitlines()][-2]
        self.assertIn("read timeout", end["error"])
        self.assertEqual(end["sha256"], hashlib.sha256(b"abcdef").hexdigest())

    def test_absence_of_a_dump_is_reported_not_invented(self):
        out, results = self.stream(seconds=0.2)
        self.assertEqual(results, [])
        records = [json.loads(line) for line in out.splitlines()]
        self.assertEqual([r["kind"] for r in records], ["session-end"])
        self.assertEqual(records[0]["dumps"], 0)
        self.assertEqual(records[0]["boot_id"], "33333333-3333-3333-3333-333333333333")

    def test_multiple_chunks_are_contiguous_and_verified(self):
        with unittest.mock.patch.object(dec, "CHUNK", 4):
            self.add_dump(data=b"0123456789")
            out, results = self.stream(max_bytes=100)
        records = [json.loads(line) for line in out.splitlines()]
        chunks = [r for r in records if r["kind"] == "dump-chunk"]
        self.assertEqual([c["offset"] for c in chunks], [0, 4, 8])
        stream = self.root / "chunks.jsonl"
        stream.write_bytes(out)
        host = self.root / "host"
        with stream.open("rb") as f, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dec.receive(f, host), 0)
        copy, = host.glob("*.elf")
        self.assertEqual(copy.read_bytes(), b"0123456789")
        self.assertTrue(results[0]["sha256"])

    def test_host_capture_wrapper_verifies_streamed_dump(self):
        entry = self.add_dump(data=b"streamed bytes")
        out, _ = self.stream()
        header = b"AFK_ID boot=fixture uptime=1 release=fixture\n"

        def transport(script):
            return [sys.executable, "-c",
                    "import sys; sys.stdout.buffer.write(%r); "
                    "sys.stdout.buffer.write(%r)" % (header, out)]

        session = self.root / "session"
        c = capture.Capture(session, "fixture", 1, 1024**2, "slpi", transport)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(c.run(), 0)
        copy, = (session / "receiver").glob("*.elf")
        self.assertEqual(copy.read_bytes(), (entry / "data").read_bytes())
        manifest = json.loads((session / "manifest.json").read_text())
        self.assertEqual(manifest["identity"], "AFK_ID boot=fixture uptime=1 release=fixture")
        self.assertTrue(manifest["dumps"])

    def test_host_capture_without_dump_is_not_reported_as_success(self):
        out = io.BytesIO()
        dec.emit(out, kind="session-end", dumps=0, boot_id="fixture")
        header = b"AFK_ID boot=fixture uptime=1 release=fixture\n"

        def transport(script):
            return [sys.executable, "-c",
                    "import sys; sys.stdout.buffer.write(%r); "
                    "sys.stdout.buffer.write(%r)" % (header, out.getvalue())]

        session = self.root / "empty"
        c = capture.Capture(session, "fixture", 1, 1024**2, "slpi", transport)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(c.run(), 0)
        manifest = json.loads((session / "manifest.json").read_text())
        self.assertEqual(manifest["dumps"], [])
        self.assertIn("no dump observed", manifest["note"])
        self.assertFalse(list((session / "receiver").glob("*.elf")))

    def test_transport_loss_after_identity_is_not_a_watcher_failure(self):
        header = b"AFK_ID boot=fixture uptime=1 release=fixture\n"

        def transport(script):
            return [sys.executable, "-c",
                    "import sys; sys.stdout.buffer.write(%r); "
                    "sys.stdout.buffer.flush(); raise SystemExit(255)" % header]

        session = self.root / "lost"
        c = capture.Capture(session, "fixture", 30, 1024**2, "slpi", transport)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(c.run(), 0)
        manifest = json.loads((session / "manifest.json").read_text())
        self.assertTrue(manifest["transport_lost"])
        self.assertEqual(manifest["dumps"], [])
        self.assertIn("possible reset", manifest["note"])
        self.assertIsNone(manifest["error"])

    def test_transport_loss_before_identity_is_a_failure(self):
        def transport(script):
            return [sys.executable, "-c", "raise SystemExit(255)"]

        session = self.root / "no-identity"
        c = capture.Capture(session, "fixture", 30, 1024**2, "slpi", transport)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(c.run(), 1)
        manifest = json.loads((session / "manifest.json").read_text())
        self.assertIn("before identity", manifest["error"])
        self.assertFalse(manifest["transport_lost"])

    def test_receiver_rejects_bad_digest_and_keeps_partial(self):
        stream = self.root / "bad.jsonl"
        lines = [
            {"kind": "dump-begin", "devcd": "devcd0", "rproc": "slpi"},
            {"kind": "dump-chunk", "devcd": "devcd0", "offset": 0,
             "data": "YWJj"},
            {"kind": "dump-end", "devcd": "devcd0", "rproc": "slpi",
             "bytes": 3, "sha256": "0" * 64},
        ]
        stream.write_text("".join(json.dumps(x) + "\n" for x in lines))
        host = self.root / "host"
        with stream.open("rb") as f, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(dec.receive(f, host), 1)
        self.assertIn("mismatch", stderr.getvalue())
        self.assertFalse(list(host.glob("*.elf")))
        self.assertEqual((host / "slpi-devcd0.elf.partial").read_bytes(), b"abc")

    def test_receiver_keeps_partial_when_stream_ends_early(self):
        stream = self.root / "cut.jsonl"
        stream.write_text(json.dumps({"kind": "dump-begin", "devcd": "devcd0",
                                      "rproc": "slpi"}) + "\n" +
                          json.dumps({"kind": "dump-chunk", "devcd": "devcd0",
                                      "offset": 0, "data": "YWJj"}) + "\n")
        host = self.root / "host"
        with stream.open("rb") as f, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(dec.receive(f, host), 1)
        self.assertIn("ended before dump-end", stderr.getvalue())
        self.assertEqual((host / "slpi-devcd0.elf.partial").read_bytes(), b"abc")


if __name__ == "__main__":
    unittest.main()
