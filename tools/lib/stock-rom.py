#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""liuqin stock-ROM input extraction and validation library.

The Fedora liuqin boot.img canonical path needs two kinds of stock-ROM inputs
that are not distributed with any project repository:

  * 44 DTBO overlay entries from the ROM's ``dtbo.img`` (Android DT table /
    DTBO image format), and
  * 14 base DTBs from the ``vendor_boot.img`` dtb section (also an Android
    DT table on this device).

This module parses those *real* on-disk formats (no placeholder logic) and
writes them in the layout the boot builder expects.  Format references:

  * Android DT table / DTBO image format: ``dt_table_header`` (magic
    ``0xd7b7ab1e``) and ``dt_table_entry``
    https://source.android.com/docs/core/architecture/dto/partitions
  * Android vendor_boot image header v3 (2112 B) / v4 (2128 B) and the
    section layout, from AOSP ``system/tools/mkbootimg``
    ``include/bootimg/bootimg.h`` (the project pins a copy of that repo under
    ``cache/upstream-v0.6.0/mkbootimg``; the parser constants below were taken
    from it and are cross-checked by ``tests/stock-rom`` against AOSP
    ``mkbootimg.py``/``unpack_bootimg.py``).
  * Android boot image header v2 (1660 B), used only to reverse-check the
    published v0.6.0 boot.img as an independent real artifact.

The tool only reads files the user provides (extracted ROM directory or a ROM
archive) and writes below the requested output directory.  It never downloads
a ROM and never includes ROM content in the project tree.
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import shutil
import struct
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Iterable, Optional

TOOL_NAME = "extract-stock-rom-inputs"
TOOL_VERSION = "1.0.0"
SCHEMA_VERSION = 1

# --- Android DT table (DTBO image) -----------------------------------------
# The AOSP dt_table_header/dt_table_entry fields are stored BIG-ENDIAN in every
# image the Android tooling and ABL actually consume (like the FDT header
# itself).  Some early in-project synthetic fixtures were written
# little-endian, so the parser detects the byte order from the magic and
# accepts both; production images always take the big-endian path.
DT_TABLE_MAGIC = 0xD7B7AB1E
DT_TABLE_MAGIC_BE = DT_TABLE_MAGIC.to_bytes(4, "big")    # b"\xd7\xb7\xab\x1e"
DT_TABLE_MAGIC_LE = DT_TABLE_MAGIC.to_bytes(4, "little")  # b"\x1e\xab\xb7\xd7"
# magic, total_size, header_size, dt_entry_size, dt_entry_count,
# dt_entries_offset, page_size, version
DT_TABLE_HEADER = struct.Struct(">8I")
DT_TABLE_HEADER_LE = struct.Struct("<8I")
# dt_size, dt_offset, id, rev, custom[4]
DT_TABLE_ENTRY = struct.Struct(">8I")
DT_TABLE_ENTRY_LE = struct.Struct("<8I")
DT_TABLE_MIN_HEADER_SIZE = DT_TABLE_HEADER.size  # 32
DT_TABLE_MIN_ENTRY_SIZE = DT_TABLE_ENTRY.size  # 32

# --- vendor_boot header (AOSP bootimg.h) ------------------------------------
VENDOR_BOOT_MAGIC = b"VNDRBOOT"
VENDOR_BOOT_V3_HEADER_SIZE = 2112
VENDOR_BOOT_V4_HEADER_SIZE = 2128
# 8s magic, I header_version, I page_size, I kernel_addr, I ramdisk_addr,
# I vendor_ramdisk_size, 2048s cmdline, I tags_addr, 16s name, I header_size,
# I dtb_size, Q dtb_addr
VENDOR_BOOT_HEADER = struct.Struct("<8sIIIII2048sI16sIIQ")
VENDOR_BOOT_V4_EXT = struct.Struct("<4I")
# vendor_ramdisk_table_size, entry_num, entry_size, bootconfig_size

# --- boot image header v2 (reverse validation of the published image) ------
BOOT_MAGIC = b"ANDROID!"
BOOT_V2_HEADER_SIZE = 1660
# Offsets inside the packed v0+ structure; documented in AOSP bootimg.h.
BOOT_FIELD = {
    "kernel_size": 8,
    "kernel_addr": 12,
    "ramdisk_size": 16,
    "ramdisk_addr": 20,
    "second_size": 24,
    "tags_addr": 32,
    "page_size": 36,
    "header_version": 40,
    "recovery_dtbo_size": 1632,
    "recovery_dtbo_offset": 1636,
    "header_size": 1644,
    "dtb_size": 1648,
    "dtb_addr": 1652,
}

FDT_MAGIC = 0xD00DFEED
FDT_MAGIC_BYTES = FDT_MAGIC.to_bytes(4, "big")  # big-endian on disk in every FDT
FDT_HEADER = struct.Struct(">10I")
# magic, totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap, version,
# last_comp_version, boot_cpuid_phys, size_dt_strings, size_dt_struct

# Pinned stock ROM identity table (read-only upstream input).
DEFAULT_ROM_IMAGES_JSON = (
    Path(__file__).resolve().parents[2]
    / "upstream/xiaomipad-6pro-mainline/tools/lib/liuqin-rom-images.json"
)

DTBO_IMAGE = "dtbo.img"
VENDOR_BOOT_IMAGE = "vendor_boot.img"
BOOT_IMAGE = "boot.img"

