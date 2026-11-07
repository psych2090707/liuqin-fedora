#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# liuqin_boot_metadata.py — the SINGLE implementation of the liuqin boot
# metadata schema (v2) shared by every producer and consumer.
#
# Producer/consumer map:
#   liuqin-bootimg-refresh            -> CLI `merge`   (writes build-info.json v2)
#   99-liuqin-android-boot.install    -> CLI `stage`   (validates v2, writes
#                                        boot-<kver>.manifest + .SHA256SUMS)
#   liuqin-apply-boot                 -> imports load_boot_metadata() (consumer)
#   liuqin-kernel-pair / diagnostics  -> CLI `show`
#
# Installed path: /usr/lib/liuqin/liuqin_boot_metadata.py (kernel-liuqin RPM).
# The repo copy (kernel/fedora/liuqin_boot_metadata.py) and the packaged copy
# are byte-identical; the schema documented below is the human contract.
#
# ============================== SCHEMA v2 ==================================
# The metadata file is JSON.  Canonical (nested) locations carry the data; the
# top-level flat keys are projections of the SAME values (validated to be
# equal on load, never independently trusted).  Schema v1 files (the previous
# refresh output: flat bootimg_sha256/kernel_release/dtb_source with the
# boot-builder document nested under "bootimg_build_info") are still READ by
# the consumer so an existing device can diagnose staged images, but staging
# and write-mode apply require schema v2.
#
# {
#   "schema": "liuqin-boot-metadata",
#   "schema_version": 2,
#   "generated_by": "liuqin-bootimg-refresh",
#   "generated_at": "2026-10-20T12:00:00Z" | null,
#   "device_ready": true,
#   # --- flat projections (must equal the nested values below) --------------
#   "kernel_release": "6.17.0-rc1-gfe81794b5e1b",
#   "bootimg_sha256": "<sha256 of the boot.img artifact>",
#   "artifact_sha256": "<same as bootimg_sha256>",
#   "kernel_image_sha256": "<sha256 of the uncompressed kernel Image>",
#   "dtb_source": "stock-rom",
#   "dtb_sha256": "<sha256 of the FINAL DTB embedded in the boot image>",
#   "board_dtb_sha256": "<sha256 of the raw board DTB installed in the kernel package>",
#   "ramdisk_sha256": "<sha256 of the stage-1 initramfs>",
#   "contract_sha256": "<sha256 of the root admission contract>",
#   "contract_pins_kernel_identity": false,
#   # --- canonical nested payload ------------------------------------------
#   "payload": {
#     "artifact": {"sha256", "bytes", "name"},
#     "kernel":   {"release", "image_sha256", "image_bytes",
#                  "gzip_sha256", "gzip_bytes", "compressed", "source"},
#     "ramdisk":  {"sha256", "bytes", "mode"},
#     "dtb":      {"source", "sha256", "bytes", "board_sha256", "board_bytes",
#                  "provenance", "canonical_stock_rom_rebuild",
#                  "cmdline_source", "dt_bootargs", "header_cmdline_empty"}
#   },
#   "contract": {"sha256", "pins_kernel_identity"},
#   "kernel_build": {"config_sha256", "kernel_build_info_sha256"} | null,
#   "builders": {
#     "bootimg":   { ...verbatim scripts/build-bootimg.sh build-info... },
#     "initramfs": { ...verbatim initramfs-info.json... }
#   }
# }
#
# Invariants enforced on load (fail closed):
#   * every flat projection equals its nested canonical value;
#   * artifact_sha256 == bootimg_sha256;
#   * the metadata's own payload hashes are cross-checked against actual bytes
#     at `stage` time and at apply time (image sha/bytes, kernel Image sha,
#     ramdisk sha, final DTB sha);
#   * `merge` additionally cross-checks the boot-builder document against the
#     real boot.img sections (gzip kernel, ramdisk, DTB) and the kernel-out
#     Image/board-DTB, so a producer can never record an artifact whose real
#     contents differ from the recorded identity.
#
# CLI:
#   liuqin_boot_metadata.py merge --build-info B --initramfs-info I \
#       --kernel-out DIR --image IMG --ramdisk RD --contract CT \
#       --kver KVER --dtb-source stock-rom --out OUT/build-info.json \
#       [--kernel-image FILE] [--board-dtb FILE] [--kernel-build-info FILE] \
#       [--generated-by NAME] [--generated-at STAMP]
#   liuqin_boot_metadata.py stage --build-info FILE --image IMG \
#       --staged-dir DIR --kver KVER [--kernel-image FILE] [--board-dtb FILE]
#   liuqin_boot_metadata.py show --build-info FILE [--json]
#
# Exit codes: 0 success; 1 validation/build failure; 2 usage or I/O error.

