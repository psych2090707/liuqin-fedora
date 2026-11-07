#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline simulation fixtures for the liuqin update/rollback chain (TN0032).

Everything here is a regular file under a temporary directory: no block device,
no loop device, no tablet.  The important rule from docs/archive/direction-review-2026-10-20.md §4.2 is
obeyed: **the staging metadata consumed by liuqin-apply-boot is always produced
by running the real producer commands** (liuqin_boot_metadata.py `merge` and
`stage`, i.e. exactly what liuqin-bootimg-refresh and the kernel-install hook
run) — the tests never hand-write the consumer's expected JSON.

Recorded real producer documents live in fixtures/:
  * fixtures/boot-builder-build-info.real-sample.json  — verbatim
    scripts/build-bootimg.sh output (out/boot/build-info.json, 2026-10-20);
  * fixtures/initramfs-info.real-sample.json — verbatim
    scripts/build-initramfs.sh output (out/boot/initramfs/initramfs-info.json).
Their field structure is reused for the simulated release builds; the hash and
path values are recomputed for the test artifacts.  `device_ready=true` /
`dtb.source=stock-rom` in the simulated build-builder document represent a
release build: the recorded offline artifacts are device_ready=false because a
canonical stock-rom DTB requires the user's own stock ROM.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
PROJECT = TESTS.parents[1]
TOOL = PROJECT / "kernel/fedora/liuqin-apply-boot"
METADATA = PROJECT / "kernel/fedora/liuqin_boot_metadata.py"
PAIR = PROJECT / "kernel/fedora/liuqin-kernel-pair"
FIXTURES = TESTS / "fixtures"

PARTITION_BYTES = 201326592
BOOT_V2_HEADER_SIZE = 1660
CHUNK = 4 * 1024 * 1024
KVER = "6.17.0-rc1-gfe81794b5e1b"   # deliberately fixed across releases
BOARD_DTB_REL = "device-tree/qcom/sm8475-xiaomi-liuqin.dtb"


# ---------------------------------------------------------------------------
# hashing / boot image assembly
# ---------------------------------------------------------------------------


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def align(value: int, page: int = 4096) -> int:
    return (value + page - 1) // page * page


def boot_image(kernel_image: bytes, ramdisk: bytes, dtb: bytes) -> bytes:
    """Android boot image v2 exactly like scripts/build-bootimg.sh/mkbootimg:
    the kernel section is the gzip of the Image, ramdisk and final DTB are raw.
    """
    kernel = gzip.compress(kernel_image, mtime=0)
    header = bytearray(BOOT_V2_HEADER_SIZE)
    header[0:8] = b"ANDROID!"
    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 12, 0x8000)
    struct.pack_into("<I", header, 16, len(ramdisk))
    struct.pack_into("<I", header, 20, 0x1000000)
    struct.pack_into("<I", header, 24, 0)          # second_size
    struct.pack_into("<I", header, 32, 0x100)      # tags_addr
    struct.pack_into("<I", header, 36, 4096)       # page_size
    struct.pack_into("<I", header, 40, 2)          # header_version
    struct.pack_into("<I", header, 1632, 0)        # recovery_dtbo_size
    struct.pack_into("<I", header, 1644, BOOT_V2_HEADER_SIZE)
    struct.pack_into("<I", header, 1648, len(dtb))
    struct.pack_into("<Q", header, 1652, 0x1F00000)
    header_page = bytes(header) + b"\x00" * (4096 - BOOT_V2_HEADER_SIZE)
    return (header_page
            + kernel + b"\x00" * (align(len(kernel)) - len(kernel))
            + ramdisk + b"\x00" * (align(len(ramdisk)) - len(ramdisk))
            + dtb)


def padded_partition(image: bytes) -> bytes:
    """image bytes followed by zeros up to the whole 192 MiB partition."""
    return image + b"\x00" * (PARTITION_BYTES - len(image))


def file_sha(path: Path) -> str:
    return sha256_file(Path(path))


# ---------------------------------------------------------------------------
# one simulated release build (kernel + initramfs + contract + documents)
# ---------------------------------------------------------------------------


