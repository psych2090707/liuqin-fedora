#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Replace only the kernel in the current daily boot; no device operations.

Keeps the device-tested DTB (with its bootargs), ramdisk and second stage
unchanged, so a RAM boot uses the same initramfs and on-disk modules.  The
candidate must therefore use the same kernel release as the daily build and
is identified by its GNU Build ID, not by `uname -r`.
"""
import argparse
import gzip
import hashlib
import json
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
TOOLS = PROJECT / "cache/upstream-v0.6.0/mkbootimg"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(args):
    return subprocess.run([str(x) for x in args], check=True,
                          capture_output=True, text=True).stdout


def masked(args):
    result = list(args)
    for flag in ("--kernel", "--ramdisk", "--dtb", "--second"):
        if flag in result:
            result[result.index(flag) + 1] = "PAYLOAD"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-boot", required=True, type=Path)
    parser.add_argument("--expected-base-sha256", required=True)
    parser.add_argument("--base-kernel-dist", required=True, type=Path)
    parser.add_argument("--kernel-dist", required=True, type=Path)
    parser.add_argument("--vmlinux", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    base = args.base_boot.resolve()
    if sha(base) != args.expected_base_sha256:
        parser.error("base boot does not match the explicitly pinned SHA256")
    info = json.loads((args.kernel_dist.parent / "build-info.json").read_text())
    base_info = json.loads((args.base_kernel_dist.parent / "build-info.json").read_text())
    if info["kernel_release"] != base_info["kernel_release"]:
        parser.error("candidate release differs from the baseline")
    matched = {}
    for name in ("config", "Module.symvers", "modules.sha256", "sm8475-xiaomi-liuqin.dtb"):
        matched[name] = sha(args.kernel_dist / name)
        if matched[name] != sha(args.base_kernel_dist / name):
            parser.error(f"candidate/baseline compatibility mismatch: {name}")
    if sha(args.vmlinux) != info["vmlinux_sha256"]:
        parser.error("vmlinux does not match the candidate build record")
    notes = run(["readelf", "-n", args.vmlinux])
    build_ids = re.findall(r"Build ID: ([0-9a-f]{40})", notes)
    if len(build_ids) != 1:
        parser.error("expected one GNU Build ID in candidate vmlinux")
    build_id = build_ids[0]
    if args.out.exists():
        parser.error(f"output exists: {args.out}")
    image = (args.kernel_dist / "Image").resolve()
    data = image.read_bytes()
    if sha(image) != info["artifacts"]["dist/Image"]["sha256"]:
        parser.error("Image does not match the candidate build record")
    if data[56:60] != b"ARM\x64":
        parser.error("not an uncompressed ARM64 Image")
    if data.count(bytes.fromhex(build_id)) != 1:
        parser.error("candidate Image does not contain the expected unique Build ID")
    args.out.mkdir(parents=True)
    with_temp = tempfile.TemporaryDirectory(dir=args.out, prefix=".repack-")
    with with_temp as tmp:
        tmp = Path(tmp)
        old = tmp / "old"
        cli = shlex.split(run([sys.executable, TOOLS / "unpack_bootimg.py",
                               "--boot_img", base, "--out", old,
                               "--format", "mkbootimg"]))
        control = tmp / "control.img"
        run([sys.executable, TOOLS / "mkbootimg.py", *cli,
             "--output", control])
        if sha(control) != sha(base):
            raise RuntimeError("identity repack differs from the base boot")
        old_payload = (old / "kernel").read_bytes()
        compressed_base = old_payload.startswith(b"\x1f\x8b")
        old_image = gzip.decompress(old_payload) if compressed_base else old_payload
        if old_image != (args.base_kernel_dist / "Image").read_bytes():
            raise RuntimeError("base boot kernel does not match the baseline dist")

        payload = tmp / "Image.payload"
        payload.write_bytes(gzip.compress(data, mtime=0) if compressed_base else data)
        cli[cli.index("--kernel") + 1] = str(payload)
        boot = args.out / "boot.img"
        run([sys.executable, TOOLS / "mkbootimg.py", *cli, "--output", boot])

        new = tmp / "new"
        new_cli = shlex.split(run([sys.executable, TOOLS / "unpack_bootimg.py",
                                   "--boot_img", boot, "--out", new,
                                   "--format", "mkbootimg"]))
        new_payload = (new / "kernel").read_bytes()
        new_image = gzip.decompress(new_payload) if compressed_base else new_payload
        if new_image != data:
            raise RuntimeError("repacked kernel does not match the candidate Image")
        if boot.stat().st_size > 201326592:
            raise RuntimeError("boot image exceeds the recorded liuqin boot partition size")
        if masked(cli) != masked(new_cli):
            raise RuntimeError("boot header changed")
        for name in ("ramdisk", "dtb", "second"):
            if (old / name).exists() != (new / name).exists():
                raise RuntimeError(f"{name} presence changed")
            if (old / name).exists() and sha(old / name) != sha(new / name):
                raise RuntimeError(f"{name} content changed")

        manifest = {
            "status": "verified-offline",
            "device_ready": True,
            "hardware_validated": False,
            "validation_scope": "offline RAM-candidate compatibility and payload checks only",
            "kernel_release": info["kernel_release"],
            "build_id": build_id,
            "base_boot_sha256": sha(base),
            "boot_sha256": sha(boot),
            "artifact_sha256": sha(boot),
            "image_sha256": sha(image),
            "config_sha256": sha(args.kernel_dist / "config"),
            "dtb_sha256": sha(old / "dtb") if (old / "dtb").exists() else None,
            "ramdisk_sha256": sha(old / "ramdisk") if (old / "ramdisk").exists() else None,
            "only_change": "kernel payload",
            "kernel_encoding": "gzip" if compressed_base else "raw-arm64-image",
            "matched_baseline_files": matched,
            "base_identity_repack_identical": True,
            "vmlinux_sha256": sha(args.vmlinux),
        }
        (args.out / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    sys.exit(main())