import argparse
import datetime
import gzip
import hashlib
import json
import os
import struct
import sys
from pathlib import Path

SCHEMA_ID = "liuqin-boot-metadata"
SCHEMA_VERSION = 2
LEGACY_SCHEMA_VERSION = 1
MANIFEST_SCHEMA_VERSION = 2
TOOL = "liuqin-boot-metadata"
TOOL_VERSION = "1.0.0"

BOOT_MAGIC = b"ANDROID!"
BOOT_V2_HEADER_SIZE = 1660
BOOT_FIELD = {
    "kernel_size": 8, "kernel_addr": 12, "ramdisk_size": 16,
    "ramdisk_addr": 20, "second_size": 24, "second_addr": 28,
    "tags_addr": 32, "page_size": 36, "header_version": 40,
    "recovery_dtbo_size": 1632, "header_size": 1644,
    "dtb_size": 1648, "dtb_addr": 1652,
}
PARTITION_BYTES = 201326592
CHUNK = 4 * 1024 * 1024

# Flat v2 keys and the nested canonical value they must equal.
FLAT_ALIASES = {
    "kernel_release": ("payload", "kernel", "release"),
    "bootimg_sha256": ("payload", "artifact", "sha256"),
    "kernel_image_sha256": ("payload", "kernel", "image_sha256"),
    "dtb_source": ("payload", "dtb", "source"),
    "dtb_sha256": ("payload", "dtb", "sha256"),
    "board_dtb_sha256": ("payload", "dtb", "board_sha256"),
    "ramdisk_sha256": ("payload", "ramdisk", "sha256"),
    "contract_sha256": ("contract", "sha256"),
}
REQUIRED_FLAT_V2 = tuple(FLAT_ALIASES) + (
    "artifact_sha256", "contract_pins_kernel_identity", "device_ready")