class Release:
    """A simulated Fedora kernel/initramfs/boot.img release build.

    Distinct tags give distinct kernel Images (and therefore distinct kernel
    pair identities) while the kernelrelease string stays fixed — exactly the
    real constraint that makes the modules-pair archive necessary.
    """

    def __init__(self, root: Path, tag: str):
        self.root = Path(root)
        self.tag = tag
        self.root.mkdir(parents=True, exist_ok=True)
        seed = f"liuqin-release-{tag}".encode()
        self.kernel_image = (seed + b":Image:") * 512            # ~14 KiB Image
        self.board_dtb = b"\xd0\x0d\xfe\xed" + (seed + b":board-dtb:") * 64
        self.final_dtb = b"\xd0\x0d\xfe\xed" + (seed + b":final-dtb:") * 256
        self.ramdisk = (seed + b":initramfs:") * 512
        self.contract = (
            "LIUQIN_FEDORA_ROOT_CONTRACT_V1\n"
            f"# simulate the regenerated admission contract for {tag}\n"
            "/usr/lib/systemd/systemd\n"
            "/usr/bin/plasmashell\n"
        ).encode()
        self.kernel_release = KVER
        self.image = boot_image(self.kernel_image, self.ramdisk, self.final_dtb)
        self.build_dir = self.root / "build"
        self.build_dir.mkdir(exist_ok=True)
        self.image_path = self.build_dir / "boot-liuqin-dev.img"
        self.image_path.write_bytes(self.image)
        self.ramdisk_path = self.build_dir / "liuqin-firstboot.cpio.gz"
        self.ramdisk_path.write_bytes(self.ramdisk)
        self.contract_path = self.build_dir / "liuqin-fedora-root.contract"
        self.contract_path.write_bytes(self.contract)
        # kernel-out layout the boot builder / refresh consume
        self.kernel_out = self.root / "kernel-out"
        (self.kernel_out / "arch/arm64/boot/dts/qcom").mkdir(parents=True, exist_ok=True)
        (self.kernel_out / "include/config").mkdir(parents=True, exist_ok=True)
        (self.kernel_out / "arch/arm64/boot/Image").write_bytes(self.kernel_image)
        (self.kernel_out / f"arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb").write_bytes(
            self.board_dtb)
        (self.kernel_out / "include/config/kernel.release").write_text(self.kernel_release + "\n")
        self.builder_info_path = self.build_dir / "boot-builder-build-info.json"
        self.builder_info_path.write_text(
            json.dumps(self.build_builder_info(), indent=2) + "\n")
        self.initramfs_info_path = self.build_dir / "initramfs-info.json"
        self.initramfs_info_path.write_text(
            json.dumps(self.initramfs_info(), indent=2) + "\n")
        self.binary = build_image_from = None  # noqa: F841 (readability)

    # -- recorded real schema, values recomputed for this release -----------
    def build_builder_info(self) -> dict:
        sample = json.loads((FIXTURES / "boot-builder-build-info.real-sample.json").read_text())
        sample.pop("_provenance", None)
        kernel = gzip.compress(self.kernel_image, mtime=0)
        sample["artifact"] = "boot-liuqin-dev.img"
        sample["artifact_sha256"] = sha256_bytes(self.image)
        sample["artifact_bytes"] = len(self.image)
        sample["fits_partition"] = len(self.image) <= PARTITION_BYTES
        sample["header"]["cmdline"] = ""
        sample["payload"]["kernel"] = {
            "source": "kernel-build",
            "image_sha256": sha256_bytes(self.kernel_image),
            "image_bytes": len(self.kernel_image),
            "gzip_sha256": sha256_bytes(kernel),
            "gzip_bytes": len(kernel),
            "release": self.kernel_release,
        }
        sample["payload"]["ramdisk"] = {
            "path": str(self.ramdisk_path),
            "sha256": sha256_bytes(self.ramdisk),
            "bytes": len(self.ramdisk),
            "mode": "persistent",
            "description": "Fedora-fied stage-1 initramfs (PID 1 /init, BusyBox 1.36.1)",
        }
        sample["payload"]["dtb"] = {
            "source": "stock-rom",
            "provenance": f"simulated canonical stock-rom rebuild for release {self.tag}",
            "sha256": sha256_bytes(self.final_dtb),
            "bytes": len(self.final_dtb),
            "cmdline_source": "DTB /chosen/bootargs",
            "dt_bootargs": "earlycon=simplefb console=tty0 ignore_loglevel",
            "header_cmdline_empty": True,
            "canonical_stock_rom_rebuild": True,
        }
        sample["device_ready"] = True
        return sample

    def initramfs_info(self) -> dict:
        sample = json.loads((FIXTURES / "initramfs-info.real-sample.json").read_text())
        sample.pop("_provenance", None)
        sample["artifact"] = "liuqin-firstboot.cpio.gz"
        sample["artifact_path"] = str(self.ramdisk_path)
        sample["artifact_sha256"] = sha256_bytes(self.ramdisk)
        sample["artifact_bytes"] = len(self.ramdisk)
        sample["device_ready"] = True
        sample["generated_from_synthetic_example_manifest"] = False
        sample["root_contract"] = {
            "path": str(self.contract_path),
            "sha256": sha256_bytes(self.contract),
            "lines": self.contract.decode().count("\n"),
            "bytes": len(self.contract),
            "header": "LIUQIN_FEDORA_ROOT_CONTRACT_V1",
            "generated_from_synthetic_example_manifest": False,
        }
        sample["kernel_release_expected"] = self.kernel_release
        return sample

    # -- rootfs kernel payload ------------------------------------------------
    def kernel_modules_files(self) -> dict:
        """relative path -> bytes for the installed modules tree of this release."""
        return {
            "vmlinuz": self.kernel_image,
            BOARD_DTB_REL: self.board_dtb,
            "kernel/drivers/liuqin_sim.ko": (f"module-{self.tag}".encode()) * 64,
            "modules.dep": f"kernel/drivers/liuqin_sim.ko:\n".encode(),
            "modules.order": b"kernel/drivers/liuqin_sim.ko\n",
        }

    def modules_manifest(self, modules_dir: Path) -> str:
        lines = []
        for rel in sorted(self.kernel_modules_files()):
            data = self.kernel_modules_files()[rel]
            lines.append(f"{sha256_bytes(data)}  {(modules_dir / rel).as_posix()}")
        return "\n".join(lines) + "\n"

    def kernel_build_info(self) -> dict:
        return {
            "schema_version": 1,
            "kernel_version": "6.17.0-rc1",
            "kernel_release": self.kernel_release,
            "artifacts": {
                "dist/Image": {"sha256": sha256_bytes(self.kernel_image),
                               "size": len(self.kernel_image)},
                "dist/sm8475-xiaomi-liuqin.dtb": {
                    "sha256": sha256_bytes(self.board_dtb),
                    "size": len(self.board_dtb)},
            },
            "config": {"sha256": "1" * 64, "audit": {"fedora_ready": True}},
        }


