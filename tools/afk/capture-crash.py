#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only AFK live capture, durable on the host even if the tablet resets.

Uses the existing AFK SSH configuration. No device installation, network setup,
log clearing, reboot or remoteproc changes. Replayed buffers are intentional;
segments and journal boot IDs distinguish reconnects from new boots.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shlex
import signal
import subprocess
import threading
import time

AFK = Path(__file__).resolve().with_name("afk.sh")


def stamp():
    return {"host_epoch_ns": time.time_ns(), "host_monotonic_ns": time.monotonic_ns()}


def guarded(serial, command):
    # Fixed, read-only identity checks before any evidence stream.
    return "\n".join([
        "set -eu",
        "serial=" + shlex.quote("androidboot.serialno=" + serial),
        'case " $(cat /proc/cmdline) " in *" $serial "*) ;; *) echo WRONG_DEVICE >&2; exit 42;; esac',
        "test -e /etc/liuqin-slpi-disabled || { echo SLPI_MARKER_MISSING >&2; exit 42; }",
        command,
    ])


def stream_command(serial, kind, seconds):
    commands = {
        "kmsg": ["dmesg", "--follow", "--raw"],
        "journal": ["journalctl", "--boot=0", "--follow", "--lines=all", "--all",
                    "--output=json", "--no-pager"],
        "state": ["python3", "-u", "-c", (AFK.parent / "crash-forensics/state.py").read_text()],
    }
    command = commands[kind]
    header = "printf 'AFK_ID boot=%s uptime=%s release=%s\\n' " + \
        '"$(cat /proc/sys/kernel/random/boot_id)" "$(cut -d\' \' -f1 /proc/uptime)" "$(uname -r)"'
    return guarded(serial, header + "\nexec " + shlex.join(
        ["timeout", "--signal=TERM", "--kill-after=3s", str(max(1, math.ceil(seconds))) + "s", *command]))


class Capture:
    def __init__(self, output, serial, seconds, limit, transport=None):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.serial, self.seconds, self.limit = serial, seconds, limit
        self.transport = transport or (lambda script: [str(AFK), "sudo", script])
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.total = 0
        self.error = None
        self.identities = {}
        self.events = (self.output / "events.jsonl").open("xb", buffering=0)

    def event(self, event, **values):
        with self.lock:
            self.events.write((json.dumps({**stamp(), "event": event, **values}) + "\n").encode())
            os.fsync(self.events.fileno())

    def receive(self, argv, name, deadline):
        """Save raw bytes, including incomplete final lines; never wait for newline."""
        offsets = {"stdout": 0, "stderr": 0}
        header = b""
        identified = False
        files = {k: (self.output / f"{name}.{k}").open("xb", buffering=0) for k in offsets}
        process = None
        selector = selectors.DefaultSelector()
        reason = "eof"
        try:
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
            for key in offsets:
                selector.register(getattr(process, key), selectors.EVENT_READ, key)
            self.event("start", segment=name)
            while selector.get_map():
                if self.stop.is_set() or time.monotonic() >= deadline:
                    reason = "stopped" if self.stop.is_set() else "deadline"
                    break
                for item, _ in selector.select(timeout=0.2):
                    data = os.read(item.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(item.fileobj)
                        continue
                    with self.lock:
                        if self.total + len(data) > self.limit:
                            self.error = "byte limit reached; capture incomplete"
                            self.stop.set()
                            reason = "byte-limit"
                            break
                        self.total += len(data)
                    key = item.data
                    start = offsets[key]
                    files[key].write(data)
                    os.fsync(files[key].fileno())
                    offsets[key] += len(data)
                    self.event("data", segment=name, pipe=key, offset=start, bytes=len(data))
                    if key == "stdout" and not identified:
                        header += data
                        if b"\n" in header:
                            first = header.split(b"\n", 1)[0].decode("utf-8", "replace")
                            if not first.startswith("AFK_ID boot="):
                                raise RuntimeError("missing device identity header")
                            identified = True
                            with self.lock:
                                self.identities[name] = first
                            self.event("identity", segment=name, identity=first)
                        elif len(header) > 4096:
                            raise RuntimeError("oversized device identity header")
        finally:
            if process is not None:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                for key in offsets:
                    getattr(process, key).close()
            selector.close()
            for f in files.values():
                os.fsync(f.fileno())
                f.close()
        rc = process.returncode if process else None
        self.event("end", segment=name, returncode=rc, reason=reason, sizes=offsets)
        return rc

    def worker(self, kind, deadline):
        try:
            attempt = 0
            while not self.stop.is_set() and time.monotonic() < deadline:
                attempt += 1
                command = stream_command(self.serial, kind, deadline - time.monotonic())
                rc = self.receive(self.transport(command), f"{kind}-{attempt:05d}", deadline)
                if rc == 42:
                    raise RuntimeError("device identity or SLPI guard failed")
                if (rc not in (0, 124, 137, 255, -signal.SIGTERM) and
                        not self.stop.is_set() and time.monotonic() < deadline - 1):
                    raise RuntimeError(f"{kind} reader failed: status {rc}; inspect stderr")
                if rc == 0 and not self.stop.is_set() and time.monotonic() < deadline - 1:
                    # Follow should not exit successfully while the deadline is far away.
                    raise RuntimeError(f"{kind} follow reader exited early")
                self.stop.wait(min(2, max(0, deadline - time.monotonic())))
        except Exception as e:
            with self.lock:
                self.error = str(e)
            self.stop.set()

    def run(self):
        deadline = time.monotonic() + self.seconds
        self.event("session", serial=self.serial, seconds=self.seconds, byte_limit=self.limit)
        kinds = ("kmsg", "journal", "state")
        workers = [threading.Thread(target=self.worker, args=(k, deadline)) for k in kinds]
        for t in workers:
            t.start()
        for t in workers:
            t.join()
        if not all(any(n.startswith(k + "-") for n in self.identities) for k in kinds):
            self.error = self.error or "one or more streams never connected; inspect stderr"
        self.event("finish", bytes=self.total, error=self.error)
        self.events.close()
        manifest = {"error": self.error, "received_bytes": self.total,
                    "identities": self.identities, "files": {}}
        for p in sorted(self.output.iterdir()):
            if p.is_file():
                h = hashlib.sha256()
                with p.open("rb") as f:
                    for chunk in iter(lambda: f.read(1024 * 1024), b""):
                        h.update(chunk)
                manifest["files"][p.name] = {"bytes": p.stat().st_size, "sha256": h.hexdigest()}
        with (self.output / "manifest.json").open("x") as f:
            json.dump(manifest, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        fd = os.open(self.output, os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return 1 if self.error else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new host directory; never overwrites")
    parser.add_argument("--serial", default="166d5e7b")
    parser.add_argument("--seconds", type=float, default=600)
    parser.add_argument("--max-mib", type=int, default=512)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or not 1 <= args.seconds <= 86400 or args.max_mib < 1:
        parser.error("seconds must be 1..86400 and max-mib must be positive")
    capture = Capture(args.output, args.serial, args.seconds, args.max_mib * 1024**2)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: capture.stop.set())
    raise SystemExit(capture.run())


if __name__ == "__main__":
    main()
