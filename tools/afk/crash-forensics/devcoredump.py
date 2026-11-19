#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Copy remoteproc devcoredumps before they expire; never release them.

Device side (`watch`) scans /sys/class/devcoredump for an entry whose
failing_device is the selected remoteproc, copies `data` while it is still
readable, writes a private local copy, and streams base64 JSON lines to
stdout. Host side (`receive`) rebuilds the dump from that stream and verifies
size and sha256.

The receiver is deliberately read-only: `data` is never written, so a dump is
not released by this tool. The kernel drops an unread dump after five minutes;
write "1" to `data` (or /sys/class/devcoredump/disabled) only after the host
copy has been verified.

Coredump must already be set to "enabled" on the matching remoteproc
(/sys/class/remoteproc/remoteprocN/coredump). The default "disabled" produces
no devcoredump at all. Do not select "inline" here: it reads device memory on
each read and blocks recovery until userspace finishes.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import time

CHUNK = 1024 * 1024


def read_text(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def device_identity(root):
    return {
        "boot_id": read_text(root / "proc/sys/kernel/random/boot_id") or None,
        "uptime": read_text(root / "proc/uptime") or None,
    }


def describe(entry):
    """Return the remoteproc behind one devcd entry, or None if raced."""
    target = Path(os.path.realpath(entry / "failing_device"))
    name = read_text(target / "name")
    if not name:
        return None
    snapshot = {key: read_text(target / key) or None
                for key in ("name", "state", "coredump", "recovery", "firmware")}
    return {"devcd": entry.name, "failing_device": str(target), "rproc": name,
            "rproc_state": snapshot}


def entries(root):
    directory = root / "sys/class/devcoredump"
    try:
        return sorted(p for p in directory.iterdir() if p.name.startswith("devcd"))
    except OSError:
        return []


def emit(out, **record):
    out.write((json.dumps(record, sort_keys=True) + "\n").encode())
    out.flush()


def durable(path, data):
    with path.open("xb") as f:
        os.chmod(path, 0o600)
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def syncdir(path):
    fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def default_reader(fd, offset, count):
    return os.pread(fd, count, offset)


def capture(entry, info, output, out, max_bytes, read_timeout, identity,
            reader=default_reader, clock=time.monotonic):
    """Copy one dump, streaming before anything can reset the tablet."""
    started = clock()
    digest = hashlib.sha256()
    total = 0
    truncated = False
    error = None
    local = None
    path = entry / "data"
    emit(out, kind="dump-begin", **info, **identity, started_ns=time.time_ns())
    try:
        if output is not None:
            output.mkdir(parents=True, exist_ok=True, mode=0o700)
            local = output / ("%s-%s-%d.elf" % (info["rproc"], info["devcd"],
                                                time.time_ns()))
        fd = os.open(path, os.O_RDONLY)
        try:
            local_file = local.open("xb") if local is not None else None
            try:
                if local_file is not None:
                    os.chmod(local, 0o600)
                while True:
                    if clock() - started > read_timeout:
                        error = "read timeout after %d bytes" % total
                        break
                    remaining = max_bytes - total
                    if remaining <= 0:
                        # Ask for one more byte so a capped dump is not
                        # mistaken for a complete one.
                        truncated = bool(reader(fd, total, 1))
                        break
                    chunk = reader(fd, total, min(CHUNK, remaining))
                    if not chunk:
                        break
                    digest.update(chunk)
                    if local_file is not None:
                        local_file.write(chunk)
                    emit(out, kind="dump-chunk", devcd=info["devcd"],
                         offset=total, data=base64.b64encode(chunk).decode())
                    total += len(chunk)
            finally:
                if local_file is not None:
                    local_file.flush()
                    os.fsync(local_file.fileno())
                    local_file.close()
        finally:
            os.close(fd)
    except OSError as e:
        error = "%s: %s" % (type(e).__name__, e)
    if local is not None and total:
        syncdir(local.parent)
        durable(local.with_suffix(".json"),
                (json.dumps({"devcd": info["devcd"], "rproc": info["rproc"],
                             "failing_device": info["failing_device"], "bytes": total,
                             "sha256": digest.hexdigest(), "truncated": truncated,
                             "error": error, "released": False},
                            indent=2, sort_keys=True) + "\n").encode())
        syncdir(local.parent)
    emit(out, kind="dump-end", devcd=info["devcd"], rproc=info["rproc"],
         bytes=total, sha256=digest.hexdigest(), truncated=truncated,
         error=error, local=None if local is None else str(local), released=False)
    return {"devcd": info["devcd"], "bytes": total,
            "sha256": digest.hexdigest(), "truncated": truncated, "error": error}


def watch(root, output, out, rproc="slpi", seconds=30, max_bytes=64 * 1024**2,
          read_timeout=20, poll=0.2, reader=default_reader,
          clock=time.monotonic, sleep=time.sleep):
    """Poll for new dumps for `seconds`; return one result per captured dump."""
    identity = device_identity(root)
    deadline = clock() + seconds
    seen = set()
    results = []
    while clock() < deadline:
        for entry in entries(root):
            if entry.name in seen:
                continue
            info = describe(entry)
            if info is None:
                # The entry may be between creation and link setup; retry.
                continue
            seen.add(entry.name)
            if info["rproc"] != rproc:
                emit(out, kind="ignored", devcd=entry.name, rproc=info["rproc"],
                     reason="not the selected remoteproc")
                continue
            result = capture(entry, info, output, out, max_bytes, read_timeout,
                             identity, reader=reader, clock=clock)
            result.update(identity)
            results.append(result)
        remaining = deadline - clock()
        if remaining > 0:
            sleep(min(poll, remaining))
    emit(out, kind="session-end", rproc=rproc, dumps=len(results),
         **identity, results=results)
    return results


def receive(stream, output):
    """Rebuild and verify dumps from a watch stream; never overwrite."""
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    active = {}
    written = {}
    errors = []
    for number, line in enumerate(stream, 1):
        if not line.strip():
            continue
        if line.startswith(b"AFK_ID "):
            # capture-crash prepends this identity header to every stream.
            continue
        try:
            record = json.loads(line)
        except ValueError as e:
            errors.append("line %d: invalid JSON: %s" % (number, e))
            continue
        kind = record.get("kind")
        name = record.get("devcd")
        if kind == "dump-begin" and name:
            if name in active:
                errors.append("%s: duplicate begin" % name)
                continue
            path = output / ("%s-%s.elf.partial" % (record.get("rproc", "rproc"), name))
            try:
                f = path.open("xb")
            except OSError as e:
                errors.append("%s: cannot create partial: %s" % (name, e))
                continue
            os.chmod(path, 0o600)
            active[name] = {"file": f, "path": path, "hash": hashlib.sha256(),
                            "bytes": 0, "begin": record}
        elif kind == "dump-chunk" and name in active:
            try:
                data = base64.b64decode(record.get("data", ""), validate=True)
            except ValueError as e:
                errors.append("%s: invalid base64: %s" % (name, e))
                continue
            item = active[name]
            if record.get("offset") != item["bytes"]:
                errors.append("%s: non-contiguous chunk at %s" % (name, record.get("offset")))
            item["file"].write(data)
            item["hash"].update(data)
            item["bytes"] += len(data)
        elif kind == "dump-end" and name in active:
            item = active.pop(name)
            f = item["file"]
            f.flush()
            os.fsync(f.fileno())
            f.close()
            ok = (item["hash"].hexdigest() == record.get("sha256") and
                  item["bytes"] == record.get("bytes"))
            final = output / ("%s-%s.elf" % (item["begin"].get("rproc", "rproc"), name))
            metadata = dict(item["begin"])
            metadata.update(record)
            metadata["received_bytes"] = item["bytes"]
            metadata["sha256_verified"] = ok
            metadata["stream_complete"] = True
            if ok:
                os.replace(item["path"], final)
                metadata["saved"] = str(final)
                written[name] = final
            else:
                errors.append("%s: size or sha256 mismatch" % name)
                metadata["saved"] = None
            try:
                durable(final.with_suffix(".json") if ok
                        else item["path"].with_suffix(".json"),
                        (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode())
            except OSError as e:
                errors.append("%s: metadata not saved: %s" % (name, e))
    for name, item in active.items():
        item["file"].flush()
        os.fsync(item["file"].fileno())
        item["file"].close()
        errors.append("%s: stream ended before dump-end; partial kept" % name)
    syncdir(output)
    for name in written:
        print(written[name])
    for error in errors:
        print("error: " + error, file=sys.stderr)
    return 1 if errors else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path("/"),
                        help="fixture root below / (offline tests only)")
    sub = parser.add_subparsers(dest="command", required=True)

    w = sub.add_parser("watch", help="device side: copy dumps and stream them")
    w.add_argument("--output", type=Path, help="private local copy directory")
    w.add_argument("--rproc", default="slpi")
    w.add_argument("--seconds", type=float, default=30)
    w.add_argument("--max-bytes", type=lambda s: int(s, 0), default=64 * 1024**2)
    w.add_argument("--read-timeout", type=float, default=20)

    r = sub.add_parser("receive", help="host side: rebuild and verify a stream")
    r.add_argument("stream", type=Path)
    r.add_argument("--output", type=Path, required=True)

    args = parser.parse_args(argv)
    if args.command == "watch":
        if not 0 < args.seconds <= 86400 or args.max_bytes < 1 or args.read_timeout <= 0:
            parser.error("seconds must be 1..86400, max-bytes positive, read-timeout positive")
        watch(args.root, args.output, sys.stdout.buffer, rproc=args.rproc,
              seconds=args.seconds, max_bytes=args.max_bytes,
              read_timeout=args.read_timeout)
        return 0
    with args.stream.open("rb") as stream:
        return receive(stream, args.output)


if __name__ == "__main__":
    raise SystemExit(main())