# ---------------------------------------------------------------------------
# simulated tablet root + staging area
# ---------------------------------------------------------------------------


class SimulatedTablet:
    """One simulated device: rootfs, boot_a/boot_b regular files, staging/pair store."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.rootfs = self.root / "rootfs"
        self.rootfs.mkdir(exist_ok=True)
        self.modules_dir = self.rootfs / "usr/lib/modules"
        self.identity_dir = self.rootfs / "usr/share/liuqin"
        self.identity_dir.mkdir(parents=True, exist_ok=True)
        self.staging = self.root / "staging"
        self.staging.mkdir(exist_ok=True)
        self.backup_dir = self.staging / "backup"
        self.pair_store = self.root / "pair-store"
        self.device_a = self.root / "boot_a"
        self.device_b = self.root / "boot_b"
        self.marker = self.rootfs / "etc/liuqin-fedora-root"
        self.marker.parent.mkdir(parents=True, exist_ok=True)
        self.marker.write_text("liuqin-fedora-root-v1\n")
        self.contract_marker = self.rootfs / "etc/liuqin-fedora-root.contract"
        self.contract_marker.write_text(
            "LIUQIN_FEDORA_ROOT_CONTRACT_V1\n/etc/liuqin-fedora-root\n")
        self.release_file = self.identity_dir / "kernel.release"
        self.build_info_file = self.identity_dir / "kernel-build-info.json"
        self.modules_manifest = self.identity_dir / "kernel-modules.manifest"
        self.releases = {}
        self.env = self._base_env()
        self.install_count = 0

    # -- environment ---------------------------------------------------------
    def _base_env(self) -> dict:
        env = os.environ.copy()
        for key in ("LIUQIN_EXPERIMENTAL_DEVICE_WRITE", "LIUQIN_APPLY_TEST_HOLD_LOCK_MS",
                    "LIUQIN_APPLY_TEST_ABORT_WRITE_AFTER",
                    "LIUQIN_APPLY_TEST_READBACK_CORRUPT",
                    "LIUQIN_KERNEL_PAIR_STORE", "LIUQIN_KERNEL_ROOT",
                    "LIUQIN_KERNEL_IDENTITY_DIR", "LIUQIN_KERNEL_BUILD_INFO"):
            env.pop(key, None)
        env.update({
            "LIUQIN_BOOT_STAGING_DIR": str(self.staging),
            "LIUQIN_BOOT_DEVICE": str(self.device_a),
            "LIUQIN_BOOT_DEVICE_B": str(self.device_b),
            "LIUQIN_MODULES_DIR": str(self.modules_dir),
            "LIUQIN_KERNEL_RELEASE_FILE": str(self.release_file),
            "LIUQIN_KERNEL_BUILD_INFO": str(self.build_info_file),
            "LIUQIN_KERNEL_MODULES_MANIFEST": str(self.modules_manifest),
            "LIUQIN_KERNEL_IDENTITY_DIR": str(self.identity_dir),
            "LIUQIN_KERNEL_PAIR_STORE": str(self.pair_store),
            "LIUQIN_KERNEL_PAIR_ALLOW_NONROOT": "1",
            "LIUQIN_APPLY_ROOT_MARKER": str(self.marker),
            "LIUQIN_APPLY_ROOT_CONTRACT": str(self.contract_marker),
            "LIUQIN_APPLY_ALLOW_REGULAR_FILE": "1",
            "LIUQIN_APPLY_TEST_ALLOW_NONROOT_WRITE": "1",
            "LIUQIN_EXPERIMENTAL_DEVICE_WRITE": "1",
            "LIUQIN_BOOT_METADATA_MODULE": str(METADATA),
            "LIUQIN_BOOT_METADATA_TOOL": str(METADATA),
            "LIUQIN_KERNEL_PAIR_TOOL": str(PAIR),
            "PYTHONPATH": str(PROJECT / "kernel/fedora"),
        })
        return env

    def run(self, *args: str, env: dict | None = None, timeout: int = 300,
            tool: Path = TOOL) -> subprocess.CompletedProcess:
        run_env = dict(self.env)
        run_env.update(env or {})
        return subprocess.run([sys.executable, str(tool), *map(str, args)],
                              text=True, capture_output=True, timeout=timeout,
                              env=run_env, cwd=str(self.root))

    # -- releases / install ---------------------------------------------------
    def release(self, tag: str) -> Release:
        if tag not in self.releases:
            self.releases[tag] = Release(self.root / "releases" / tag, tag)
        return self.releases[tag]

    def write_device(self, device: Path, release: Release) -> None:
        with device.open("wb") as stream:
            stream.write(padded_partition(release.image))
            stream.flush()
            os.fsync(stream.fileno())

    def _install_rootfs_payload(self, release: Release) -> None:
        modules = self.modules_dir / release.kernel_release
        if modules.exists():
            shutil.rmtree(modules)
        for rel, data in release.kernel_modules_files().items():
            target = modules / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.release_file.write_text(release.kernel_release + "\n")
        self.build_info_file.write_text(
            json.dumps(release.kernel_build_info(), indent=2) + "\n")
        self.modules_manifest.write_text(release.modules_manifest(modules))

    def install(self, release: Release) -> None:
        """Simulate a factory install: same project boot image on boot_a+boot_b,
        matching modules tree in the rootfs, no journal."""
        self.write_device(self.device_a, release)
        self.write_device(self.device_b, release)
        self._install_rootfs_payload(release)
        self.install_count += 1

    def rpm_upgrade(self, release: Release, *, expect_archive: bool = True) -> dict:
        """Simulate `dnf upgrade kernel-liuqin`: %pre archives the installed pair,
        then rpm replaces the (fixed-path) modules tree and identity files."""
        archive = self.run("archive", "--reason", "rpm-upgrade", tool=PAIR)
        if expect_archive and archive.returncode != 0:
            raise AssertionError(f"pair archive failed: {archive.stdout}{archive.stderr}")
        self._install_rootfs_payload(release)
        return {"archive": archive}

    # -- producer chain: refresh merge + hook staging -------------------------
    def produce_staging(self, release: Release) -> dict:
        """Run the REAL producer commands for this release (no hand-written JSON):

        1. liuqin_boot_metadata.py merge  (what liuqin-bootimg-refresh runs)
        2. copy image/build-info into the staging dir (what the hook does)
        3. liuqin_boot_metadata.py stage  (what the hook runs: validates against
           the staged bytes and the installed kernel Image/board DTB, then writes
           boot-<kver>.manifest + boot-<kver>.SHA256SUMS)
        """
        out_dir = release.build_dir / "refresh-out"
        merged = out_dir / "build-info.json"
        result = self.run(
            "merge",
            "--build-info", str(release.builder_info_path),
            "--initramfs-info", str(release.initramfs_info_path),
            "--kernel-out", str(release.kernel_out),
            "--image", str(release.image_path),
            "--ramdisk", str(release.ramdisk_path),
            "--contract", str(release.contract_path),
            "--kver", release.kernel_release,
            "--dtb-source", "stock-rom",
            "--kernel-build-info", str(self.build_info_file),
            "--generated-by", "liuqin-bootimg-refresh",
            "--generated-at", "2026-10-20T00:00:00Z",
            "--out", str(merged),
            tool=METADATA)
        if result.returncode != 0:
            raise AssertionError(f"producer merge failed: {result.stdout}{result.stderr}")
        staged_image = self.staging / f"boot-{release.kernel_release}.img"
        staged_info = self.staging / f"boot-{release.kernel_release}.build-info.json"
        shutil.copyfile(release.image_path, staged_image)
        shutil.copyfile(merged, staged_info)
        stage = self.run(
            "stage",
            "--build-info", str(staged_info),
            "--image", str(staged_image),
            "--staged-dir", str(self.staging),
            "--kver", release.kernel_release,
            "--kernel-image", str(self.modules_dir / release.kernel_release / "vmlinuz"),
            "--board-dtb", str(self.modules_dir / release.kernel_release / BOARD_DTB_REL),
            tool=METADATA)
        return {"merge": result, "stage": stage, "image": staged_image,
                "build_info": staged_info,
                "manifest": self.staging / f"boot-{release.kernel_release}.manifest",
                "sums": self.staging / f"boot-{release.kernel_release}.SHA256SUMS"}

    def require_staging(self, release: Release) -> Path:
        return self.staging / f"boot-{release.kernel_release}.img"

    # -- tool calls -----------------------------------------------------------
    def apply(self, release: Release, *extra: str, env: dict | None = None):
        return self.run("apply", "--image", str(self.require_staging(release)), *extra,
                        env=env)

    def rollback(self, *extra: str, env: dict | None = None):
        return self.run("rollback", *extra, env=env)

    def confirm(self, *extra: str, env: dict | None = None):
        return self.run("confirm", *extra, env=env)

    def status_json(self, *extra: str, env: dict | None = None) -> dict:
        result = self.run("status", "--json", *extra, env=env)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    # -- state inspection -----------------------------------------------------
    def journal(self) -> dict:
        path = self.staging / "apply-state.json"
        return json.loads(path.read_text()) if path.is_file() else {}

    def backups(self, prefix: str = "boot_a") -> list:
        return sorted(self.backup_dir.glob(f"{prefix}-*.img"))

    def device_sha(self, device: Path) -> str:
        return file_sha(device)

    def padded_sha(self, release: Release) -> str:
        return sha256_bytes(padded_partition(release.image))

    def installed_pair_id(self) -> str:
        return file_sha(self.modules_dir / KVER / "vmlinuz")

    def pair_list(self) -> list:
        result = self.run("list", "--json", tool=PAIR)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)["pairs"]

    def pair_verify(self, pair_id: str):
        return self.run("verify", "--pair-id", pair_id, tool=PAIR)

    def partition_kernel_image_sha(self, device: Path) -> str:
        """Parse the embedded kernel Image sha from a whole padded partition file
        via the schema implementation (the boot payload's kernel pair identity)."""
        sys.path.insert(0, str(PROJECT / "kernel/fedora"))
        try:
            import liuqin_boot_metadata as metadata  # noqa: PLC0415
        finally:
            sys.path.pop(0)
        return metadata.boot_image_sections(Path(device))["kernel_image_sha256"]


def make_tablet(root: Path) -> SimulatedTablet:
    return SimulatedTablet(Path(root))
