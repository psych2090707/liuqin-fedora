#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Copy pstore before systemd-pstore unlinks it; never erase the source.

Each directory is named for the RECEIVING boot. The producer boot of pstore
records is deliberately unknown until matched to an embedded boot marker.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


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


def read(path):
    try:
        return path.read_text().strip()
    except OSError as e:
        return {"error": str(e)}


def archive(destination, root=Path("/"), max_bytes=256 * 1024**2, pon_module_dir=None):
    boot = str(uuid.UUID((root / "proc/sys/kernel/random/boot_id").read_text().strip()))
    destination = Path(destination)
    if destination.is_symlink():
        raise RuntimeError("archive destination is a symlink")
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    used = sum(p.stat().st_size for p in destination.rglob("*") if p.is_file())
    # Keep room for metadata; refuse instead of pruning evidence automatically.
    if used + 1024**2 > max_bytes:
        raise RuntimeError("archive capacity reached; preserve and export existing evidence")
    output = Path(tempfile.mkdtemp(prefix=boot + "-", dir=destination))
    errors = []
    metadata = {"receiving_boot_id": boot, "producer_boot_id": None,
                "captured_epoch_ns": time.time_ns(), "files": {}, "errors": errors}
    if pon_module_dir is not None:
        module = Path(pon_module_dir) / (os.uname().release + ".ko")
        loaded = False
        try:
            if Path("/sys/module/afk_pon_snapshot").exists():
                raise RuntimeError("PON module already loaded; refusing a potentially stale snapshot")
            subprocess.run(["insmod", str(module)], check=True, timeout=5, capture_output=True)
            loaded = True
            raw = Path("/sys/module/afk_pon_snapshot/parameters/raw_hex").read_text().strip()
            if len(bytes.fromhex(raw)) != 128:
                raise RuntimeError("incomplete PON snapshot")
            durable(output / "pon-sdam.hex", (raw + "\n").encode())
            metadata["pon"] = "pon-sdam.hex; PMIC history has no boot IDs or wall times"
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as e:
            errors.append(f"PON: {e}")
        finally:
            if loaded:
                try:
                    subprocess.run(["rmmod", "afk_pon_snapshot"], check=True, timeout=5, capture_output=True)
                except (OSError, subprocess.SubprocessError) as e:
                    errors.append(f"PON unload: {e}")
    for name in ("proc/cmdline", "proc/uptime", "proc/iomem"):
        metadata[name] = read(root / name)
    metadata["ramoops"] = {p.name: read(p) for p in
                            (root / "sys/module/ramoops/parameters").glob("*") if p.is_file()}
    for name in ("sys/firmware/devicetree/base/reserved-memory",
                 "sys/firmware/devicetree/base/liuqin-abl-overlay-sink/pmic-pon-log"):
        metadata[name] = {str(p.relative_to(root / name)): base64.b64encode(p.read_bytes()).decode()
                          for p in (root / name).rglob("*") if p.is_file()}
    pstore = root / "sys/fs/pstore"
    metadata["pstore_source_exists"] = pstore.is_dir()
    for source in sorted(pstore.iterdir()) if pstore.is_dir() else []:
        if source.is_symlink() or not source.is_file():
            errors.append(f"ignored non-regular pstore entry: {source.name}")
            continue
        try:
            # pstore stat sizes can be zero; bound the actual read.
            with source.open("rb") as f:
                data = f.read(min(16 * 1024**2, max_bytes - used) + 1)
            if len(data) > min(16 * 1024**2, max_bytes - used):
                raise RuntimeError("pstore file exceeds archive limit")
            durable(output / source.name, data)
            used += len(data)
            metadata["files"][source.name] = len(data)
        except (OSError, RuntimeError) as e:
            errors.append(f"{source.name}: {e}")
    # Store errors durably as well. A nonzero exit never means "no crash".
    durable(output / "metadata.json", (json.dumps(metadata, indent=2) + "\n").encode())
    syncdir(output)
    syncdir(destination)
    print(output)
    if errors:
        raise RuntimeError("; ".join(errors))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/var/lib/afk/crash"))
    parser.add_argument("--pon-module-dir", type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("root required")
    archive(args.output, pon_module_dir=args.pon_module_dir)


if __name__ == "__main__":
    main()