class MetadataError(Exception):
    """Malformed or inconsistent boot metadata (fail closed)."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _align(value: int, page: int = 4096) -> int:
    return (value + page - 1) // page * page


def boot_image_sections(path: Path) -> dict:
    """Parse an Android boot image v2 and hash every payload section.

    Works on a bare boot.img and on a whole zero-padded 192 MiB partition
    image (only the sections are read).  The kernel section is stored gzipped
    by the release pipeline; the uncompressed Image sha256 is the kernel pair
    identity (it equals sha256(/usr/lib/modules/<kver>/vmlinuz)).
    """
    path = Path(path)
    try:
        size = path.stat().st_size
    except OSError as error:
        raise MetadataError(f"cannot stat {path}: {error}") from error
    if size < BOOT_V2_HEADER_SIZE:
        raise MetadataError(f"{path}: {size} bytes is smaller than a boot v2 header")
    with path.open("rb") as stream:
        header = stream.read(BOOT_V2_HEADER_SIZE)
        if header[:8] != BOOT_MAGIC:
            raise MetadataError(f"{path}: Android boot magic missing (got {header[:8]!r})")
        header_version = _u32(header, BOOT_FIELD["header_version"])
        header_size = _u32(header, BOOT_FIELD["header_size"])
        page_size = _u32(header, BOOT_FIELD["page_size"])
        if header_version != 2:
            raise MetadataError(f"{path}: boot header version {header_version}, expected 2")
        if header_size != BOOT_V2_HEADER_SIZE:
            raise MetadataError(f"{path}: header_size {header_size}, expected {BOOT_V2_HEADER_SIZE}")
        if page_size != 4096:
            raise MetadataError(f"{path}: page size {page_size}, expected 4096")
        kernel_size = _u32(header, BOOT_FIELD["kernel_size"])
        ramdisk_size = _u32(header, BOOT_FIELD["ramdisk_size"])
        second_size = _u32(header, BOOT_FIELD["second_size"])
        recovery_dtbo_size = _u32(header, BOOT_FIELD["recovery_dtbo_size"])
        dtb_size = _u32(header, BOOT_FIELD["dtb_size"])
        if kernel_size == 0 or ramdisk_size == 0:
            raise MetadataError(f"{path}: kernel/ramdisk size is zero")
        if dtb_size == 0:
            raise MetadataError(f"{path}: no DTB in the boot image (v2 requires one)")
        kernel_offset = _align(header_size)
        ramdisk_offset = kernel_offset + _align(kernel_size)
        dtb_offset = (ramdisk_offset + _align(ramdisk_size)
                      + _align(second_size) + _align(recovery_dtbo_size))
        if dtb_offset + dtb_size > size:
            raise MetadataError(
                f"{path}: DTB section [{dtb_offset}, {dtb_offset + dtb_size}) "
                f"exceeds the {size}-byte file")

        def read_section(offset: int, length: int) -> bytes:
            stream.seek(offset)
            data = stream.read(length)
            if len(data) != length:
                raise MetadataError(f"{path}: short read at {offset}+{length}")
            return data

        kernel = read_section(kernel_offset, kernel_size)
        ramdisk = read_section(ramdisk_offset, ramdisk_size)
        dtb = read_section(dtb_offset, dtb_size)

    compressed = kernel[:2] == b"\x1f\x8b"
    if compressed:
        try:
            image = gzip.decompress(kernel)
        except OSError as error:
            raise MetadataError(f"{path}: kernel section is not valid gzip: {error}") from error
        image_sha = hashlib.sha256(image).hexdigest()
        image_bytes = len(image)
    else:
        image_sha = hashlib.sha256(kernel).hexdigest()
        image_bytes = len(kernel)
    return {
        "file_bytes": size,
        "kernel_gzip_sha256": hashlib.sha256(kernel).hexdigest(),
        "kernel_gzip_bytes": len(kernel),
        "kernel_image_sha256": image_sha,
        "kernel_image_bytes": image_bytes,
        "kernel_compressed": compressed,
        "ramdisk_sha256": hashlib.sha256(ramdisk).hexdigest(),
        "ramdisk_bytes": len(ramdisk),
        "dtb_sha256": hashlib.sha256(dtb).hexdigest(),
        "dtb_bytes": len(dtb),
    }


def inspect_boot_payload(path: Path):
    """Convenience wrapper: sections or None when the bytes are not a v2 image."""
    try:
        return boot_image_sections(Path(path))
    except MetadataError:
        return None


def _dig(mapping, keys):
    value = mapping
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def _canonical(fields: dict, raw: dict, *, legacy: bool, warnings: list) -> dict:
    canonical = dict(fields)
    canonical["legacy"] = legacy
    canonical["warnings"] = warnings
    canonical["raw"] = raw
    return canonical


def _canonical_v2(raw: dict) -> dict:
    problems = []
    for key in REQUIRED_FLAT_V2:
        if key not in raw:
            problems.append(f"missing required key: {key}")
    if problems:
        raise MetadataError("schema v2 metadata is incomplete: " + "; ".join(problems))
    if raw.get("schema") not in (None, SCHEMA_ID):
        raise MetadataError(f"unexpected schema id: {raw.get('schema')!r}")
    if raw.get("schema_version") != SCHEMA_VERSION:
        raise MetadataError(f"unexpected schema_version: {raw.get('schema_version')!r}")
    for flat, nested in FLAT_ALIASES.items():
        canonical_value = _dig(raw, nested)
        if canonical_value != raw[flat]:
            raise MetadataError(
                f"schema v2 alias mismatch: {flat}={raw[flat]!r} != "
                f"{'.'.join(nested)}={canonical_value!r}")
    if raw["bootimg_sha256"] != raw["artifact_sha256"]:
        raise MetadataError(
            "schema v2 alias mismatch: bootimg_sha256 != artifact_sha256")
    if raw["contract_pins_kernel_identity"] is not False:
        raise MetadataError(
            "contract_pins_kernel_identity must be false (P0-1: the root admission "
            "contract must not pin the kernel identity)")
    payload = raw["payload"]
    if not isinstance(payload, dict):
        raise MetadataError("payload is not an object")
    artifact = payload.get("artifact") or {}
    if artifact.get("sha256") != raw["artifact_sha256"]:
        raise MetadataError("payload.artifact.sha256 != artifact_sha256")
    fields = {
        "schema": SCHEMA_ID,
        "schema_version": SCHEMA_VERSION,
        "generated_by": raw.get("generated_by"),
        "generated_at": raw.get("generated_at"),
        "device_ready": bool(raw["device_ready"]),
        "kernel_release": raw["kernel_release"],
        "bootimg_sha256": raw["bootimg_sha256"],
        "artifact_sha256": raw["artifact_sha256"],
        "artifact_bytes": artifact.get("bytes"),
        "kernel_image_sha256": raw["kernel_image_sha256"],
        "kernel_gzip_sha256": payload["kernel"].get("gzip_sha256"),
        "kernel_gzip_bytes": payload["kernel"].get("gzip_bytes"),
        "kernel_compressed": payload["kernel"].get("compressed"),
        "kernel_source": payload["kernel"].get("source"),
        "dtb_source": raw["dtb_source"],
        "dtb_sha256": raw["dtb_sha256"],
        "dtb_bytes": payload["dtb"].get("bytes"),
        "board_dtb_sha256": raw["board_dtb_sha256"],
        "ramdisk_sha256": raw["ramdisk_sha256"],
        "contract_sha256": raw["contract_sha256"],
        "contract_pins_kernel_identity": False,
        "kernel_build_config_sha256": _dig(raw, ("kernel_build", "config_sha256")),
        "builders": raw.get("builders") or {},
        "payload": payload,
        "contract": raw.get("contract") or {},
    }
    return _canonical(fields, raw, legacy=False, warnings=[])


def _canonical_v1(raw: dict) -> dict:
    """Map the legacy schema-v1 refresh output onto the canonical view."""
    warnings = ["legacy schema v1 metadata: produced by an older refresh tool; re-run the "
                "kernel-install hook to stage schema v2 before writing"]
    builder = raw.get("bootimg_build_info") or {}
    initramfs = raw.get("initramfs_build_info") or {}
    payload = builder.get("payload") or {}
    bootimg_sha = raw.get("bootimg_sha256")
    artifact_sha = raw.get("artifact_sha256") or bootimg_sha
    if not artifact_sha or not bootimg_sha:
        raise MetadataError("legacy metadata has no bootimg_sha256/artifact_sha256")
    kernel_release = raw.get("kernel_release") or _dig(payload, ("kernel", "release"))
    kernel_image_sha = (raw.get("kernel_image_sha256")
                        or _dig(payload, ("kernel", "image_sha256")))
    dtb_source = raw.get("dtb_source") or _dig(payload, ("dtb", "source"))
    dtb_sha = _dig(payload, ("dtb", "sha256"))
    board_dtb_sha = raw.get("dtb_sha256")  # v1 flat dtb_sha256 was the raw board DTB
    ramdisk_sha = raw.get("ramdisk_sha256") or _dig(payload, ("ramdisk", "sha256"))
    contract_sha = raw.get("contract_sha256") or _dig(initramfs, ("root_contract", "sha256"))
    fields = {
        "schema": SCHEMA_ID,
        "schema_version": LEGACY_SCHEMA_VERSION,
        "generated_by": raw.get("generated_by"),
        "generated_at": raw.get("generated_at"),
        "device_ready": bool(raw.get("device_ready")),
        "kernel_release": kernel_release,
        "bootimg_sha256": bootimg_sha,
        "artifact_sha256": artifact_sha,
        "artifact_bytes": None,
        "kernel_image_sha256": kernel_image_sha,
        "kernel_gzip_sha256": _dig(payload, ("kernel", "gzip_sha256")),
        "kernel_gzip_bytes": _dig(payload, ("kernel", "gzip_bytes")),
        "kernel_compressed": None,
        "kernel_source": _dig(payload, ("kernel", "source")),
        "dtb_source": dtb_source,
        "dtb_sha256": dtb_sha,
        "dtb_bytes": _dig(payload, ("dtb", "bytes")),
        "board_dtb_sha256": board_dtb_sha,
        "ramdisk_sha256": ramdisk_sha,
        "contract_sha256": contract_sha,
        "contract_pins_kernel_identity": bool(
            raw.get("contract_pins_kernel_identity", False)),
        "kernel_build_config_sha256": raw.get("kernel_config_sha256"),
        "builders": {"bootimg": builder, "initramfs": initramfs},
        "payload": payload,
        "contract": {"sha256": contract_sha,
                     "pins_kernel_identity": bool(
                         raw.get("contract_pins_kernel_identity", False))},
    }
    return _canonical(fields, raw, legacy=True, warnings=warnings)


def load_boot_metadata(path) -> dict:
    """Load and normalize a staged build-info document (v2, or legacy v1).

    Returns the canonical dict (see module docstring).  Raises MetadataError
    when the document is malformed or internally inconsistent.  The caller
    decides whether a legacy document is acceptable (write mode is not).
    """
    path = Path(path)
    try:
        raw = json.loads(path.read_text())
    except OSError as error:
        raise MetadataError(f"cannot read {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise MetadataError(f"cannot parse {path}: {error}") from error
    if not isinstance(raw, dict):
        raise MetadataError(f"{path}: metadata is not a JSON object")
    version = raw.get("schema_version")
    if version == SCHEMA_VERSION or raw.get("schema") == SCHEMA_ID:
        return _canonical_v2(raw)
    if version in (None, LEGACY_SCHEMA_VERSION) or "bootimg_build_info" in raw:
        return _canonical_v1(raw)
    raise MetadataError(f"{path}: unsupported schema_version: {version!r}")


# ---------------------------------------------------------------------------
# producer: merge the boot-builder + initramfs documents into schema v2
# ---------------------------------------------------------------------------


def _require(problems: list, label: str, ok: bool, detail: str = "") -> None:
    if not ok:
        problems.append(f"{label}: {detail}" if detail else label)


def merge_metadata(*, build_info: Path, initramfs_info: Path, kernel_out: Path,
                   image: Path, ramdisk: Path, contract: Path, kver: str,
                   dtb_source: str, out: Path, kernel_image=None,
                   board_dtb=None, kernel_build_info=None,
                   generated_by: str = "liuqin-bootimg-refresh",
                   generated_at: str | None = None) -> dict:
    """Build the schema v2 metadata document.  Raises MetadataError on mismatch."""
    try:
        boot = json.loads(Path(build_info).read_text())
        initramfs = json.loads(Path(initramfs_info).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise MetadataError(f"cannot read producer inputs: {error}") from error
    if not isinstance(boot, dict) or not isinstance(initramfs, dict):
        raise MetadataError("producer inputs are not JSON objects")

    kernel_image = Path(kernel_image) if kernel_image else \
        Path(kernel_out) / "arch/arm64/boot/Image"
    board_dtb = Path(board_dtb) if board_dtb else \
        Path(kernel_out) / "arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb"
    image, ramdisk, contract = Path(image), Path(ramdisk), Path(contract)
    for path, label in ((image, "boot image"), (ramdisk, "initramfs"),
                        (contract, "root contract"), (kernel_image, "kernel Image"),
                        (board_dtb, "board DTB")):
        if not path.is_file():
            raise MetadataError(f"missing {label}: {path}")

    problems: list[str] = []
    sections = boot_image_sections(image)
    if sections["file_bytes"] > PARTITION_BYTES:
        problems.append(
            f"boot image is {sections['file_bytes']} bytes, larger than the "
            f"{PARTITION_BYTES}-byte boot partition")
    payload = boot.get("payload") or {}
    _require(problems, "boot-builder device_ready", boot.get("device_ready") is True,
             f"device_ready={boot.get('device_ready')!r}")
    _require(problems, "initramfs device_ready", initramfs.get("device_ready") is True,
             f"device_ready={initramfs.get('device_ready')!r}")
    _require(problems, "initramfs synthetic contract",
             initramfs.get("generated_from_synthetic_example_manifest") is not True,
             "contract was generated from the synthetic example manifest")
    _require(problems, "kernel release", payload.get("kernel", {}).get("release") == kver,
             f"build-info {payload.get('kernel', {}).get('release')!r} != {kver!r}")
    _require(problems, "dtb source", payload.get("dtb", {}).get("source") == dtb_source,
             f"build-info {payload.get('dtb', {}).get('source')!r} != {dtb_source!r}")
    # The recorded boot-builder identity must equal the real boot.img sections.
    for label, recorded, actual in (
            ("boot-builder artifact_sha256", boot.get("artifact_sha256"),
             sha256_file(image)),
            ("boot-builder kernel gzip_sha256", payload.get("kernel", {}).get("gzip_sha256"),
             sections["kernel_gzip_sha256"]),
            ("boot-builder kernel image_sha256", payload.get("kernel", {}).get("image_sha256"),
             sections["kernel_image_sha256"]),
            ("boot-builder ramdisk sha256", payload.get("ramdisk", {}).get("sha256"),
             sections["ramdisk_sha256"]),
            ("boot-builder dtb sha256", payload.get("dtb", {}).get("sha256"),
             sections["dtb_sha256"])):
        if recorded is None:
            problems.append(f"{label}: missing from the boot-builder document")
        elif recorded != actual:
            problems.append(f"{label}: {recorded} != actual {actual}")
    # kernel-out inputs must be the payload really embedded in the boot image.
    _require(problems, "kernel-out Image == boot.img kernel",
             sha256_file(kernel_image) == sections["kernel_image_sha256"],
             f"{sha256_file(kernel_image)} != {sections['kernel_image_sha256']}")
    _require(problems, "ramdisk == boot.img ramdisk",
             sha256_file(ramdisk) == sections["ramdisk_sha256"],
             f"{sha256_file(ramdisk)} != {sections['ramdisk_sha256']}")
    _require(problems, "initramfs artifact_sha256",
             initramfs.get("artifact_sha256") == sections["ramdisk_sha256"],
             f"{initramfs.get('artifact_sha256')} != {sections['ramdisk_sha256']}")
    contract_sha = sha256_file(contract)
    _require(problems, "initramfs contract sha256",
             _dig(initramfs, ("root_contract", "sha256")) == contract_sha,
             f"{_dig(initramfs, ('root_contract', 'sha256'))} != {contract_sha}")
    if problems:
        raise MetadataError("boot identity verification failed:\n  - " + "\n  - ".join(problems))

    config_sha = None
    kernel_build_sha = None
    if kernel_build_info:
        kernel_build_info = Path(kernel_build_info)
        if kernel_build_info.is_file():
            kernel_build_sha = sha256_file(kernel_build_info)
            try:
                config_sha = (json.loads(kernel_build_info.read_text())
                              .get("config", {}).get("sha256"))
            except (OSError, json.JSONDecodeError):
                config_sha = None

    image_sha = sha256_file(image)
    document = {
        "schema": SCHEMA_ID,
        "schema_version": SCHEMA_VERSION,
        "generated_by": generated_by,
        "generated_at": generated_at,
        "device_ready": True,
        "kernel_release": kver,
        "bootimg_sha256": image_sha,
        "artifact_sha256": image_sha,
        "kernel_image_sha256": sections["kernel_image_sha256"],
        "dtb_source": dtb_source,
        "dtb_sha256": sections["dtb_sha256"],
        "board_dtb_sha256": sha256_file(board_dtb),
        "ramdisk_sha256": sections["ramdisk_sha256"],
        "contract_sha256": contract_sha,
        "contract_pins_kernel_identity": False,
        "payload": {
            "artifact": {
                "name": image.name,
                "sha256": image_sha,
                "bytes": sections["file_bytes"],
            },
            "kernel": {
                "release": kver,
                "source": payload.get("kernel", {}).get("source"),
                "image_sha256": sections["kernel_image_sha256"],
                "image_bytes": sections["kernel_image_bytes"],
                "gzip_sha256": sections["kernel_gzip_sha256"],
                "gzip_bytes": sections["kernel_gzip_bytes"],
                "compressed": sections["kernel_compressed"],
            },
            "ramdisk": {
                "sha256": sections["ramdisk_sha256"],
                "bytes": sections["ramdisk_bytes"],
                "mode": (initramfs.get("storage_mode")
                         or boot.get("payload", {}).get("ramdisk", {}).get("mode")),
            },
            "dtb": {
                "source": dtb_source,
                "sha256": sections["dtb_sha256"],
                "bytes": sections["dtb_bytes"],
                "board_sha256": sha256_file(board_dtb),
                "board_bytes": board_dtb.stat().st_size,
                "provenance": _dig(payload, ("dtb", "provenance")),
                "canonical_stock_rom_rebuild": bool(
                    _dig(payload, ("dtb", "canonical_stock_rom_rebuild"))),
                "cmdline_source": _dig(payload, ("dtb", "cmdline_source")),
                "dt_bootargs": _dig(payload, ("dtb", "dt_bootargs")),
                "header_cmdline_empty": _dig(payload, ("dtb", "header_cmdline_empty")),
            },
        },
        "contract": {"sha256": contract_sha, "pins_kernel_identity": False},
        "kernel_build": {"config_sha256": config_sha,
                         "kernel_build_info_sha256": kernel_build_sha},
        "builders": {"bootimg": boot, "initramfs": initramfs},
    }
    # Round-trip through the consumer view so the producer cannot emit a
    # document the consumer would reject.
    load_boot_metadata_dict(document)
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text(json.dumps(document, indent=2) + "\n")
    os.replace(tmp, out)
    return document


def load_boot_metadata_dict(raw: dict) -> dict:
    path = None
    if raw.get("schema_version") == SCHEMA_VERSION:
        return _canonical_v2(raw)
    return _canonical_v1(raw)


# ---------------------------------------------------------------------------
# producer: staged manifest + SHA256SUMS
# ---------------------------------------------------------------------------


def staged_names(kver: str) -> dict:
    base = f"boot-{kver}"
    return {"image": f"{base}.img", "build_info": f"{base}.build-info.json",
            "manifest": f"{base}.manifest", "sums": f"{base}.SHA256SUMS"}


def _atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w") as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)


def stage_metadata(*, build_info: Path, image: Path, staged_dir: Path, kver: str,
                   kernel_image=None, board_dtb=None) -> dict:
    """Validate schema v2 metadata against the staged files and write the
    staging manifest + SHA256SUMS.  Raises MetadataError when inconsistent."""
    metadata = load_boot_metadata(build_info)
    if metadata["legacy"]:
        raise MetadataError(
            "staged build-info is legacy schema v1; the kernel-install hook must "
            "re-stage with the schema v2 metadata tool")
    if metadata["schema_version"] != SCHEMA_VERSION:
        raise MetadataError(f"unsupported schema version {metadata['schema_version']}")
    image = Path(image)
    if not image.is_file():
        raise MetadataError(f"staged image not found: {image}")
    if metadata["device_ready"] is not True:
        raise MetadataError(f"device_ready={metadata['device_ready']!r}")
    if metadata["dtb_source"] != "stock-rom":
        raise MetadataError(f"dtb_source={metadata['dtb_source']!r} is not stock-rom")
    missing = [key for key in ("kernel_release", "kernel_image_sha256",
                               "bootimg_sha256", "dtb_sha256", "board_dtb_sha256",
                               "ramdisk_sha256", "contract_sha256")
               if not metadata.get(key)]
    if missing:
        raise MetadataError("metadata is missing required fields: " + ", ".join(missing))
    if metadata["kernel_release"] != kver:
        raise MetadataError(
            f"metadata kernel_release {metadata['kernel_release']!r} != {kver!r}")
    sections = boot_image_sections(image)
    checks = [
        ("artifact sha256", sha256_file(image), metadata["artifact_sha256"]),
        ("artifact bytes", sections["file_bytes"], metadata["artifact_bytes"]),
        ("kernel image sha256", sections["kernel_image_sha256"],
         metadata["kernel_image_sha256"]),
        ("ramdisk sha256", sections["ramdisk_sha256"], metadata["ramdisk_sha256"]),
        ("dtb sha256", sections["dtb_sha256"], metadata["dtb_sha256"]),
    ]
    if kernel_image:
        checks.append(("installed kernel Image sha256", sha256_file(Path(kernel_image)),
                       metadata["kernel_image_sha256"]))
    if board_dtb:
        checks.append(("installed board DTB sha256", sha256_file(Path(board_dtb)),
                       metadata["board_dtb_sha256"]))
    problems = [f"{label}: {actual} != recorded {recorded}"
                for label, actual, recorded in checks if actual != recorded]
    if problems:
        raise MetadataError("staged metadata does not match the staged bytes:\n  - "
                            + "\n  - ".join(problems))

    staged_dir = Path(staged_dir)
    names = staged_names(kver)
    manifest = {
        "schema_version": str(MANIFEST_SCHEMA_VERSION),
        "kernel_release": metadata["kernel_release"],
        "kernel_image_sha256": metadata["kernel_image_sha256"],
        "dtb_source": metadata["dtb_source"],
        "dtb_sha256": metadata["dtb_sha256"],
        "board_dtb_sha256": metadata["board_dtb_sha256"],
        "bootimg_sha256": metadata["bootimg_sha256"],
        "artifact_sha256": metadata["artifact_sha256"],
        "ramdisk_sha256": metadata["ramdisk_sha256"],
        "contract_sha256": metadata["contract_sha256"],
        "contract_pins_kernel_identity": "false",
        "device_ready": "true",
        "release_gate": "passed",
        "device_write": "not performed (staged only; use liuqin-apply-boot)",
        "qbootctl": "not used; gpt_slot_attributes=not modified",
    }
    lines = ["# liuqin boot image staging manifest (schema v2)"]
    lines += [f"{key}={value}" for key, value in manifest.items()]
    _atomic_text(staged_dir / names["manifest"], "\n".join(lines) + "\n")
    _atomic_text(staged_dir / names["sums"],
                 f"{metadata['artifact_sha256']}  {names['image']}\n")
    return {"schema_version": SCHEMA_VERSION, "kernel_release": metadata["kernel_release"],
            "image": str(image), "bootimg_sha256": metadata["artifact_sha256"],
            "kernel_image_sha256": metadata["kernel_image_sha256"],
            "board_dtb_sha256": metadata["board_dtb_sha256"],
            "manifest": str(staged_dir / names["manifest"]),
            "sha256sums": str(staged_dir / names["sums"]),
            "device_ready": True}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cmd_merge(args) -> int:
    try:
        document = merge_metadata(
            build_info=Path(args.build_info),
            initramfs_info=Path(args.initramfs_info),
            kernel_out=Path(args.kernel_out),
            image=Path(args.image), ramdisk=Path(args.ramdisk),
            contract=Path(args.contract), kver=args.kver,
            dtb_source=args.dtb_source, out=Path(args.out),
            kernel_image=args.kernel_image, board_dtb=args.board_dtb,
            kernel_build_info=args.kernel_build_info,
            generated_by=args.generated_by, generated_at=args.generated_at or _now())
    except MetadataError as error:
        print(f"{TOOL}: merge failed: {error}", file=sys.stderr)
        return 1
    print(f"{TOOL}: merged schema v2 metadata -> {args.out}")
    print(f"{TOOL}: bootimg={document['bootimg_sha256']} "
          f"kernel_image={document['kernel_image_sha256']} "
          f"dtb={document['dtb_sha256']} contract={document['contract_sha256']}")
    return 0


def cmd_stage(args) -> int:
    try:
        summary = stage_metadata(
            build_info=Path(args.build_info), image=Path(args.image),
            staged_dir=Path(args.staged_dir), kver=args.kver,
            kernel_image=args.kernel_image, board_dtb=args.board_dtb)
    except MetadataError as error:
        print(f"{TOOL}: stage failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2))
    return 0


def cmd_show(args) -> int:
    try:
        metadata = load_boot_metadata(Path(args.build_info))
    except MetadataError as error:
        print(f"{TOOL}: cannot load metadata: {error}", file=sys.stderr)
        return 1
    view = {key: metadata[key] for key in (
        "schema", "schema_version", "generated_by", "generated_at", "device_ready",
        "kernel_release", "kernel_image_sha256", "kernel_gzip_sha256",
        "bootimg_sha256", "artifact_sha256", "artifact_bytes", "dtb_source",
        "dtb_sha256", "board_dtb_sha256", "ramdisk_sha256", "contract_sha256",
        "contract_pins_kernel_identity", "kernel_build_config_sha256", "legacy")}
    view["warnings"] = metadata["warnings"]
    if args.json:
        print(json.dumps(view, indent=2, sort_keys=True))
    else:
        print(f"{TOOL} {TOOL_VERSION}: {args.build_info}")
        for key in ("schema_version", "device_ready", "kernel_release",
                    "kernel_image_sha256", "bootimg_sha256", "dtb_source",
                    "dtb_sha256", "board_dtb_sha256", "ramdisk_sha256",
                    "contract_sha256", "legacy"):
            print(f"  {key}: {view[key]}")
        for warning in metadata["warnings"]:
            print(f"  warning: {warning}", file=sys.stderr)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=TOOL, description="liuqin boot metadata schema v2 (single producer/consumer implementation)")
    parser.add_argument("--version", action="version", version=f"{TOOL} {TOOL_VERSION}")
    sub = parser.add_subparsers(dest="command", required=True)

    merge = sub.add_parser("merge", help="merge boot-builder + initramfs documents into schema v2")
    merge.add_argument("--build-info", required=True)
    merge.add_argument("--initramfs-info", required=True)
    merge.add_argument("--kernel-out", required=True)
    merge.add_argument("--image", required=True)
    merge.add_argument("--ramdisk", required=True)
    merge.add_argument("--contract", required=True)
    merge.add_argument("--kver", required=True)
    merge.add_argument("--dtb-source", required=True)
    merge.add_argument("--out", required=True)
    merge.add_argument("--kernel-image", default=None)
    merge.add_argument("--board-dtb", default=None)
    merge.add_argument("--kernel-build-info", default=None)
    merge.add_argument("--generated-by", default="liuqin-bootimg-refresh")
    merge.add_argument("--generated-at", default=None)
    merge.set_defaults(func=cmd_merge)

    stage = sub.add_parser("stage", help="validate schema v2 metadata and write the staged manifest")
    stage.add_argument("--build-info", required=True)
    stage.add_argument("--image", required=True)
    stage.add_argument("--staged-dir", required=True)
    stage.add_argument("--kver", required=True)
    stage.add_argument("--kernel-image", default=None)
    stage.add_argument("--board-dtb", default=None)
    stage.set_defaults(func=cmd_stage)

    show = sub.add_parser("show", help="print the canonical view of a metadata document")
    show.add_argument("--build-info", required=True)
    show.add_argument("--json", action="store_true")
    show.set_defaults(func=cmd_show)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except OSError as error:
        print(f"{TOOL}: I/O error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
