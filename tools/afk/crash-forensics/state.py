#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only state stream, executed over SSH without installing on the tablet."""
import base64
import json
from pathlib import Path
import time


def read(path):
    try:
        return path.read_text().strip()
    except OSError as e:
        return {"error": str(e)}


def snapshot():
    files = [Path("/proc/cmdline"), Path("/proc/uptime"),
             Path("/sys/power/pm_wakeup_irq"),
             Path("/sys/class/tty/tty0/active")]
    for name in ("adsp", "adsp_island", "apss", "cdsp", "aosd", "cxsd"):
        files.append(Path("/sys/kernel/debug/qcom_stats") / name)
    for p in Path("/sys/class/remoteproc").glob("remoteproc*"):
        files.extend(p / n for n in ("name", "state", "coredump", "recovery"))
    splash = {"pid": read(Path("/run/plymouth/pid"))}
    if isinstance(splash["pid"], str) and splash["pid"].isdigit():
        process = Path("/proc") / splash["pid"]
        for name in ("root", "exe"):
            try:
                splash[name] = str((process / name).readlink())
            except OSError as error:
                splash[name] = {"error": str(error)}
        splash["status"] = read(process / "status")
        splash["drm_fds"] = {}
        for fd in (process / "fd").glob("*"):
            try:
                target = str(fd.readlink())
                if target.startswith("/dev/dri/"):
                    splash["drm_fds"][fd.name] = target
            except OSError:
                pass
    return {"boot_id": read(Path("/proc/sys/kernel/random/boot_id")),
            "files": {str(p): read(p) for p in files}, "plymouth": splash}


def pstore():
    result = {}
    for root in (Path("/sys/fs/pstore"), Path("/var/lib/systemd/pstore")):
        for p in root.rglob("*"):
            if p.is_file() and not p.is_symlink():
                try:
                    with p.open("rb") as f:
                        data = f.read(8 * 1024**2 + 1)
                    result[str(p)] = ({"error": "exceeds 8 MiB"} if len(data) > 8 * 1024**2
                                      else {"base64": base64.b64encode(data).decode()})
                except OSError as e:
                    result[str(p)] = {"error": str(e)}
    return result


def main():
    first = True
    while True:
        data = snapshot()
        if first:
            data["pstore_and_archive"] = pstore()
            first = False
        print(json.dumps(data), flush=True)
        time.sleep(5)


if __name__ == "__main__":
    main()
