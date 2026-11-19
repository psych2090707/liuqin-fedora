#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run the devcoredump watcher over AFK SSH and verify the host copy.

Uses the existing AFK SSH configuration. Starts the read-only watcher on the
tablet, stores every received line durably, then rebuilds and verifies each
dump with crash-forensics/devcoredump.py. The watcher never releases a dump.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import selectors
import shlex
import signal
import subprocess
import sys

AFK = Path(__file__).resolve().with_name("afk.sh")
RECEIVER = Path(__file__).resolve().parent / "crash-forensics/devcoredump.py"


def receiver_module():
    spec = importlib.util.spec_from_file_location("devcoredump", RECEIVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def guarded(serial, command):
    return "\n".join([
        "set -eu",
        "serial=" + shlex.quote("androidboot.serialno=" + serial),
        'case " $(cat /proc/cmdline) " in *" $serial "*) ;; *) echo WRONG_DEVICE >&2; exit 42;; esac',
        "test -e /etc/liuqin-slpi-disabled || { echo SLPI_MARKER_MISSING >&2; exit 42; }",
        command,
    ])


def watch_command(serial, seconds, max_bytes, rproc):
    source = RECEIVER.read_text()
    header = "printf 'AFK_ID boot=%s uptime=%s release=%s\\n' " + \
        '"$(cat /proc/sys/kernel/random/boot_id)" "$(cut -d\' \' -f1 /proc/uptime)" "$(uname -r)"'
    call = ["timeout", "--signal=TERM", "--kill-after=3s",
            str(max(1, math.ceil(seconds))) + "s",
            "python3", "-u", "-c", source, "watch",
            "--seconds", str(seconds), "--max-bytes", str(max_bytes),
            "--rproc", rproc]
    return guarded(serial, header + "\nexec " + shlex.join(call))


class Capture:
    def __init__(self, output, serial, seconds, max_bytes, rproc, transport=None):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.serial, self.seconds = serial, seconds
        self.max_bytes, self.rproc = max_bytes, rproc
        self.transport = transport or (lambda script: [str(AFK), "sudo", script])
        self.error = None
        self.identity = None
        self.returncode = None
        self.process = None

    def run(self):
        stream_path = self.output / "stream.jsonl"
        stderr_path = self.output / "watch.stderr"
        allow_header = True
        with stream_path.open("xb", buffering=0) as stream, stderr_path.open("xb", buffering=0) as err:
            process = self.process = subprocess.Popen(self.transport(watch_command(
                self.serial, self.seconds, self.max_bytes, self.rproc)),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL, start_new_session=True)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            try:
                while selector.get_map():
                    for item, _ in selector.select(timeout=0.5):
                        data = os.read(item.fileobj.fileno(), 65536)
                        if not data:
                            selector.unregister(item.fileobj)
                            continue
                        target = stream if item.data == "stdout" else err
                        target.write(data)
                        os.fsync(target.fileno())
                        if item.data == "stdout" and allow_header:
                            if b"\n" in data:
                                first = data.split(b"\n", 1)[0].decode("utf-8", "replace")
                                if not first.startswith("AFK_ID boot="):
                                    self.error = "missing device identity header"
                                else:
                                    self.identity = first
                                allow_header = False
                            elif len(data) > 4096:
                                self.error = "oversized device identity header"
            finally:
                selector.close()
                process.stdout.close()
                process.stderr.close()
            self.returncode = process.wait()
        if self.returncode == 42:
            self.error = self.error or "device identity or SLPI guard failed"
        transport_lost = self.returncode == 255 and bool(self.identity)
        if self.returncode == 255 and not self.identity:
            self.error = self.error or "watcher failed: status 255 before identity; inspect watch.stderr"
        if (self.returncode not in (0, 124, 137, 255, -signal.SIGTERM)):
            self.error = self.error or "watcher failed: status %s; inspect watch.stderr" % self.returncode

        result = {"returncode": self.returncode, "identity": self.identity,
                  "transport_lost": transport_lost, "error": self.error, "receiver": None}
        with stream_path.open("rb") as stream:
            rc = receiver_module().receive(stream, self.output / "receiver")
        result["receiver"] = {"returncode": rc}
        if rc != 0:
            self.error = self.error or "stream incomplete or digest mismatch; partial evidence kept"
        received = sorted((self.output / "receiver").glob("*.elf"))
        result["dumps"] = [p.name for p in received]
        if transport_lost and not received and rc == 0:
            result["note"] = ("transport ended before the watcher timeout (possible reset); "
                              "no dump observed, neither success nor proof that none was generated")
        elif not received:
            result["note"] = "no dump observed; neither success nor proof that none was generated"
        else:
            result["note"] = "verified dump(s) saved"
        result["error"] = self.error
        with (self.output / "manifest.json").open("x") as f:
            json.dump(result, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        fd = os.open(self.output, os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        if self.error:
            print("error: " + self.error, file=sys.stderr)
        print(result["note"])
        return 1 if self.error else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True, help="new host directory")
    parser.add_argument("--serial", default="166d5e7b")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--max-mib", type=int, default=64)
    parser.add_argument("--rproc", default="slpi")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or not 1 <= args.seconds <= 86400 or args.max_mib < 1:
        parser.error("seconds must be 1..86400 and max-mib must be positive")
    capture = Capture(args.output, args.serial, args.seconds,
                      args.max_mib * 1024**2, args.rproc)

    def stop(*_):
        if capture.process is not None and capture.process.poll() is None:
            os.killpg(capture.process.pid, signal.SIGTERM)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)
    raise SystemExit(capture.run())


if __name__ == "__main__":
    main()
