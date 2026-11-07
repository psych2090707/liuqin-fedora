#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""One RAM-only fbdev OFF/ON before GDM, using the community recovery path."""
import fcntl
import json
import os
from pathlib import Path
import struct
import sys
import time

marker = Path("/run/liuqin-ram-display.json")
if marker.exists():
    print("liuqin RAM display: already attempted in this boot", flush=True)
    sys.exit(0)

state = {"status": "starting", "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}


def save():
    marker.write_text(json.dumps(state, indent=2) + "\n")
    print("liuqin RAM display: " + json.dumps(state), flush=True)


try:
    identity = json.loads(Path("/run/liuqin-kernel-ram-test.json").read_text())
    if identity["mode"] != "RAM only" or os.uname().release != identity["kernel_release"]:
        raise RuntimeError("RAM kernel identity missing or wrong")
    notes = Path("/sys/kernel/notes").read_bytes()
    pos = 0
    build_id = None
    while pos + 12 <= len(notes):
        n, d, kind = struct.unpack_from("<III", notes, pos)
        pos += 12
        name = notes[pos:pos + n].rstrip(b"\0")
        pos = (pos + n + 3) & ~3
        desc = notes[pos:pos + d]
        pos = (pos + d + 3) & ~3
        if name == b"GNU" and kind == 3:
            build_id = desc.hex()
    if build_id != identity["gnu_build_id"]:
        raise RuntimeError("live GNU Build ID mismatch")
    state["gnu_build_id"] = build_id
    save()  # No automatic repetition on a GDM restart or a failed attempt.

    deadline = time.monotonic() + 30
    name_path = Path("/sys/class/graphics/fb0/name")
    while not (name_path.exists() and Path("/dev/fb0").exists()):
        if time.monotonic() >= deadline:
            raise RuntimeError("msm fbdev did not become ready within 30 seconds")
        time.sleep(0.1)
    if name_path.read_text().strip() != "msmdrmfb":
        raise RuntimeError("fb0 is not the msm framebuffer")

    # GDM has not started yet. Refuse to blank another DRM master's display.
    clients = Path("/sys/kernel/debug/dri/0/clients").read_text().splitlines()
    if any(len(p) > 3 and p[3] == "y" for p in (line.split() for line in clients[1:])):
        raise RuntimeError("a userspace DRM master is already active")

    fd = os.open("/dev/fb0", os.O_RDWR | os.O_CLOEXEC)
    try:
        try:
            fcntl.ioctl(fd, 0x4611, 4)  # FBIOBLANK, FB_BLANK_POWERDOWN
        finally:
            fcntl.ioctl(fd, 0x4611, 0)  # Always attempt FB_BLANK_UNBLANK.
    finally:
        os.close(fd)
    state["status"] = "ioctls_completed"
    save()  # Physical display acceptance still requires the user's observation.
except Exception as error:
    state.update(status="failed", error=str(error))
    save()
    sys.exit(1)
