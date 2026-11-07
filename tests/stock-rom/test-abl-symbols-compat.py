#!/usr/bin/env python3
"""Regress dtc label restoration without needing private stock ROM inputs."""
import importlib.util
import gzip
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = ROOT / "upstream/xiaomipad-6pro-mainline/tools/lib/abl-symbols.py"
PATCH = ROOT / "overlays/boot/abl-symbols-dtc-labels.patch"


@unittest.skipUnless(UPSTREAM.is_file() and shutil.which("dtc") and shutil.which("patch"),
                     "requires pinned upstream clone, dtc and patch")
class LabelCompatibility(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.work = Path(cls.tmp.name)
        target = cls.work / "tools/lib/abl-symbols.py"
        target.parent.mkdir(parents=True)
        shutil.copyfile(UPSTREAM, target)
        subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-d", str(cls.work)],
                       input=PATCH.read_text(), text=True, capture_output=True, check=True)
        spec = importlib.util.spec_from_file_location("abl_symbols_compat", target)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_real_dtc_symbol_roundtrip(self):
        source = self.work / "fixture.dts"
        dtb = self.work / "fixture.dtb"
        source.write_text('/dts-v1/; / { first: second: liuqin-abl-overlay-sink '
                          '{ phandle = <1>; }; };\n')
        subprocess.run(["dtc", "-q", "-@", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(source)],
                       capture_output=True, check=True)
        decoded = self.module.decode(shutil.which("dtc"), dtb)
        body = self.module.extract_block(decoded, "liuqin-abl-overlay-sink")
        self.assertIsNotNone(body)
        self.assertIn("phandle = <0x01>;", body)
        self.assertIn('first = "/liuqin-abl-overlay-sink";',
                      self.module.extract_block(decoded, "__symbols__"))

    def test_labeled_and_unlabeled_nested_body(self):
        for prefix in ("", "label: ", "first: second: "):
            with self.subTest(prefix=prefix):
                text = f"\t{prefix}sink {{\n\t child {{ value = <1>; }};\n\t}};\n"
                self.assertIn("child", self.module.extract_block(text, "sink"))

    def test_missing_or_different_node_rejected(self):
        for text in ("a: other {\n};\n", "a: sink-extra {\n};\n", "a: sink;\n"):
            with self.subTest(text=text):
                self.assertIsNone(self.module.extract_block(text, "sink"))

    def test_1781_label_prefix(self):
        labels = " ".join(f"label_{n}:" for n in range(1781))
        text = f"\t{labels} sink {{\n\t\tphandle = <0x16d>;\n\t}};\n"
        self.assertEqual(self.module.extract_block(text, "sink").strip(), "phandle = <0x16d>;")


PUBLISHED = ROOT / "cache/upstream-v0.6.0/boot.img"
UNPACK = ROOT / "cache/upstream-v0.6.0/mkbootimg/unpack_bootimg.py"


@unittest.skipUnless(PUBLISHED.is_file() and UNPACK.is_file() and
                     all(shutil.which(x) for x in ("dtc", "fdtget", "fdtput", "cpio")),
                     "requires cached published boot image and DT tools")
class InterconnectGuard(unittest.TestCase):
    def test_old_substitute_cannot_discard_board_changes(self):
        for prop in ("interconnects", "interconnect-names"):
            with self.subTest(property=prop), tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp)
                dist = work / "kernel/dist"
                dist.mkdir(parents=True)
                unpacked = work / "unpacked"
                subprocess.run(["python3", str(UNPACK), "--boot_img", str(PUBLISHED),
                                "--out", str(unpacked)], capture_output=True, check=True)
                raw = dist / "sm8475-xiaomi-liuqin.dtb"
                shutil.copyfile(unpacked / "dtb", raw)
                node = "/soc@0/display-subsystem@ae00000"
                if prop == "interconnects":
                    cells = subprocess.check_output(["fdtget", "-t", "x", str(raw), node, prop],
                                                    text=True).split()
                    cells[1], cells[4], cells[7], cells[10] = "3", "1", "3", "1"
                    subprocess.run(["fdtput", "-t", "x", str(raw), node, prop, *cells], check=True)
                else:
                    subprocess.run(["fdtput", "-t", "s", str(raw), node, prop, "wrong-path"], check=True)
                # Only an ARM64 header is needed: refusal must happen before
                # accepting or parsing the deliberately incomplete ramdisk.
                image = bytearray(128)
                image[56:60] = b"ARMd"
                (dist / "Image").write_bytes(image)
                ramdisk = work / "fixture.cpio.gz"
                ramdisk.write_bytes(gzip.compress(b"incomplete fixture"))
                result = subprocess.run([str(ROOT / "scripts/build-bootimg.sh"),
                                         "--kernel-out", str(dist.parent), "--ramdisk", str(ramdisk),
                                         "--ramdisk-mode", "persistent", "--dtb-source", "upstream-artifact",
                                         "--strict-kernel", "--out", str(work / "boot")],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"final DTB drops the kernel board MDSS {prop};", result.stderr)
                self.assertFalse((work / "boot/boot-liuqin-dev.img").exists())


if __name__ == "__main__":
    unittest.main()
