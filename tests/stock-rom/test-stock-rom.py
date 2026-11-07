#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for tools/extract-stock-rom-inputs.py and tools/lib/stock-rom.py.

What is tested with which evidence:

  * dt_table / vendor_boot / boot-v2 parsers against *synthetic images built in
    this file with explicit struct layouts* (independent from the library's
    writer code), plus cross-validation against AOSP mkbootimg.py /
    unpack_bootimg.py from cache/upstream-v0.6.0/mkbootimg when present;
  * the published v0.6.0 boot.img (a real artifact) is reverse-parsed and its
    DTB sha256 must equal 885faaab7dad9de85a2f4fd89307ed57459e4893d8d83477cfdc918950aa8619;
  * the extractor CLI: directory and archive inputs, both output layouts,
    manifest + --verify-manifest, tamper detection, fail-closed 44/14 counts,
    unknown-version warning, build-bootimg directory-regex compatibility.

What can only be tested with a real Xiaomi Pad 6 Pro Fastboot ROM (marked
@requires_real_rom and skipped here): the actual 44 DTBO payloads, the actual
14 vendor_boot base DTBs, the 1781-symbol ABL union end-to-end, and byte
equality of the rebuilt final DTB with the published one (885faaab…).

Run: python3 tests/stock-rom/test-stock-rom.py
"""
from __future__ import annotations

import importlib.util
import json
import re
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
LIB_PATH = PROJECT / "tools/lib/stock-rom.py"
CLI = PROJECT / "tools/extract-stock-rom-inputs.py"
MKBOOTIMG_DIR = PROJECT / "cache/upstream-v0.6.0/mkbootimg"
PUBLISHED_BOOTIMG = PROJECT / "cache/upstream-v0.6.0/boot.img"
PUBLISHED_DTB_SHA256 = "885faaab7dad9de85a2f4fd89307ed57459e4893d8d83477cfdc918950aa8619"
ROM_IMAGES_JSON = (
    PROJECT / "upstream/xiaomipad-6pro-mainline/tools/lib/liuqin-rom-images.json"
)

DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_MAGIC = 0xD00DFEED
VENDOR_BOOT_MAGIC = b"VNDRBOOT"
BOOT_MAGIC = b"ANDROID!"
PAGE = 4096


def load_library():
    spec = importlib.util.spec_from_file_location("liuqin_stock_rom_test", LIB_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses/Python 3.13+ need the module registered
    spec.loader.exec_module(module)
    return module


sr = load_library()


# ---------------------------------------------------------------------------
# Synthetic fixtures (explicit byte layout, deliberately not using the lib writer)
# ---------------------------------------------------------------------------


def make_fdt(node_name: bytes = b"", compatible: bytes = b"test") -> bytes:
    """Build a minimal but structurally valid FDT (version 17).

    Property values are padded to 4-byte alignment as the FDT specification
    requires; dtc rejects unpadded values as invalid structure opcodes.
    """
    strings = b"compatible\x00"
    name = node_name + b"\x00"
    name += b"\x00" * ((4 - len(name) % 4) % 4)
    value = compatible + b"\x00"
    value += b"\x00" * ((4 - len(value) % 4) % 4)
    struct_block = (
        struct.pack(">I", 1)  # FDT_BEGIN_NODE
        + name
        + struct.pack(">I", 3)  # FDT_PROP
        + struct.pack(">I", len(compatible) + 1)
        + struct.pack(">I", 0)  # name offset in strings
        + value
        + struct.pack(">I", 2)  # FDT_END_NODE
        + struct.pack(">I", 9)  # FDT_END
    )
    rsvmap = b"\x00" * 16
    off_struct = 40 + len(rsvmap)
    off_strings = off_struct + len(struct_block)
    totalsize = off_strings + len(strings)
    header = struct.pack(
        ">10I", FDT_MAGIC, totalsize, off_struct, off_strings, 40, 17, 16, 0,
        len(strings), len(struct_block),
    )
    return header + rsvmap + struct_block + strings


def make_dt_table(payloads: list[bytes], *, pad_to: int | None = None,
                  page_size: int = 2048, version: int = 0) -> bytes:
    """Build an Android DT table image (DTBO image format), explicit bytes."""
    header_size = 32
    entry_size = 32
    entries_offset = header_size
    cursor = entries_offset + entry_size * len(payloads)
    entries = []
    blobs = []
    for index, payload in enumerate(payloads):
        entries.append(struct.pack("<8I", len(payload), cursor, index, 0, 0, 0, 0, 0))
        blobs.append(payload)
        cursor += len(payload)
    total_size = cursor
    body = b"".join(entries) + b"".join(blobs)
    header = struct.pack(
        "<8I", DT_TABLE_MAGIC, total_size, header_size, entry_size,
        len(payloads), entries_offset, page_size, version,
    )
    image = header + body
    if pad_to is not None:
        assert pad_to >= len(image)
        image += b"\x00" * (pad_to - len(image))
    return image


def make_vendor_boot_v3(dtb_section: bytes, *, vendor_ramdisk: bytes = b"",
                        page_size: int = PAGE) -> bytes:
    header_size = 2112
    header = struct.pack(
        "<8sIIIII2048sI16sIIQ",
        VENDOR_BOOT_MAGIC, 3, page_size, 0x80000000, 0x10000000,
        len(vendor_ramdisk), b"\x00", 0x100, b"liuqin\x00", header_size,
        len(dtb_section), 0x20000000,
    )
    padded_header = header + b"\x00" * (page_size - header_size)
    ramdisk_block = vendor_ramdisk + b"\x00" * (
        (-len(vendor_ramdisk)) % page_size
    )
    dtb_block = dtb_section + b"\x00" * ((-len(dtb_section)) % page_size)
    return padded_header + ramdisk_block + dtb_block


def make_vendor_boot_v4(dtb_section: bytes, *, vendor_ramdisk: bytes = b"",
                        page_size: int = PAGE) -> bytes:
    header_size = 2128
    header = struct.pack(
        "<8sIIIII2048sI16sIIQ",
        VENDOR_BOOT_MAGIC, 4, page_size, 0x80000000, 0x10000000,
        len(vendor_ramdisk), b"\x00", 0x100, b"liuqin\x00", header_size,
        len(dtb_section), 0x20000000,
    ) + struct.pack("<4I", 0, 0, 0, 0)
    padded_header = header + b"\x00" * (page_size - header_size)
    ramdisk_block = vendor_ramdisk + b"\x00" * (
        (-len(vendor_ramdisk)) % page_size
    )
    dtb_block = dtb_section + b"\x00" * ((-len(dtb_section)) % page_size)
    return padded_header + ramdisk_block + dtb_block


def make_boot_v2(kernel: bytes, ramdisk: bytes, dtb: bytes,
                 *, page_size: int = PAGE) -> bytes:
    header_size = 1660
    header = bytearray(header_size)
    header[0:8] = BOOT_MAGIC
    fields = {
        8: len(kernel), 12: 0x8000, 16: len(ramdisk), 20: 0x1000000,
        24: 0, 28: 0, 32: 0x100, 36: page_size, 40: 2, 44: 0,
        1632: 0, 1644: header_size, 1648: len(dtb),
    }
    for offset, value in fields.items():
        struct.pack_into("<I", header, offset, value)
    struct.pack_into("<Q", header, 1636, 0)  # recovery_dtbo_offset
    struct.pack_into("<Q", header, 1652, 0x1F00000)  # dtb_addr
    header[48:64] = b"liuqin\x00l\x00\x00\x00\x00\x00\x00\x00\x00\x00"[0:16]
    header[64:64 + len(b"console=tty0")] = b"console=tty0"

    def pad(blob: bytes) -> bytes:
        return blob + b"\x00" * ((-len(blob)) % page_size)

    header_page = bytes(header) + b"\x00" * (page_size - header_size)
    return header_page + pad(kernel) + pad(ramdisk) + pad(dtb)


def make_rom_tree(root: Path, *, dtbo_count: int = 44, dtb_count: int = 14,
                  dtbo_pad_to: int = 24 * 1024 * 1024) -> dict:
    images = root / "images"
    images.mkdir(parents=True)
    dts = [make_fdt(b"", f"entry{index}".encode()) for index in range(dtbo_count)]
    base = [make_fdt(b"", f"base{index}".encode()) for index in range(dtb_count)]
    dtbo_img = make_dt_table(dts, pad_to=dtbo_pad_to)
    dtb_table = make_dt_table(base, page_size=2048)
    vendor_boot = make_vendor_boot_v4(dtb_table)
    boot = make_boot_v2(b"K" * 1024, b"R" * 512, make_fdt())
    (images / "dtbo.img").write_bytes(dtbo_img)
    (images / "vendor_boot.img").write_bytes(vendor_boot)
    (images / "boot.img").write_bytes(boot)
    return {
        "dtbo": dtbo_img, "vendor_boot": vendor_boot, "boot": boot,
        "dtbo_payloads": dts, "base_payloads": base, "images": images,
    }


def run_cli(*args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CLI), *map(str, args)],
        text=True, capture_output=True, timeout=timeout,
        cwd=str(PROJECT),
    )


# ---------------------------------------------------------------------------
# Library-level format tests
# ---------------------------------------------------------------------------


class FormatTests(unittest.TestCase):
    def test_fdt_fixture_is_valid(self):
        info = sr.fdt_info(make_fdt())
        self.assertEqual(info["totalsize"], info["bytes"])

    def test_dt_table_roundtrip_44_entries(self):
        payloads = [make_fdt(b"", f"entry{index}".encode()) for index in range(44)]
        image = make_dt_table(payloads, pad_to=24 * 1024 * 1024)
        table = sr.parse_dt_table(image, source="synthetic dtbo.img")
        self.assertEqual(table.count, 44)
        self.assertEqual(table.trailing_bytes, 24 * 1024 * 1024 - table.total_size)
        self.assertGreater(table.trailing_bytes, 0)  # partition padding ignored
        self.assertEqual(table.version, 0)
        for index, entry in enumerate(table.entries):
            self.assertEqual(entry.data, payloads[index])
            self.assertEqual(entry.dt_size, len(payloads[index]))
        self.assertIn("magic", table.summary())

    def test_dt_table_rejects_bad_inputs(self):
        good = make_dt_table([make_fdt()])
        bad_magic = bytearray(good)
        struct.pack_into("<I", bad_magic, 0, 0x12345678)
        with self.assertRaises(sr.FormatError):
            sr.parse_dt_table(bytes(bad_magic))
        with self.assertRaises(sr.FormatError):
            sr.parse_dt_table(good[:16])
        overlapping = bytearray(good)
        struct.pack_into("<I", overlapping, 20, 0)  # dt_entries_offset inside header
        with self.assertRaises(sr.FormatError):
            sr.parse_dt_table(bytes(overlapping))
        no_entries = bytearray(good)
        struct.pack_into("<I", no_entries, 16, 0)  # dt_entry_count = 0
        with self.assertRaises(sr.FormatError):
            sr.parse_dt_table(bytes(no_entries))

    def test_vendor_boot_v3_and_v4(self):
        base = [make_fdt(b"", f"base{index}".encode()) for index in range(14)]
        table = make_dt_table(base, page_size=2048)
        for builder, version in ((make_vendor_boot_v3, 3), (make_vendor_boot_v4, 4)):
            image = builder(table, vendor_ramdisk=b"R" * 100)
            parsed = sr.parse_vendor_boot(image, source=f"vendor_boot v{version}")
            self.assertEqual(parsed.header_version, version)
            self.assertEqual(parsed.dtb_size, len(table))
            self.assertEqual(parsed.dtb_offset % PAGE, 0)
            self.assertEqual(parsed.dtb_bytes, table)
            self.assertEqual(parsed.file_bytes, len(image))
            parsed_table = sr.parse_dt_table(parsed.dtb_bytes)
            self.assertEqual(parsed_table.count, 14)
            for index, entry in enumerate(parsed_table.entries):
                self.assertEqual(entry.data, base[index])

    def test_vendor_boot_rejects_bad_magic_and_version(self):
        image = bytearray(make_vendor_boot_v4(make_dt_table([make_fdt()])))
        image[0:8] = b"BADMAGIC"
        with self.assertRaises(sr.FormatError):
            sr.parse_vendor_boot(bytes(image))
        image = bytearray(make_vendor_boot_v4(make_dt_table([make_fdt()])))
        struct.pack_into("<I", image, 8, 9)
        with self.assertRaises(sr.FormatError):
            sr.parse_vendor_boot(bytes(image))

    def test_boot_v2_roundtrip(self):
        kernel, ramdisk, dtb = b"K" * 4097, b"R" * 100, make_fdt()
        image = make_boot_v2(kernel, ramdisk, dtb)
        parsed = sr.parse_boot_image_v2(image, source="synthetic boot.img")
        self.assertEqual(parsed.header_version, 2)
        self.assertEqual(parsed.page_size, PAGE)
        self.assertEqual(parsed.kernel, kernel)
        self.assertEqual(parsed.ramdisk, ramdisk)
        self.assertEqual(parsed.dtb, dtb)
        self.assertTrue(parsed.page_padding_ok)
        with self.assertRaises(sr.FormatError):
            sr.parse_boot_image_v2(b"NOTANDROID" + image[10:])


# ---------------------------------------------------------------------------
# Extractor CLI tests
# ---------------------------------------------------------------------------


class ExtractorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="liuqin-stockrom-test-")
        self.root = Path(self.tmp.name)
        self.rom = self.root / "rom"
        self.fixture = make_rom_tree(self.rom)
        self.out = self.root / "out/stock-rom"
        self.out.parent.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_extract_directory_both_layouts(self):
        result = run_cli("--rom", self.rom, "--out", self.out, "--allow-outside", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertEqual(manifest["counts"]["dtbo_entries"], 44)
        self.assertEqual(manifest["counts"]["vendor_boot_base_dtbs"], 14)
        self.assertFalse(manifest["rom"]["version"]["known"])
        self.assertTrue(manifest["warnings"])
        analysis_dtbo = self.out / "analysis/dtbo"
        analysis_dtbs = self.out / "analysis/vendor_boot/dtbs"
        flat_dtbo = self.out / "dtbo"
        flat_dtbs = self.out / "vendor_boot/dtbs"
        self.assertEqual(len(list(analysis_dtbo.glob("entry.*"))), 44)
        self.assertEqual(len(list(analysis_dtbs.glob("dtb-*.dtb"))), 14)
        self.assertEqual(len(list(flat_dtbo.glob("entry.*"))), 44)
        self.assertEqual(len(list(flat_dtbs.glob("dtb-*.dtb"))), 14)
        self.assertEqual((analysis_dtbo / "entry.00").read_bytes(), self.fixture["dtbo_payloads"][0])
        self.assertEqual((analysis_dtbo / "entry.43").read_bytes(), self.fixture["dtbo_payloads"][43])
        self.assertEqual(
            (self.out / "analysis/vendor_boot/dtb-02.dtb").read_bytes(),
            self.fixture["base_payloads"][2],
        )
        self.assertTrue((self.out / "manifest.json").is_file())

    def test_output_layout_matches_bootimg_regexes(self):
        result = run_cli("--rom", self.rom, "--out", self.out, "--allow-outside")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Exact rules from upstream tools/lib/build-bootimg.sh.
        overlay = [p for p in (self.out / "analysis/dtbo").iterdir()
                   if p.is_file() and re.fullmatch(r".*/entry\.[0-9]+", str(p))]
        base = [p for p in (self.out / "analysis/vendor_boot/dtbs").iterdir()
                if p.is_file() and re.fullmatch(r".*/dtb-[0-9][0-9]\.dtb", str(p))]
        self.assertEqual(len(overlay), 44)
        self.assertEqual(len(base), 14)
        # The boot builder's --stock-rom-dir probe accepts these candidates.
        self.assertTrue((self.out / "analysis/dtbo").is_dir())
        self.assertTrue((self.out / "analysis/vendor_boot/dtbs").is_dir())
        self.assertTrue((self.out / "dtbo").is_dir())
        self.assertTrue((self.out / "vendor_boot/dtbs").is_dir())

    def test_verify_manifest_roundtrip_and_tamper(self):
        result = run_cli("--rom", self.rom, "--out", self.out, "--allow-outside")
        self.assertEqual(result.returncode, 0, result.stderr)
        verify = run_cli("--verify-manifest", "--out", self.out, "--allow-outside")
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertIn("PASS", verify.stdout)
        (self.out / "analysis/dtbo/entry.07").write_bytes(make_fdt(b"", b"tampered"))
        tampered = run_cli("--verify-manifest", "--out", self.out, "--allow-outside")
        self.assertEqual(tampered.returncode, 5)
        self.assertIn("FAIL", tampered.stdout)

    def test_fail_closed_counts(self):
        bad = self.root / "rom-43"
        make_rom_tree(bad, dtbo_count=43, dtb_count=14)
        out = self.root / "out-43"
        result = run_cli("--rom", bad, "--out", out, "--allow-outside")
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("FAIL-CLOSED", result.stderr)
        self.assertFalse(out.exists() and any(out.iterdir()))

        bad2 = self.root / "rom-13"
        make_rom_tree(bad2, dtbo_count=44, dtb_count=13)
        out2 = self.root / "out-13"
        result = run_cli("--rom", bad2, "--out", out2, "--allow-outside")
        self.assertEqual(result.returncode, 4, result.stderr)

    def test_bad_rom_format_exit_code(self):
        bad = self.root / "rom-bad"
        images = bad / "images"
        images.mkdir(parents=True)
        (images / "dtbo.img").write_bytes(b"not a dt table" * 100)
        (images / "vendor_boot.img").write_bytes(make_vendor_boot_v4(make_dt_table([make_fdt()])))
        result = run_cli("--rom", bad, "--out", self.root / "out-bad", "--allow-outside")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("ROM error", result.stderr)

    def test_archive_input_tgz(self):
        archive = self.root / "liuqin_images_test.tgz"
        with tarfile.open(archive, "w:gz") as handle:
            for path in sorted(self.fixture["images"].iterdir()):
                handle.add(path, arcname=f"liuqin_test/images/{path.name}")
        out = self.root / "out-tgz"
        result = run_cli("--rom", archive, "--out", out, "--allow-outside")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((out / "analysis/dtbo").glob("entry.*"))), 44)

    def test_archive_input_zip(self):
        archive = self.root / "liuqin_images_test.zip"
        with zipfile.ZipFile(archive, "w") as handle:
            for path in sorted(self.fixture["images"].iterdir()):
                handle.write(path, arcname=f"images/{path.name}")
        out = self.root / "out-zip"
        result = run_cli("--rom", archive, "--out", out, "--allow-outside")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((out / "analysis/vendor_boot/dtbs").glob("dtb-*.dtb"))), 14)

    def test_dry_run_writes_nothing(self):
        out = self.root / "out-dry"
        result = run_cli("--rom", self.rom, "--out", out, "--allow-outside", "--dry-run", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertTrue(manifest["outputs"]["dry_run"])
        self.assertFalse(out.exists())

    def test_inspect_synthetic_images(self):
        dtbo = self.root / "inspect-dtbo.img"
        dtbo.write_bytes(self.fixture["dtbo"])
        result = run_cli("--inspect", dtbo)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["type"], "dt_table")
        self.assertEqual(payload["table"]["entry_count"], 44)
        vendor = self.root / "inspect-vendor_boot.img"
        vendor.write_bytes(self.fixture["vendor_boot"])
        result = run_cli("--inspect", vendor)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["type"], "vendor_boot")
        self.assertEqual(payload["header"]["header_version"], 4)
        self.assertEqual(payload["dtb_table"]["entry_count"], 14)


# ---------------------------------------------------------------------------
# Cross-validation against real artifacts / AOSP tools
# ---------------------------------------------------------------------------


@unittest.skipUnless(MKBOOTIMG_DIR.is_dir(), "AOSP mkbootimg checkout is not available")
class AospCrossValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="liuqin-aosp-test-")
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_py(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, *map(str, args)], text=True, capture_output=True, timeout=300
        )

    def test_ours_to_aosp_vendor_boot(self):
        base = [make_fdt(b"", f"base{index}".encode()) for index in range(14)]
        table = make_dt_table(base, page_size=2048)
        image = make_vendor_boot_v4(table)
        vendor = self.root / "vendor_boot.img"
        vendor.write_bytes(image)
        out_dir = self.root / "unpacked"
        result = self.run_py(MKBOOTIMG_DIR / "unpack_bootimg.py",
                             "--boot_img", vendor, "--out", out_dir, "--format", "info")
        self.assertEqual(result.returncode, 0, result.stderr)
        extracted_dtb = (out_dir / "dtb").read_bytes()
        self.assertEqual(extracted_dtb, table)
        self.assertIn("dtb size:", result.stdout)
        parsed = sr.parse_vendor_boot(image)
        self.assertEqual(parsed.dtb_bytes, extracted_dtb)
        parsed_table = sr.parse_dt_table(parsed.dtb_bytes)
        self.assertEqual(parsed_table.count, 14)

    def test_aosp_vendor_boot_v3_to_ours(self):
        base = [make_fdt(b"", f"base{index}".encode()) for index in range(14)]
        table = make_dt_table(base, page_size=2048)
        dtb_file = self.root / "dtb.img"
        dtb_file.write_bytes(table)
        vendor_ramdisk = self.root / "vendor_ramdisk.bin"
        vendor_ramdisk.write_bytes(b"V" * 256)
        out = self.root / "aosp-vendor_boot.img"
        result = self.run_py(
            MKBOOTIMG_DIR / "mkbootimg.py",
            "--header_version", "3", "--pagesize", "4096",
            "--vendor_boot", out,
            "--vendor_ramdisk", vendor_ramdisk,
            "--dtb", dtb_file,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = sr.parse_vendor_boot(out.read_bytes(), source=str(out))
        self.assertEqual(parsed.header_version, 3)
        self.assertEqual(parsed.dtb_size, len(table))
        self.assertEqual(parsed.dtb_bytes, table)
        self.assertEqual(sr.parse_dt_table(parsed.dtb_bytes).count, 14)

    def test_aosp_boot_v2_to_ours(self):
        kernel = self.root / "kernel"
        kernel.write_bytes(b"K" * 4097)
        ramdisk = self.root / "ramdisk"
        ramdisk.write_bytes(b"R" * 513)
        dtb = self.root / "dtb"
        dtb.write_bytes(make_fdt())
        out = self.root / "boot.img"
        result = self.run_py(
            MKBOOTIMG_DIR / "mkbootimg.py",
            "--header_version", "2", "--pagesize", "4096",
            "--kernel", kernel, "--ramdisk", ramdisk, "--dtb", dtb,
            "--cmdline", "", "-o", out,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = sr.parse_boot_image_v2(out.read_bytes(), source=str(out))
        self.assertEqual(parsed.kernel, kernel.read_bytes())
        self.assertEqual(parsed.ramdisk, ramdisk.read_bytes())
        self.assertEqual(parsed.dtb, dtb.read_bytes())

    @unittest.skipUnless(PUBLISHED_BOOTIMG.is_file(), "published v0.6.0 boot.img is not cached")
    def test_published_boot_img_reverse_validation(self):
        out_dir = self.root / "unpacked-published"
        result = self.run_py(MKBOOTIMG_DIR / "unpack_bootimg.py",
                             "--boot_img", PUBLISHED_BOOTIMG,
                             "--out", out_dir, "--format", "info")
        self.assertEqual(result.returncode, 0, result.stderr)
        image = sr.parse_boot_image_v2(PUBLISHED_BOOTIMG.read_bytes(),
                                       source=str(PUBLISHED_BOOTIMG))
        self.assertEqual(image.page_size, 4096)
        self.assertEqual(image.header_version, 2)
        self.assertEqual(image.kernel, (out_dir / "kernel").read_bytes())
        self.assertEqual(image.ramdisk, (out_dir / "ramdisk").read_bytes())
        published_dtb = (out_dir / "dtb").read_bytes()
        self.assertEqual(image.dtb, published_dtb)
        self.assertEqual(sr.sha256_bytes(published_dtb), PUBLISHED_DTB_SHA256)
        self.assertEqual(sr.sha256_bytes(image.dtb), PUBLISHED_DTB_SHA256)
        info = sr.fdt_info(published_dtb)
        self.assertEqual(info["totalsize"], len(published_dtb))
        self.assertEqual(info["totalsize"], 224672)
        self.assertEqual(info["version"], 17)
        # The published DTB already carries the ABL sink and identity overlays;
        # parsing it here is what proves the extractor's validator can consume a
        # real final DTB. The canonical *rebuild* comparison needs a real ROM.
        self.assertIn(b"liuqin-abl-overlay-sink", published_dtb)

    def test_inspect_published_boot_img_cli(self):
        result = run_cli("--inspect", PUBLISHED_BOOTIMG)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["type"], "boot_v2")
        self.assertEqual(payload["header"]["header_version"], 2)
        self.assertEqual(payload["dtb_sha256"], PUBLISHED_DTB_SHA256)
        self.assertEqual(payload["header"]["dtb_size"], 224672)


# ---------------------------------------------------------------------------
# Documented real-ROM-only checks
# ---------------------------------------------------------------------------


class RealRomOnlyTests(unittest.TestCase):
    @unittest.skip("requires the user's Xiaomi Pad 6 Pro Fastboot ROM (not redistributed)")
    def test_real_rom_44_14_and_final_dtb_equality(self):
        """The canonical end-to-end check on the real ROM.

        Steps once a real ROM is available:
          tools/extract-stock-rom-inputs.py --rom <ROM> --out out/stock-rom
          scripts/build-bootimg.sh --kernel-out out/kernel --ramdisk ... \
              --dtb-source stock-rom --stock-rom-dir out/stock-rom \
              --out out/boot-stock
        The final DTB must then be byte-identical to the published one
        (sha256 885faaab…) when the ROM is OS2.0.6.0.VMYCNXM and the kernel is
        the locked commit; otherwise the builder's VERIFICATION.md reports the
        differing identity/bootargs fields (the expected cause is a different
        ROM version).
        """


if __name__ == "__main__":
    unittest.main(verbosity=2)