DEFAULT_EXPECTED_DTBO_ENTRIES = 44
DEFAULT_EXPECTED_VENDOR_DTBS = 14
DTB02_INDEX = 2


class StockRomError(Exception):
    """Base error; the CLI maps subclasses to distinct exit codes."""


class UsageError(StockRomError):
    """Bad arguments / unusable output directory."""


class InputError(StockRomError):
    """ROM file missing, unreadable or in an unsupported container format."""


class FormatError(StockRomError):
    """A ROM image does not match the real Android on-disk format."""


class CountError(StockRomError):
    """Extracted entry count does not match the expected fail-closed count."""


class ManifestError(StockRomError):
    """A previously written manifest does not match the files on disk."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# FDT (flattened device tree) sanity checks
# ---------------------------------------------------------------------------


def fdt_info(data: bytes) -> dict:
    """Return basic FDT identity for an extracted DT/DTBO payload."""
    if len(data) < FDT_HEADER.size:
        raise FormatError(f"payload is {len(data)} bytes, smaller than an FDT header")
    fields = FDT_HEADER.unpack_from(data, 0)
    magic, totalsize, off_struct, off_strings, off_rsvmap, version, last_comp, _, size_strings, size_struct = fields
    if magic != FDT_MAGIC:
        raise FormatError(f"payload is not an FDT (magic {magic:#010x}, expected {FDT_MAGIC:#010x})")
    if totalsize < FDT_HEADER.size or totalsize > len(data):
        raise FormatError(f"FDT totalsize {totalsize} is invalid for a {len(data)}-byte payload")
    for label, offset in (("structure", off_struct), ("strings", off_strings), ("mem_rsvmap", off_rsvmap)):
        if offset >= totalsize:
            raise FormatError(f"FDT {label} offset {offset} is outside totalsize {totalsize}")
    if off_struct + size_struct > totalsize or off_strings + size_strings > totalsize:
        raise FormatError("FDT block sizes exceed totalsize")
    return {
        "magic": f"{magic:#010x}",
        "totalsize": totalsize,
        "version": version,
        "last_comp_version": last_comp,
        "size_dt_strings": size_strings,
        "size_dt_struct": size_struct,
        "bytes": len(data),
        "payload_after_fdt": len(data) - totalsize,
    }


# ---------------------------------------------------------------------------
# Android DT table (dtbo.img and vendor_boot dtb section)
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class DtEntry:
    index: int
    dt_size: int
    dt_offset: int
    id: int
    rev: int
    custom: tuple[int, int, int, int]
    data: bytes

    def summary(self) -> dict:
        return {
            "index": self.index,
            "dt_size": self.dt_size,
            "dt_offset": self.dt_offset,
            "id": self.id,
            "rev": self.rev,
            "custom": list(self.custom),
            "sha256": sha256_bytes(self.data),
            "fdt": fdt_info(self.data),
        }


@dataclasses.dataclass
class DtTable:
    total_size: int
    header_size: int
    dt_entry_size: int
    dt_entries_offset: int
    page_size: int
    version: int
    entries: list[DtEntry]
    trailing_bytes: int
    source: str = ""
    endian: str = "big"
    container: str = "dt_table"

    @property
    def count(self) -> int:
        return len(self.entries)

    def summary(self) -> dict:
        return {
            "source": self.source,
            "magic": f"{DT_TABLE_MAGIC:#010x}",
            "container": self.container,
            "endian": self.endian,
            "total_size": self.total_size,
            "header_size": self.header_size,
            "dt_entry_size": self.dt_entry_size,
            "dt_entries_offset": self.dt_entries_offset,
            "page_size": self.page_size,
            "version": self.version,
            "entry_count": self.count,
            "entry_bytes_total": sum(entry.dt_size for entry in self.entries),
            "trailing_bytes": self.trailing_bytes,
        }


def parse_dt_table(data: bytes, source: str = "dt_table") -> DtTable:
    """Parse an Android DT table (DTBO image format) from *data*.

    The table may be stored inside a larger, page-padded partition image
    (``total_size`` bounds the table; the remaining bytes are flash padding),
    which is exactly how ``dtbo.img`` ships in a Fastboot ROM.
    """
    if len(data) < DT_TABLE_HEADER.size:
        raise FormatError(f"{source}: {len(data)} bytes is smaller than a DT table header")
    # Byte order comes from the magic: real ROM images (mkdtimg / ABL) are
    # big-endian, the project's earliest synthetic fixtures were little-endian.
    if data[:4] == DT_TABLE_MAGIC_BE:
        header_struct, entry_struct, endian = DT_TABLE_HEADER, DT_TABLE_ENTRY, "big"
    elif data[:4] == DT_TABLE_MAGIC_LE:
        header_struct, entry_struct, endian = DT_TABLE_HEADER_LE, DT_TABLE_ENTRY_LE, "little"
    else:
        magic = int.from_bytes(data[:4], "big")
        raise FormatError(
            f"{source}: bad DT table magic {magic:#010x} (expected {DT_TABLE_MAGIC:#010x})"
        )
    magic, total_size, header_size, entry_size, entry_count, entries_offset, page_size, version = (
        header_struct.unpack_from(data, 0)
    )
    if magic != DT_TABLE_MAGIC:
        raise FormatError(
            f"{source}: bad DT table magic {magic:#010x} (expected {DT_TABLE_MAGIC:#010x})"
        )
    if version != 0:
        raise FormatError(f"{source}: unsupported DT table version {version} (expected 0)")
    if header_size < DT_TABLE_MIN_HEADER_SIZE or header_size > len(data):
        raise FormatError(f"{source}: invalid dt_table_header size {header_size}")
    if entry_size < DT_TABLE_MIN_ENTRY_SIZE:
        raise FormatError(f"{source}: dt_entry_size {entry_size} is smaller than {DT_TABLE_MIN_ENTRY_SIZE}")
    if total_size < header_size or total_size > len(data):
        raise FormatError(f"{source}: total_size {total_size} is outside the {len(data)}-byte image")
    if entries_offset < header_size:
        raise FormatError(f"{source}: dt_entries_offset {entries_offset} overlaps the header")
    if entry_count == 0:
        raise FormatError(f"{source}: DT table has no entries")
    if entries_offset + entry_count * entry_size > total_size:
        raise FormatError(f"{source}: entry table does not fit into total_size {total_size}")
    entries: list[DtEntry] = []
    for index in range(entry_count):
        offset = entries_offset + index * entry_size
        dt_size, dt_offset, entry_id, rev, *custom = entry_struct.unpack_from(data, offset)
        if dt_size == 0:
            raise FormatError(f"{source}: entry {index} has dt_size 0")
        if dt_offset < header_size or dt_offset + dt_size > total_size:
            raise FormatError(
                f"{source}: entry {index} payload [{dt_offset}, {dt_offset + dt_size}) "
                f"is outside total_size {total_size}"
            )
        payload = data[dt_offset:dt_offset + dt_size]
        if len(payload) != dt_size:
            raise FormatError(f"{source}: entry {index} payload is truncated")
        entries.append(
            DtEntry(index=index, dt_size=dt_size, dt_offset=dt_offset, id=entry_id,
                    rev=rev, custom=tuple(custom), data=payload)
        )
    return DtTable(
        total_size=total_size,
        header_size=header_size,
        dt_entry_size=entry_size,
        dt_entries_offset=entries_offset,
        page_size=page_size,
        version=version,
        entries=entries,
        trailing_bytes=len(data) - total_size,
        source=source,
        endian=endian,
    )


def parse_dtb_list(data: bytes, source: str = "dtb section") -> DtTable:
    """Parse a concatenated FDT blob list (the real vendor_boot dtb section).

    A Xiaomi/Qualcomm ``vendor_boot.img`` stores the base DTBs by simply
    concatenating the FDT blobs: each blob starts with ``0xd00dfeed`` and its
    big-endian ``totalsize`` field gives the offset of the next blob.  There is
    no alignment padding and no containing DT table, so the section is walked
    until exactly ``len(data)`` bytes have been consumed.
    """
    entries: list[DtEntry] = []
    pos = 0
    while pos < len(data):
        if data[pos:pos + 4] != FDT_MAGIC_BYTES:
            raise FormatError(
                f"{source}: no FDT magic at offset {pos} of a {len(data)}-byte dtb list"
            )
        if pos + FDT_HEADER.size > len(data):
            raise FormatError(f"{source}: FDT header at offset {pos} is truncated")
        totalsize = struct.unpack_from(">I", data, pos + 4)[0]
        if totalsize < FDT_HEADER.size or pos + totalsize > len(data):
            raise FormatError(
                f"{source}: FDT at offset {pos} declares totalsize {totalsize}, "
                f"outside the {len(data)}-byte section"
            )
        payload = data[pos:pos + totalsize]
        fdt_info(payload)  # validates magic/offsets, raises FormatError
        entries.append(
            DtEntry(index=len(entries), dt_size=totalsize, dt_offset=pos,
                    id=len(entries), rev=0, custom=(0, 0, 0, 0), data=payload)
        )
        pos += totalsize
    if not entries:
        raise FormatError(f"{source}: empty dtb list")
    return DtTable(
        total_size=len(data),
        header_size=0,
        dt_entry_size=0,
        dt_entries_offset=0,
        page_size=0,
        version=0,
        entries=entries,
        trailing_bytes=0,
        source=source,
        endian="big",
        container="fdt_list",
    )


def parse_dtb_container(data: bytes, source: str = "dtb section") -> DtTable:
    """Parse a dtb section that is either a DT table or a bare FDT list.

    Real Xiaomi Fastboot ROMs use the FDT-list form for ``vendor_boot.img``;
    the project's synthetic fixtures and some AOSP images use a ``dt_table``.
    The container is detected from the first four bytes, so neither form is
    silently misread.
    """
    if data[:4] == FDT_MAGIC_BYTES:
        return parse_dtb_list(data, source=source)
    return parse_dt_table(data, source=source)


# ---------------------------------------------------------------------------
# vendor_boot image (header v3/v4, dtb section)
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class VendorBootImage:
    header_version: int
    page_size: int
    vendor_ramdisk_size: int
    dtb_size: int
    dtb_addr: int
    header_size: int
    dtb_offset: int
    dtb_bytes: bytes
    ramdisk_table_entry_num: int
    bootconfig_size: int
    file_bytes: int

    def summary(self) -> dict:
        return {
            "header_version": self.header_version,
            "page_size": self.page_size,
            "header_size": self.header_size,
            "vendor_ramdisk_size": self.vendor_ramdisk_size,
            "dtb_size": self.dtb_size,
            "dtb_addr": f"{self.dtb_addr:#x}",
            "dtb_offset": self.dtb_offset,
            "ramdisk_table_entry_num": self.ramdisk_table_entry_num,
            "bootconfig_size": self.bootconfig_size,
            "file_bytes": self.file_bytes,
        }


def _align(value: int, page_size: int) -> int:
    if page_size <= 0:
        raise FormatError(f"invalid page size {page_size}")
    return (value + page_size - 1) // page_size * page_size


def parse_vendor_boot(data: bytes, source: str = "vendor_boot.img") -> VendorBootImage:
    if len(data) < VENDOR_BOOT_HEADER.size:
        raise FormatError(f"{source}: {len(data)} bytes is smaller than a vendor_boot header")
    (magic, header_version, page_size, _kernel_addr, _ramdisk_addr, vendor_ramdisk_size,
     _cmdline, _tags_addr, _name, header_size, dtb_size, dtb_addr) = (
        VENDOR_BOOT_HEADER.unpack_from(data, 0)
    )
    if magic != VENDOR_BOOT_MAGIC:
        raise FormatError(f"{source}: bad magic {magic!r} (expected {VENDOR_BOOT_MAGIC!r})")
    if header_version not in (3, 4):
        raise FormatError(f"{source}: unsupported vendor_boot header version {header_version} (expected 3 or 4)")
    expected_header_size = VENDOR_BOOT_V4_HEADER_SIZE if header_version == 4 else VENDOR_BOOT_V3_HEADER_SIZE
    if header_size != expected_header_size:
        raise FormatError(
            f"{source}: header_size {header_size} does not match vendor_boot v{header_version} "
            f"({expected_header_size} bytes)"
        )
    if page_size <= 0 or page_size > (1 << 20):
        raise FormatError(f"{source}: implausible page_size {page_size}")
    if dtb_size == 0:
        raise FormatError(f"{source}: dtb_size is 0 (the base DTB table is required)")
    header_pages = _align(header_size, page_size)
    ramdisk_pages = _align(vendor_ramdisk_size, page_size)
    dtb_offset = header_pages + ramdisk_pages
    dtb_end = dtb_offset + dtb_size
    if dtb_end > len(data):
        raise FormatError(
            f"{source}: dtb section [{dtb_offset}, {dtb_end}) exceeds the {len(data)}-byte image"
        )
    ramdisk_entry_num = 0
    bootconfig_size = 0
    if header_version == 4:
        if len(data) < VENDOR_BOOT_V4_HEADER_SIZE:
            raise FormatError(f"{source}: header v4 extension is truncated")
        _table_size, ramdisk_entry_num, _entry_size, bootconfig_size = VENDOR_BOOT_V4_EXT.unpack_from(
            data, VENDOR_BOOT_V3_HEADER_SIZE
        )
    return VendorBootImage(
        header_version=header_version,
        page_size=page_size,
        vendor_ramdisk_size=vendor_ramdisk_size,
        dtb_size=dtb_size,
        dtb_addr=dtb_addr,
        header_size=header_size,
        dtb_offset=dtb_offset,
        dtb_bytes=data[dtb_offset:dtb_end],
        ramdisk_table_entry_num=ramdisk_entry_num,
        bootconfig_size=bootconfig_size,
        file_bytes=len(data),
    )


# ---------------------------------------------------------------------------
# boot image v2 (reverse validation of the published image)
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class BootImageV2:
    page_size: int
    header_version: int
    kernel_size: int
    ramdisk_size: int
    second_size: int
    recovery_dtbo_size: int
    dtb_size: int
    dtb_addr: int
    kernel: bytes
    ramdisk: bytes
    dtb: bytes
    file_bytes: int
    page_padding_ok: bool

    def summary(self) -> dict:
        return {
            "header_version": self.header_version,
            "page_size": self.page_size,
            "kernel_size": self.kernel_size,
            "ramdisk_size": self.ramdisk_size,
            "second_size": self.second_size,
            "recovery_dtbo_size": self.recovery_dtbo_size,
            "dtb_size": self.dtb_size,
            "dtb_addr": f"{self.dtb_addr:#x}",
            "file_bytes": self.file_bytes,
            "page_padding_ok": self.page_padding_ok,
        }


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def parse_boot_image_v2(data: bytes, source: str = "boot.img") -> BootImageV2:
    if len(data) < BOOT_V2_HEADER_SIZE:
        raise FormatError(f"{source}: {len(data)} bytes is smaller than a boot v2 header")
    if data[:8] != BOOT_MAGIC:
        raise FormatError(f"{source}: bad boot image magic {data[:8]!r}")
    page_size = _u32(data, BOOT_FIELD["page_size"])
    header_version = _u32(data, BOOT_FIELD["header_version"])
    header_size = _u32(data, BOOT_FIELD["header_size"])
    kernel_size = _u32(data, BOOT_FIELD["kernel_size"])
    ramdisk_size = _u32(data, BOOT_FIELD["ramdisk_size"])
    second_size = _u32(data, BOOT_FIELD["second_size"])
    recovery_dtbo_size = _u32(data, BOOT_FIELD["recovery_dtbo_size"])
    dtb_size = _u32(data, BOOT_FIELD["dtb_size"])
    dtb_addr = struct.unpack_from("<Q", data, BOOT_FIELD["dtb_addr"])[0]
    if header_version != 2:
        raise FormatError(f"{source}: header version {header_version}, expected 2")
    if header_size != BOOT_V2_HEADER_SIZE:
        raise FormatError(f"{source}: header_size {header_size}, expected {BOOT_V2_HEADER_SIZE}")
    if page_size <= 0 or page_size > (1 << 20):
        raise FormatError(f"{source}: implausible page size {page_size}")
    if kernel_size == 0 or ramdisk_size == 0 or dtb_size == 0:
        raise FormatError(f"{source}: kernel/ramdisk/dtb sizes must all be non-zero")
    offsets = {}
    cursor = _align(header_size, page_size)
    for name, size in (("kernel", kernel_size), ("ramdisk", ramdisk_size),
                       ("second", second_size), ("recovery_dtbo", recovery_dtbo_size),
                       ("dtb", dtb_size)):
        offsets[name] = (cursor, cursor + size)
        cursor += _align(size, page_size)
    if offsets["dtb"][1] > len(data):
        raise FormatError(f"{source}: dtb section exceeds the {len(data)}-byte image")
    padding_ok = True
    for name in ("kernel", "ramdisk", "dtb"):
        start, end = offsets[name]
        padded = _align(end, page_size)
        if padded > len(data):
            padding_ok = False
            continue
        if any(data[end:padded]):
            padding_ok = False
    kernel = data[slice(*offsets["kernel"])]
    ramdisk = data[slice(*offsets["ramdisk"])]
    dtb = data[slice(*offsets["dtb"])]
    return BootImageV2(
        page_size=page_size,
        header_version=header_version,
        kernel_size=kernel_size,
        ramdisk_size=ramdisk_size,
        second_size=second_size,
        recovery_dtbo_size=recovery_dtbo_size,
        dtb_size=dtb_size,
        dtb_addr=dtb_addr,
        kernel=kernel,
        ramdisk=ramdisk,
        dtb=dtb,
        file_bytes=len(data),
        page_padding_ok=padding_ok,
    )


# ---------------------------------------------------------------------------
# Pinned stock ROM identity table
# ---------------------------------------------------------------------------


class RomImages:
    """The upstream pinned stock-ROM image identity table."""

    def __init__(self, table: dict, source_path: Path):
        self.table = table
        self.source_path = source_path
        self.rom = table.get("rom", "")
        self.package = table.get("package", "")
        self.images = table.get("images", {})

    @classmethod
    def load(cls, path: Optional[Path] = None) -> "RomImages":
        path = Path(path) if path else DEFAULT_ROM_IMAGES_JSON
        if not path.is_file():
            raise InputError(f"stock ROM identity table is unavailable: {path}")
        try:
            table = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            raise InputError(f"cannot parse {path}: {error}") from error
        if not isinstance(table.get("images"), dict) or not table["images"]:
            raise InputError(f"{path} does not contain an images table")
        return cls(table, path)

    def expected(self, image_name: str) -> Optional[dict]:
        entry = self.images.get(image_name)
        if entry is None:
            return None
        return {
            "bytes": entry.get("bytes"),
            "sha256": entry.get("sha256"),
            "partition": entry.get("partition"),
            "sparse": entry.get("sparse", False),
        }


# ---------------------------------------------------------------------------
# ROM input resolving (directory or archive)
# ---------------------------------------------------------------------------

ARCHIVE_SUFFIXES = (".tgz", ".tar.gz", ".tar.bz2", ".tar.xz", ".tar", ".zip")
MAX_SEARCH_DEPTH = 4


def _archive_open(path: Path):
    if path.suffix.lower() == ".zip":
        return zipfile.ZipFile(path)
    return tarfile.open(path, "r:*")


def _archive_members(handle) -> list[str]:
    if isinstance(handle, zipfile.ZipFile):
        return [info.filename for info in handle.infolist() if not info.is_dir()]
    return [member.name for member in handle.getmembers() if member.isfile()]


def _archive_extract(handle, member: str, destination: Path) -> None:
    if isinstance(handle, zipfile.ZipFile):
        with handle.open(member) as source, destination.open("wb") as target:
            shutil.copyfileobj(source, target)
    else:
        source = handle.extractfile(member)
        if source is None:
            raise InputError(f"cannot read archive member {member}")
        with source, destination.open("wb") as target:
            shutil.copyfileobj(source, target)


def _pick_member(members: Iterable[str], image_name: str, container: str) -> str:
    wanted = image_name.lower()
    matches = [member for member in members if Path(member).name.lower() == wanted]
    if not matches:
        raise InputError(f"{container}: no {image_name} found in the ROM archive")
    if len(matches) > 1:
        preferred = [member for member in matches if "/images/" in "/" + member.lower()]
        matches = preferred or matches
    if len(matches) > 1:
        raise InputError(f"{container}: ambiguous {image_name} members: {sorted(matches)[:4]}")
    return matches[0]


def _find_in_directory(root: Path, image_name: str) -> Path:
    root = root.resolve()
    candidates: list[tuple[int, Path]] = []
    for current, dirnames, filenames in os.walk(root):
        rel = Path(current).relative_to(root)
        depth = 0 if rel == Path(".") else len(rel.parts)
        if depth > MAX_SEARCH_DEPTH:
            dirnames[:] = []
            continue
        for filename in filenames:
            if filename.lower() == image_name.lower():
                candidates.append((depth, Path(current) / filename))
    if not candidates:
        raise InputError(f"{root}: no {image_name} found (expected an extracted Fastboot ROM or images/ directory)")
    if len(candidates) > 1:
        preferred = [item for item in candidates if "images" in item[1].parts]
        candidates = preferred or candidates
    if len(candidates) > 1:
        raise InputError(f"{root}: ambiguous {image_name}: {[str(item[1]) for item in candidates][:4]}")
    return candidates[0][1]


class RomSource:
    """Read-only view of the three stock images in a ROM directory or archive."""

    REQUIRED = (DTBO_IMAGE, VENDOR_BOOT_IMAGE)
    OPTIONAL = (BOOT_IMAGE,)

    def __init__(self, path: Path):
        path = Path(path)
        if not path.exists():
            raise InputError(f"stock ROM input does not exist: {path}")
        self.source_path = path.resolve()
        self.kind = "directory" if self.source_path.is_dir() else "archive"
        if self.kind == "archive":
            lowered = self.source_path.name.lower()
            if not any(lowered.endswith(suffix) for suffix in ARCHIVE_SUFFIXES):
                raise InputError(
                    f"unsupported ROM container {self.source_path.name}; "
                    f"expected a directory or one of {ARCHIVE_SUFFIXES}"
                )
        self._tmpdir: Optional[tempfile.TemporaryDirectory] = None
        self._paths: dict[str, Path] = {}
        self._load()

    def _load(self) -> None:
        if self.kind == "directory":
            for name in self.REQUIRED + self.OPTIONAL:
                try:
                    self._paths[name] = _find_in_directory(self.source_path, name)
                except InputError:
                    if name in self.OPTIONAL:
                        continue
                    raise
            return
        self._tmpdir = tempfile.TemporaryDirectory(prefix="liuqin-stock-rom-")
        temp_root = Path(self._tmpdir.name)
        try:
            with _archive_open(self.source_path) as handle:
                members = _archive_members(handle)
                for name in self.REQUIRED + self.OPTIONAL:
                    try:
                        member = _pick_member(members, name, str(self.source_path))
                    except InputError:
                        if name in self.OPTIONAL:
                            continue
                        raise
                    destination = temp_root / name
                    _archive_extract(handle, member, destination)
                    self._paths[name] = destination
        except (tarfile.TarError, zipfile.BadZipFile, OSError) as error:
            self.close()
            raise InputError(f"cannot read ROM archive {self.source_path}: {error}") from error

    @property
    def files(self) -> dict[str, Path]:
        return dict(self._paths)

    def read(self, image_name: str) -> bytes:
        path = self._paths.get(image_name)
        if path is None:
            raise InputError(f"{image_name} is not present in {self.source_path}")
        try:
            return path.read_bytes()
        except OSError as error:
            raise InputError(f"cannot read {path}: {error}") from error

    def close(self) -> None:
        if self._tmpdir is not None:
            self._tmpdir.cleanup()
            self._tmpdir = None

    def __enter__(self) -> "RomSource":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

LAYOUTS = ("analysis", "flat", "both")


def _layout_paths(out_dir: Path, layout: str) -> dict[str, Path]:
    if layout not in LAYOUTS:
        raise UsageError(f"unknown layout {layout!r} (expected one of {LAYOUTS})")
    if layout == "analysis":
        return {
            "dtbo": out_dir / "analysis/dtbo",
            "dtbs": out_dir / "analysis/vendor_boot/dtbs",
            "dtb02": out_dir / "analysis/vendor_boot",
        }
    if layout == "flat":
        return {
            "dtbo": out_dir / "dtbo",
            "dtbs": out_dir / "vendor_boot/dtbs",
            "dtb02": out_dir / "vendor_boot",
        }
    return {
        "dtbo": out_dir / "analysis/dtbo",
        "dtbs": out_dir / "analysis/vendor_boot/dtbs",
        "dtb02": out_dir / "analysis/vendor_boot",
        "dtbo_flat": out_dir / "dtbo",
        "dtbs_flat": out_dir / "vendor_boot/dtbs",
        "dtb02_flat": out_dir / "vendor_boot",
    }


def _write_payload(path: Path, data: bytes, out_dir: Path) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return {
        "path": str(path.resolve().relative_to(out_dir.resolve())),
        "bytes": len(data),
        "sha256": sha256_bytes(data),
    }


def _entry_name(index: int) -> str:
    return f"entry.{index:02d}"


def _dtb_name(index: int) -> str:
    return f"dtb-{index:02d}.dtb"


def extract(
    rom_path: Path,
    out_dir: Path,
    *,
    layout: str = "both",
    expected_dtbo: int = DEFAULT_EXPECTED_DTBO_ENTRIES,
    expected_dtb: int = DEFAULT_EXPECTED_VENDOR_DTBS,
    write_dtb02: bool = True,
    rom_images: Optional[RomImages] = None,
    allow_unknown_version: bool = True,
    dry_run: bool = False,
    force: bool = False,
    log=lambda message: None,
) -> dict:
    """Extract the 44 DTBO entries and 14 vendor_boot base DTBs.

    Raises InputError/FormatError/CountError/UsageError.  Nothing is written
    before the full parse and the fail-closed count checks have succeeded.
    """
    out_dir = Path(out_dir)
    if out_dir.exists() and any(out_dir.iterdir()) and not force and not dry_run:
        raise UsageError(f"output directory is not empty: {out_dir} (pass --force to overwrite)")
    rom_images = rom_images or RomImages.load()
    notes: list[str] = []
    warnings: list[str] = []
    layout_map = _layout_paths(out_dir, layout)

    with RomSource(rom_path) as rom:
        rom_files = {}
        for name in (DTBO_IMAGE, VENDOR_BOOT_IMAGE, BOOT_IMAGE):
            if name not in rom.files:
                rom_files[name] = {"present": False}
                continue
            data = rom.read(name)
            expected = rom_images.expected(name)
            matches = bool(
                expected
                and expected.get("bytes") == len(data)
                and expected.get("sha256") == sha256_bytes(data)
            )
            rom_files[name] = {
                "present": True,
                "bytes": len(data),
                "sha256": sha256_bytes(data),
                "known_version_image": matches,
                "expected": expected,
                "source_name": rom.files[name].name,
            }
            if not matches:
                message = (
                    f"{name} ({len(data)} bytes, sha256 {sha256_bytes(data)[:16]}…) does not match "
                    f"the pinned {rom_images.rom or 'stock ROM'} table"
                )
                if allow_unknown_version:
                    warnings.append(message + "; extracting anyway (unknown ROM version)")
                else:
                    raise InputError(message + "; --strict-known requested")
        if not rom_files[BOOT_IMAGE].get("present"):
            notes.append("boot.img is not present in the ROM input; only dtbo.img/vendor_boot.img are required")
        known = all(
            entry.get("known_version_image")
            for name, entry in rom_files.items()
            if entry.get("present")
        ) and rom_files[DTBO_IMAGE]["present"] and rom_files[VENDOR_BOOT_IMAGE]["present"]

        dtbo_data = rom.read(DTBO_IMAGE)
        vendor_data = rom.read(VENDOR_BOOT_IMAGE)
        dtbo = parse_dt_table(dtbo_data, source=str(rom.files[DTBO_IMAGE]))
        vendor = parse_vendor_boot(vendor_data, source=str(rom.files[VENDOR_BOOT_IMAGE]))
        base_table = parse_dtb_container(vendor.dtb_bytes, source="vendor_boot dtb section")
        notes.append(
            f"vendor_boot v{vendor.header_version}: page_size={vendor.page_size}, "
            f"dtb section {vendor.dtb_size} B at offset {vendor.dtb_offset}"
        )

        # Fail-closed counts before any write.
        if dtbo.count != expected_dtbo:
            raise CountError(
                f"dtbo.img contains {dtbo.count} DT table entries, expected {expected_dtbo}: "
                f"{rom.files[DTBO_IMAGE]}"
            )
        if base_table.count != expected_dtb:
            raise CountError(
                f"vendor_boot dtb section contains {base_table.count} base DTBs, expected {expected_dtb}: "
                f"{rom.files[VENDOR_BOOT_IMAGE]}"
            )

        # Every extracted payload must be a real FDT.
        dtbo_entries = []
        for entry in dtbo.entries:
            try:
                fdt_info(entry.data)
            except FormatError as error:
                raise FormatError(f"dtbo entry {entry.index}: {error}") from error
            dtbo_entries.append(
                {"index": entry.index, "name": _entry_name(entry.index),
                 "dt_size": entry.dt_size, "dt_offset": entry.dt_offset,
                 "id": entry.id, "rev": entry.rev, "sha256": sha256_bytes(entry.data),
                 "fdt": fdt_info(entry.data)}
            )
        dtb_entries = []
        for entry in base_table.entries:
            try:
                fdt_info(entry.data)
            except FormatError as error:
                raise FormatError(f"vendor_boot base dtb {entry.index}: {error}") from error
            dtb_entries.append(
                {"index": entry.index, "name": _dtb_name(entry.index),
                 "dt_size": entry.dt_size, "dt_offset": entry.dt_offset,
                 "sha256": sha256_bytes(entry.data), "fdt": fdt_info(entry.data)}
            )

        manifest = {
            "schema_version": SCHEMA_VERSION,
            "kind": "liuqin-stock-rom-inputs",
            "tool": {"name": TOOL_NAME, "version": TOOL_VERSION},
            "rom": {
                "source": {
                    "path": str(rom.source_path),
                    "type": rom.kind,
                    "name": rom.source_path.name,
                },
                "version": {
                    "known": known,
                    "name": rom_images.rom if known else None,
                    "package": rom_images.package if known else None,
                    "identity_table": str(rom_images.source_path),
                    "warning": None if known else "ROM images are not the pinned known version",
                },
                "files": rom_files,
            },
            "expected": {"dtbo_entries": expected_dtbo, "vendor_boot_base_dtbs": expected_dtb},
            "counts": {"dtbo_entries": dtbo.count, "vendor_boot_base_dtbs": base_table.count},
            "dtbo_table": dtbo.summary(),
            "vendor_boot": {**vendor.summary(), "dtb_table": base_table.summary()},
            "dtbo_entries": dtbo_entries,
            "vendor_boot_base_dtbs": dtb_entries,
            "outputs": {"layout": layout, "directories": {}},
            "verification": {
                "dtbo_count_ok": dtbo.count == expected_dtbo,
                "base_dtb_count_ok": base_table.count == expected_dtb,
                "all_payloads_are_fdt": True,
                "known_rom_version": known,
            },
            "warnings": warnings,
            "notes": notes,
        }

        if dry_run:
            manifest["outputs"]["dry_run"] = True
            log(f"dry-run: parsed {dtbo.count} DTBO entries and {base_table.count} base DTBs; nothing written")
            return manifest

        if out_dir.exists() and force:
            shutil.rmtree(out_dir)
        written: dict[str, dict] = {}

        def write_tree(dtbo_dir: Path, dtbs_dir: Path, dtb02_dir: Path, tag: str) -> dict:
            tree = {"dtbo_dir": str(dtbo_dir), "dtbs_dir": str(dtbs_dir)}
            for entry in dtbo.entries:
                written[f"{tag}/{_entry_name(entry.index)}"] = _write_payload(
                    dtbo_dir / _entry_name(entry.index), entry.data, out_dir
                )
            for entry in base_table.entries:
                written[f"{tag}/{_dtb_name(entry.index)}"] = _write_payload(
                    dtbs_dir / _dtb_name(entry.index), entry.data, out_dir
                )
            if write_dtb02:
                dtb02 = base_table.entries[DTB02_INDEX]
                written[f"{tag}/dtb-02.dtb"] = _write_payload(
                    dtb02_dir / "dtb-02.dtb", dtb02.data, out_dir
                )
                tree["dtb02"] = str(dtb02_dir / "dtb-02.dtb")
            return tree

        manifest["outputs"]["directories"]["analysis"] = write_tree(
            layout_map["dtbo"], layout_map["dtbs"], layout_map["dtb02"], "analysis"
        )
        if layout == "both":
            manifest["outputs"]["directories"]["flat"] = write_tree(
                layout_map["dtbo_flat"], layout_map["dtbs_flat"], layout_map["dtb02_flat"], "flat"
            )
        manifest["outputs"]["files"] = written
        manifest["outputs"]["manifest"] = str(out_dir / "manifest.json")
        (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        log(
            f"extracted {dtbo.count} DTBO entries and {base_table.count} base DTBs "
            f"to {out_dir} (layout={layout})"
        )
        return manifest


# ---------------------------------------------------------------------------
# Manifest verification
# ---------------------------------------------------------------------------


def verify_manifest(manifest_path: Path, *, expected_dtbo: int = DEFAULT_EXPECTED_DTBO_ENTRIES,
                    expected_dtb: int = DEFAULT_EXPECTED_VENDOR_DTBS) -> dict:
    """Re-verify an extraction manifest and the files it describes."""
    manifest_path = Path(manifest_path)
    if not manifest_path.is_file():
        raise ManifestError(f"manifest not found: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text())
    except json.JSONDecodeError as error:
        raise ManifestError(f"cannot parse manifest {manifest_path}: {error}") from error
    if manifest.get("kind") != "liuqin-stock-rom-inputs":
        raise ManifestError(f"{manifest_path} is not a {TOOL_NAME} manifest")
    out_dir = manifest_path.parent
    problems: list[str] = []
    checks: list[dict] = []

    def check(check_id: str, ok: bool, detail: str = "") -> None:
        checks.append({"id": check_id, "ok": bool(ok), "detail": detail})
        if not ok:
            problems.append(f"{check_id}: {detail}")

    counts = manifest.get("counts", {})
    check("counts.dtbo_entries", counts.get("dtbo_entries") == expected_dtbo,
          f"manifest has {counts.get('dtbo_entries')} (expected {expected_dtbo})")
    check("counts.vendor_boot_base_dtbs", counts.get("vendor_boot_base_dtbs") == expected_dtb,
          f"manifest has {counts.get('vendor_boot_base_dtbs')} (expected {expected_dtb})")

    dtbo_entries = manifest.get("dtbo_entries", [])
    dtb_entries = manifest.get("vendor_boot_base_dtbs", [])
    check("manifest.dtbo_list_length", len(dtbo_entries) == counts.get("dtbo_entries"),
          f"{len(dtbo_entries)} entries listed")
    check("manifest.dtb_list_length", len(dtb_entries) == counts.get("vendor_boot_base_dtbs"),
          f"{len(dtb_entries)} entries listed")

    files = manifest.get("outputs", {}).get("files", {})
    if not files:
        check("outputs.files_present", False, "manifest has no output file hashes")
    out_root = out_dir.resolve()
    for relative, record in sorted(files.items()):
        recorded = record.get("path") if isinstance(record, dict) else None
        if recorded:
            path = (out_dir / recorded).resolve()
        else:  # older manifests: fall back to a unique basename search
            key = relative.split("/", 1)[-1]
            candidates = list(out_dir.rglob(Path(key).name))
            path = candidates[0].resolve() if candidates else None
        if path is None or not path.is_file():
            check(f"file.{relative}", False, "missing from output directory")
            continue
        try:
            path.relative_to(out_root)
        except ValueError:
            check(f"file.{relative}", False, f"recorded path escapes the output directory: {path}")
            continue
        data = path.read_bytes()
        ok = len(data) == record.get("bytes") and sha256_bytes(data) == record.get("sha256")
        check(f"file.{relative}", ok, f"{path} bytes={len(data)} sha256={sha256_bytes(data)[:16]}…")
    # Layout directories recorded in the manifest must still exist.
    for layout_name, tree in manifest.get("outputs", {}).get("directories", {}).items():
        for label in ("dtbo_dir", "dtbs_dir"):
            directory = Path(tree.get(label, ""))
            check(f"dir.{layout_name}.{label}", directory.is_dir(), str(directory))
    return {
        "manifest": str(manifest_path),
        "out_dir": str(out_dir),
        "ok": not problems,
        "checks": checks,
        "problems": problems,
        "counts": counts,
        "known_rom_version": manifest.get("rom", {}).get("version", {}).get("known"),
        "warnings": manifest.get("warnings", []),
    }


# ---------------------------------------------------------------------------
# Small CLI helpers shared by the entry point and tests
# ---------------------------------------------------------------------------


def parse_size(value: str) -> int:
    try:
        number = int(value, 0)
    except ValueError as error:
        raise UsageError(f"invalid integer: {value}") from error
    if number <= 0:
        raise UsageError(f"expected a positive integer: {value}")
    return number
