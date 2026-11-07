#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""liuqin GPU hang evidence watcher (TN0081).

Why this exists: on liuqin a wedged GPU leaves the panel dark and touch/keyboard
dead while the kernel, SSH and the rest of userspace keep running.  The usual
crash collectors never fire because there is no panic, no reset and no reboot.
By the time someone notices, dmesg has rotated and the interesting state is
gone.  This daemon is always resident, costs nothing while idle, and snapshots
the live GPU state the moment the driver reports a fault, a hangcheck lockup or
a GMU timeout, so the scene survives even a long delay before anyone looks.

Read-only towards the system: it only reads /proc, /sys, debugfs and the
journal, and writes exclusively below its log directory.

Usage:
    gpu-hang-watch.py daemon            # long-running watcher (systemd)
    gpu-hang-watch.py capture [--reason TEXT]   # snapshot right now
    gpu-hang-watch.py status            # what has been captured so far
"""

import argparse
import collections
import json
import os
import shutil
import signal
import subprocess
import sys
import time

LOG_DIR = os.environ.get("LOGS_DIRECTORY") or "/var/log/liuqin-gpu-hang"
DEBUGFS_GPU = "/sys/kernel/debug/dri/0"
MAX_DUMPS = 40
MAX_BYTES = 512 * 1024 * 1024
MIN_FREE_BYTES = 512 * 1024 * 1024
FULL_COOLDOWN_S = 60
WARN_COOLDOWN_S = 300
HANG_QUIET_S = 600
RING_LINES = 400

HANG_PATTERNS = (
    "hangcheck detected gpu lockup",
    "hangcheck recover!",
    "*** gpu fault:",
    "gpu fault ring",
    "CP | opcode error",
    "Unable to power on the GPU RSC",
    "gpu lockup",
)
WARN_PATTERNS = (
    "timed out waiting for response",
    "Unexpected message id",
    "gmu_set_oob] *ERROR* Timeout",
    "timeout waiting for space in ringbuffer",
    "didn't collapse",
    "Recovered gpu",
)

state = {
    "last_full": 0.0,
    "last_hang": 0.0,
    "last_warn": 0.0,
    "dumps": 0,
    "warn": 0,
    "boot_id": "",
}


def log(msg):
    print(f"gpu-hang-watch: {msg}", file=sys.stderr, flush=True)


def boot_id():
    try:
        return open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError:
        return "unknown"


def stamp():
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def boot_uptime():
    try:
        return float(open("/proc/uptime").read().split()[0])
    except (OSError, ValueError, IndexError):
        return -1.0


def run(cmd, timeout, path=None):
    """Run a read-only collector; never raise, never block the daemon."""
    try:
        cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout, text=True, errors="replace")
        out, rc = cp.stdout, cp.returncode
    except subprocess.TimeoutExpired as exc:
        out = (exc.output or "") if isinstance(exc.output, str) else ""
        out += f"\n[collector timed out after {timeout}s]\n"
        rc = 124
    except OSError as exc:
        out, rc = f"[collector failed: {exc}]\n", 127
    if path:
        try:
            with open(path, "w", errors="replace") as fh:
                fh.write(out)
        except OSError as exc:
            log(f"cannot write {path}: {exc}")
    return out, rc


def write_text(path, text):
    try:
        with open(path, "w", errors="replace") as fh:
            fh.write(text)
    except OSError as exc:
        log(f"cannot write {path}: {exc}")


def collect_sysfs():
    """Cheap, stable sysfs view: GPU clocks, rails, panel, thermal."""
    lines = []
    for rel in (
        "class/devfreq/3d00000.gpu/cur_freq",
        "class/devfreq/3d00000.gpu/min_freq",
        "class/devfreq/3d00000.gpu/max_freq",
        "class/devfreq/3d00000.gpu/governor",
        "class/devfreq/3d00000.gpu/trans_stat",
        "class/drm/card0-DSI-1/status",
        "class/drm/card0-DSI-1/enabled",
        "class/drm/card0-DSI-1/dpms",
        "power/mem_sleep",
        "power/suspend_stats/success",
        "power/suspend_stats/fail",
    ):
        path = "/sys/" + rel
        try:
            val = open(path).read().strip()
        except OSError as exc:
            val = f"<{exc.strerror}>"
        lines.append(f"{rel}: {val.replace(chr(10), ' ')}")
    for bl in ("/sys/class/backlight",):
        try:
            for name in os.listdir(bl):
                base = os.path.join(bl, name)
                for field in ("brightness", "max_brightness", "bl_power"):
                    try:
                        val = open(os.path.join(base, field)).read().strip()
                    except OSError:
                        continue
                    lines.append(f"backlight/{name}/{field}: {val}")
        except OSError:
            pass
    try:
        zones = sorted(os.listdir("/sys/class/thermal"))
    except OSError:
        zones = []
    temps = []
    for z in zones:
        if not z.startswith("thermal_zone"):
            continue
        base = "/sys/class/thermal/" + z
        try:
            kind = open(base + "/type").read().strip()
            val = open(base + "/temp").read().strip()
        except OSError:
            continue
        temps.append(f"{z}({kind})={val}")
    if temps:
        lines.append("thermal: " + " ".join(temps))
    return "\n".join(lines) + "\n"


def collect_fdinfo():
    """Per-process DRM client stats: the only way to say who was using the GPU."""
    chunks = []
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return "[/proc unreadable]\n"
    for pid in pids:
        drm_fds = []
        fd_dir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fd_dir):
                try:
                    target = os.readlink(os.path.join(fd_dir, fd))
                except OSError:
                    continue
                if target.startswith("/dev/dri/"):
                    drm_fds.append((fd, target))
        except OSError:
            continue
        if not drm_fds:
            continue
        try:
            comm = open(f"/proc/{pid}/comm").read().strip()
        except OSError:
            comm = "?"
        chunks.append(f"### pid {pid} ({comm})")
        for fd, target in sorted(drm_fds):
            chunks.append(f"# fd {fd} -> {target}")
            try:
                with open(f"/proc/{pid}/fdinfo/{fd}", errors="replace") as fh:
                    for line in fh:
                        if line.startswith(("drm-", "fd:", "pos:")) or "drm" in line:
                            chunks.append("  " + line.rstrip())
            except OSError as exc:
                chunks.append(f"  <{exc.strerror}>")
        chunks.append("")
    return "\n".join(chunks) if chunks else "[no process held /dev/dri]\n"


def collect_dstate():
    """Kernel stacks of uninterruptible tasks: shows who is stuck on the GPU."""
    out = []
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return "[/proc unreadable]\n"
    for pid in pids:
        try:
            stat = open(f"/proc/{pid}/stat").read().split(")", 1)[1].split()
            st = stat[0]
            comm = open(f"/proc/{pid}/comm").read().strip()
        except (OSError, IndexError):
            continue
        if st not in ("D",):
            continue
        out.append(f"### pid {pid} ({comm}) state={st}")
        try:
            out.append(open(f"/proc/{pid}/stack", errors="replace").read().rstrip())
        except OSError as exc:
            out.append(f"<stack unreadable: {exc.strerror}>")
        out.append("")
    return "\n".join(out) if out else "[no uninterruptible task]\n"


def collect_identity(trigger):
    lines = [
        f"trigger: {trigger}",
        f"boot_id: {boot_id()}",
        f"uptime_s: {boot_uptime():.2f}",
        f"wallclock: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}",
    ]
    for rel in ("proc/sys/kernel/osrelease", "proc/version"):
        try:
            lines.append(f"{rel}: {open('/' + rel).read().strip()}")
        except OSError:
            pass
    for cmd in (["rpm", "-q", "kernel-core"], ["rpm", "-q", "mesa-dri-drivers"],
                ["rpm", "-q", "gnome-shell"]):
        out, _ = run(cmd, 5)
        if out.strip():
            lines.append("pkg: " + out.strip().splitlines()[0])
    for rel in ("/sys/module/msm/version", "/sys/module/adreno/version"):
        try:
            lines.append(f"{rel}: {open(rel).read().strip()}")
        except OSError:
            pass
    return "\n".join(lines) + "\n"


def prune(root):
    """Keep the newest snapshots, but never rotate the first real hang away.

    Long wedges produce one capture per minute; without this the earliest (and
    most valuable) hang snapshot would be the first thing deleted.  `warn`
    snapshots go first, each event dir is tagged in its name.
    """
    try:
        paths = sorted(os.path.join(root, d) for d in os.listdir(root)
                       if d[:8].isdigit() and os.path.isdir(os.path.join(root, d)))
    except OSError:
        return
    protected = ""
    try:
        with open(os.path.join(root, "LAST-HANG.txt"), errors="replace") as fh:
            protected = fh.readline().strip()
    except OSError:
        pass

    sizes = {}
    for p in paths:
        sizes[p] = sum(os.path.getsize(os.path.join(dp, f))
                       for dp, _, fs in os.walk(p) for f in fs
                       if os.path.exists(os.path.join(dp, f)))
    total = sum(sizes.values())

    def droppable():
        # warn first, oldest first, never the protected hang snapshot
        return [p for p in sorted(sizes, key=lambda x: (0 if "-warn" in os.path.basename(x) else 1, x))
                if os.path.abspath(p) != os.path.abspath(protected)]

    while len(sizes) > MAX_DUMPS:
        cand = droppable()
        if not cand:
            break
        shutil.rmtree(cand[0], ignore_errors=True)
        total -= sizes.pop(cand[0], 0)
    while total > MAX_BYTES:
        cand = droppable()
        if not cand:
            break
        shutil.rmtree(cand[0], ignore_errors=True)
        total -= sizes.pop(cand[0], 0)


def capture(level, trigger, ring, output_dir=None, prune_dir=None):
    """Write one evidence directory. Returns the path or None."""
    root = output_dir or LOG_DIR
    dumps_root = prune_dir or LOG_DIR
    try:
        os.makedirs(root, mode=0o750, exist_ok=True)
        free = shutil.disk_usage(root).free
    except OSError as exc:
        log(f"cannot create {root}: {exc}")
        return None
    if free < MIN_FREE_BYTES:
        log(f"refusing to capture: only {free // (1 << 20)} MiB free")
        return None

    dst = os.path.join(root, f"{stamp()}-{boot_id()[:8]}-{level}")
    n = 1
    while os.path.exists(dst):
        n += 1
        dst = os.path.join(root, f"{stamp()}-{boot_id()[:8]}-{level}-{n}")
    try:
        os.makedirs(dst, mode=0o750)
    except OSError as exc:
        log(f"cannot create {dst}: {exc}")
        return None

    started = time.monotonic()
    write_text(os.path.join(dst, "identity.txt"), collect_identity(trigger))
    write_text(os.path.join(dst, "kernel-context.txt"),
               "".join(ring) or "[ring buffer empty]\n")
    run(["dmesg", "-T"], 30, os.path.join(dst, "dmesg.txt"))
    run(["journalctl", "-k", "-b", "--no-pager", "-o", "short-precise",
         "-n", "4000"], 40, os.path.join(dst, "journal-kernel.txt"))
    run(["journalctl", "-b", "--no-pager", "-o", "short-precise",
         "--since", "-10min", "-n", "4000"], 40, os.path.join(dst, "journal-session.txt"))
    run(["journalctl", "-b", "--no-pager", "-o", "short-precise",
         "_UID=1000", "-n", "1000"], 30, os.path.join(dst, "journal-user.txt"))
    run(["ps", "-eo", "pid,ppid,stat,etime,pcpu,pmem,rss,comm,args",
         "--sort=-pcpu"], 15, os.path.join(dst, "ps.txt"))
    run(["cat", "/proc/meminfo"], 10, os.path.join(dst, "meminfo.txt"))
    write_text(os.path.join(dst, "sysfs.txt"), collect_sysfs())
    write_text(os.path.join(dst, "fdinfo-drm.txt"), collect_fdinfo())
    write_text(os.path.join(dst, "dstate-stacks.txt"), collect_dstate())

    # The GPU state dump is the reason this service exists: rings, GMU log/HFI,
    # registers, shader blocks -- all only available while the kernel is alive.
    run(["cat", os.path.join(DEBUGFS_GPU, "gpu")], 25,
        os.path.join(dst, "gpu-state.yaml"))
    run(["cat", os.path.join(DEBUGFS_GPU, "clients")], 15,
        os.path.join(dst, "drm-clients.txt"))

    try:
        os.chmod(dst, 0o750)
    except OSError:
        pass

    with open(os.path.join(dumps_root, "events.csv"), "a") as fh:
        fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')},{level},"
                 f"{boot_id()[:8]},{boot_uptime():.1f},"
                 f"\"{trigger.strip().replace(chr(34), chr(39))[:200]}\"\n")

    summary = os.path.join(dumps_root, "LAST-HANG.txt")
    if level == "hang":
        write_text(summary, f"{dst}\n{time.strftime('%Y-%m-%dT%H:%M:%S%z')}\n"
                             f"boot {boot_id()[:8]} uptime {boot_uptime():.0f}s\n"
                             f"{trigger.strip()}\n")
    prune(dumps_root)
    log(f"captured {level} -> {dst} in {time.monotonic() - started:.1f}s")
    return dst


def is_hang(line):
    low = line.lower()
    return any(p.lower() in low for p in HANG_PATTERNS)


def is_warn(line):
    low = line.lower()
    return any(p.lower() in low for p in WARN_PATTERNS)


def daemon():
    ring = collections.deque(maxlen=RING_LINES)
    os.makedirs(LOG_DIR, mode=0o750, exist_ok=True)
    log(f"watching kernel log, output {LOG_DIR}, boot {boot_id()[:8]}")
    while True:
        try:
            proc = subprocess.Popen(["dmesg", "--follow", "--raw"],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors="replace", bufsize=1)
        except OSError as exc:
            log(f"cannot follow kernel log: {exc}; retrying in 30s")
            time.sleep(30)
            continue
        try:
            for line in proc.stdout:
                ring.append(line if line.endswith("\n") else line + "\n")
                now = time.monotonic()
                if is_hang(line):
                    state["dumps"] += 1
                    if now - state["last_full"] >= FULL_COOLDOWN_S:
                        state["last_full"] = now
                        state["last_hang"] = now
                        capture("hang", line, ring)
                elif is_warn(line):
                    state["warn"] += 1
                    # A hang capture already covers this burst; don't let
                    # repeated GMU timeouts rotate the first snapshot away.
                    if now - state["last_hang"] < HANG_QUIET_S:
                        continue
                    if now - state["last_warn"] >= WARN_COOLDOWN_S:
                        state["last_warn"] = now
                        state["last_full"] = now
                        capture("warn", line, ring)
        except KeyboardInterrupt:
            raise
        except Exception as exc:                     # keep the watcher alive
            log(f"reader error: {exc}")
        finally:
            try:
                proc.terminate()
                proc.wait(timeout=5)
            except Exception:
                pass
        log("kernel log stream ended; restarting in 5s")
        time.sleep(5)


def status():
    root = LOG_DIR
    print(f"log dir: {root}")
    if not os.path.isdir(root):
        print("no captures yet")
        return
    events = os.path.join(root, "events.csv")
    if os.path.exists(events):
        with open(events, errors="replace") as fh:
            lines = fh.readlines()
        print(f"events: {len(lines)}")
        for line in lines[-10:]:
            print("  " + line.rstrip())
    else:
        print("events: 0")
    marker = os.path.join(root, "LAST-HANG.txt")
    if os.path.exists(marker):
        print("last hang:\n  " + open(marker, errors="replace").read().replace("\n", "\n  ").strip())
    dirs = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
    size = sum(os.path.getsize(os.path.join(dp, f)) for d in dirs
               for dp, _, fs in os.walk(os.path.join(root, d)) for f in fs
               if os.path.exists(os.path.join(dp, f)))
    print(f"snapshots: {len(dirs)} ({size / (1 << 20):.1f} MiB)")
    for d in dirs[-5:]:
        print("  " + d)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", nargs="?", default="daemon",
                    choices=("daemon", "capture", "status"))
    ap.add_argument("--reason", default="manual capture")
    ap.add_argument("--output-dir", default=None)
    args = ap.parse_args()

    if args.mode == "daemon":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        daemon()
    elif args.mode == "capture":
        ring = []
        out, _ = run(["dmesg"], 20)
        ring = out.splitlines(keepends=True)[-RING_LINES:]
        path = capture("manual", args.reason, ring, output_dir=args.output_dir,
                       prune_dir=LOG_DIR)
        print(path or "capture failed")
        return 0 if path else 1
    else:
        status()
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
