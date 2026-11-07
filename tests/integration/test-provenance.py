#!/usr/bin/env python3
"""Small offline regressions for TN0040; no RPM builds or devices required."""
import ast
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import zlib
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "firmware_provenance", PROJECT / "packaging/device/write-firmware-provenance.py")
FW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FW)


class FirmwareProvenance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "root"
        self.upstream = Path(self.temp.name) / "upstream"
        self.blob = self.root / "usr/lib/firmware/novatek/liuqin/panel.bin"
        self.blob.parent.mkdir(parents=True)
        self.blob.write_bytes(b"private fixture, not real firmware")
        self.name = "/" + str(self.blob.relative_to(self.root))
        self.manifest = self.upstream / "device/firmware/firmware.manifest"
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text(f"{FW.sha256(self.blob)}  {self.name}\n")
        source = self.upstream / "device/firmware" / self.name.lstrip("/")
        source.parent.mkdir(parents=True)
        source.write_bytes(self.blob.read_bytes())
        self.output = self.root / "usr/share/liuqin/firmware-provenance.json"

    def queries(self, args, **kwargs):
        if "-qa" in args:
            return "liuqin-firmware\tliuqin-firmware-0.6.0-1.aarch64\n"
        if "-ql" in args:
            return self.name + "\n"
        if args[0] == "git":
            return "f" * 40 + "\n"
        self.fail(str(args))

    def test_actual_bytes_and_private_restriction(self):
        with patch.object(FW.subprocess, "check_output", side_effect=self.queries):
            FW.main(self.root, self.upstream)
        data = json.loads(self.output.read_text())
        self.assertFalse(data["redistributable"])
        self.assertEqual(data["files"][0]["sha256"], FW.sha256(self.blob))
        self.assertEqual(data["source"]["manifest_sha256"], FW.sha256(self.manifest))
        self.assertNotIn("private fixture", self.output.read_text())

    def test_changed_blob_is_rejected(self):
        self.blob.write_bytes(b"changed")
        with patch.object(FW.subprocess, "check_output", side_effect=self.queries):
            with self.assertRaisesRegex(ValueError, "does not match"):
                FW.main(self.root, self.upstream)
        self.assertFalse(self.output.exists())

    def test_rpm_query_failure_is_not_absence(self):
        with patch.object(FW.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "rpm")):
            with self.assertRaises(subprocess.CalledProcessError):
                FW.main(self.root, self.upstream)

    def test_generic_tree_drops_stale_marker(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_text("stale")
        with patch.object(FW.subprocess, "check_output", return_value="bash\tbash-1.aarch64\n"):
            FW.main(self.root, self.upstream)
        self.assertFalse(self.output.exists())

    def test_ath11k_relocation_and_symlink_record(self):
        name = "/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0/amss.bin"
        blob = self.root / name.lstrip("/")
        blob.parent.mkdir(parents=True)
        blob.write_bytes(b"ath11k")
        link = blob.with_name("alias.bin")
        link.symlink_to("amss.bin")
        source_root = self.upstream / "device/firmware"
        source = source_root / name.replace("updates/", "").lstrip("/")
        source.parent.mkdir(parents=True)
        source.write_bytes(blob.read_bytes())
        source.with_name("alias.bin").symlink_to("amss.bin")
        expected = {name.replace("updates/", ""): FW.sha256(blob)}
        paths = [name, name.replace("amss", "alias")]
        records = FW.records_for(self.root, paths, expected, source_root)
        self.assertEqual(records[0]["symlink_target"], "amss.bin")
        self.assertEqual(records[1]["source_path"], name.replace("updates/", ""))
        # A regular source replaced by a link must fail, even if its bytes match.
        blob.unlink()
        blob.symlink_to("missing.bin")
        with self.assertRaisesRegex(ValueError, "symlink does not match"):
            FW.records_for(self.root, [name], expected, source_root)

    def test_source_symlink_replaced_by_regular_file_is_rejected(self):
        source_root = self.upstream / "device/firmware"
        source = source_root / self.name.lstrip("/")
        source.with_name("alias.bin").symlink_to("panel.bin")
        alias = self.blob.with_name("alias.bin")
        alias.write_bytes(self.blob.read_bytes())
        with self.assertRaisesRegex(ValueError, "replaced by a regular file"):
            FW.records_for(self.root, [self.name.replace("panel", "alias")],
                           {self.name: FW.sha256(self.blob)}, source_root)

    def test_exact_updates_pin_wins_over_relocation(self):
        source_root = self.upstream / "device/firmware"
        name = "/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0/amss.bin"
        exact = source_root / name.lstrip("/")
        exact.parent.mkdir(parents=True)
        exact.write_bytes(b"separately pinned updates payload")
        fallback = source_root / name.replace("updates/", "").lstrip("/")
        fallback.parent.mkdir(parents=True)
        fallback.write_bytes(b"different main-tree payload")
        actual = self.root / name.lstrip("/")
        actual.parent.mkdir(parents=True)
        actual.write_bytes(exact.read_bytes())
        expected = {name: FW.sha256(exact), name.replace("updates/", ""): FW.sha256(fallback)}
        records = FW.records_for(self.root, [name], expected, source_root)
        self.assertEqual(records[0]["source_path"], name)

    def test_pinned_file_replaced_by_directory_is_rejected(self):
        self.blob.unlink()
        self.blob.mkdir()
        with self.assertRaisesRegex(ValueError, "replaced by a directory"):
            FW.records_for(self.root, [self.name], {self.name: "not used"},
                           self.upstream / "device/firmware")

    def test_unmapped_extra_blob_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not mapped"):
            FW.records_for(self.root, [self.name.replace("panel", "unknown")], {},
                           self.upstream / "device/firmware")


class ExistingFirmwareRPM(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("LIUQIN_EXISTING_FIRMWARE_RPM_ROOT"),
                         "set LIUQIN_EXISTING_FIRMWARE_RPM_ROOT to an existing RPM extraction")
    def test_real_extracted_payload_and_upstream_pins(self):
        root = Path(os.environ["LIUQIN_EXISTING_FIRMWARE_RPM_ROOT"]).resolve()
        source_root = PROJECT / "upstream/xiaomipad-6pro-mainline/device/firmware"
        expected = dict((name, digest) for digest, name in
                        (line.split(None, 1) for line in (source_root / "firmware.manifest").read_text().splitlines()))
        paths = ["/" + str(path.relative_to(root)) for path in (root / "usr/lib/firmware").rglob("*")]
        records = FW.records_for(root, paths, expected, source_root)
        self.assertEqual(len(records), 198)  # 194 regular files + 4 source links
        self.assertEqual(sum("symlink_target" in row for row in records), 4)
        updates = [row for row in records if "/updates/ath11k/" in row["path"] and
                   row["path"].endswith(".bin") and not row["path"].endswith("board.bin")]
        self.assertEqual(len(updates), 8)
        self.assertTrue(all(row["source_path"] == row["path"] for row in updates))
        print(f"existing RPM payload: {len(records)} verified records, 8 exact updates pins")


class KernelSnapshot(unittest.TestCase):
    def test_verifier_rejects_config_drift_even_when_metadata_or_snapshot_agree(self):
        source = (PROJECT / "scripts/verify-bundle.sh").read_text()
        checker = source.split("def verify_kernel_config(", 1)[1].split("\ndef load_metadata", 1)[0]
        checker = "def verify_kernel_config(" + checker
        results = []
        scope = {"gzip": gzip, "hashlib": hashlib, "zlib": zlib,
                 "sha256": lambda p: hashlib.sha256(p.read_bytes()).hexdigest(),
                 "add": lambda cid, category, status, detail, **kw: results.append((cid, status))}
        exec(compile(checker, "verify-kernel-config", "exec"), scope)
        verify = scope["verify_kernel_config"]
        actual = b"CONFIG_SECURITY_SELINUX=y\n"
        stale = b"CONFIG_SECURITY_APPARMOR=y\n"
        kernel = gzip.compress(b"ARM64 fixture" + b"IKCFG_ST" + gzip.compress(actual) + b"IKCFG_ED")
        with tempfile.TemporaryDirectory() as temp:
            meta = Path(temp) / "boot-build-info.json"
            config = meta.with_name("kernel.config")
            for snapshot, recorded, expected in [
                (actual, actual, ["PASS", "PASS"]),
                (stale, actual, ["FAIL", "PASS"]),  # TN0047: stale bundled snapshot
                (stale, stale, ["PASS", "FAIL"]),  # matching sidecars cannot hide a wrong kernel
                (None, actual, ["FAIL", "PASS"]),
            ]:
                results.clear()
                if snapshot is not None:
                    config.write_bytes(snapshot)
                elif config.exists():
                    config.unlink()
                verify(kernel, {"config_sha256": hashlib.sha256(recorded).hexdigest(),
                                "config_snapshot": "kernel.config"}, meta)
                self.assertEqual([status for _, status in results], expected)
            config.write_bytes(actual)
            for invalid in (b"missing embedded config", b"IKCFG_STbrokenIKCFG_ED"):
                results.clear()
                verify(invalid, {"config_sha256": hashlib.sha256(actual).hexdigest(),
                                 "config_snapshot": "kernel.config"}, meta)
                self.assertEqual(results[-1][1], "FAIL")

    def test_kernel_rpm_config_is_carried_to_boot_input(self):
        source = (PROJECT / "scripts/build-image.sh").read_text()
        function = re.search(r"^extract_kernel_from_stage\(\) \{\n.*?^\}", source, re.M | re.S).group(0)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            mod = root / "usr/lib/modules/test"
            mod.mkdir(parents=True)
            (mod / "vmlinuz").write_bytes(b"kernel fixture")
            (mod / "sm8475-xiaomi-liuqin.dtb").write_bytes(b"dtb")
            config = root / "usr/share/liuqin/kernel-config"
            config.parent.mkdir(parents=True)
            config.write_text("CONFIG_SECURITY_SELINUX=y\n")
            script = '''set -eu
rootfs_stage=$1
work=$2
kernel_rpms_dir=fixture
installed_kernel_release() { echo test; }
die() { echo "$*" >&2; exit 1; }
''' + function + '\nextract_kernel_from_stage\n'
            work = Path(temp) / "work"
            subprocess.run(["sh", "-c", script, "sh", str(root), str(work)], check=True)
            self.assertEqual((work / "kernel-out/.config").read_bytes(), config.read_bytes())
            config.unlink()
            result = subprocess.run(["sh", "-c", script, "sh", str(root), str(work)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"missing its kernel-config", result.stderr)


class BundleMetadata(unittest.TestCase):
    def test_real_producer_keeps_field_alignment_without_vm_arguments(self):
        source = (PROJECT / "scripts/build-image.sh").read_text()
        function = source[source.index("write_bundle_json() {"):source.index("write_bundle_sha256sums() {")]
        with tempfile.TemporaryDirectory(prefix="metadata with spaces ") as temp:
            root = Path(temp)
            bundle, work = root / "bundle", root / "work"
            (bundle / "manifests").mkdir(parents=True)
            work.mkdir()
            (bundle / "boot.img").write_bytes(b"payload")
            (work / "boot.kernel-release").write_text("test-kernel\n")
            (work / "skips.txt").write_text("")
            script = '''set -eu
bundle_dir=$1
work=$2
project_root=$3
upstream=$3/upstream/xiaomipad-6pro-mainline
bundle_name=metadata-fixture
release=44
firmware_pool=retained-pool
device_rpm_count=1
audio_topology=retained-topology
dtb_source=stock-rom
build_mode=release
kernel_source=kernel-rpm
kernel_rpms_dir=kernel-rpms-sentinel
device_rpms_dirs=device-rpms-sentinel
rootfs_dir=rootfs-sentinel
rootfs_manifest_json=manifest-sentinel
installer_overlay=installer-sentinel
boot_img_source=boot-sentinel
boot_img_input=unused
skips_file=$work/skips.txt
has_skip() { return 1; }
''' + function + '\nwrite_bundle_json\n'
            result = subprocess.run(["sh", "-c", script, "sh", str(bundle), str(work), str(PROJECT)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads((bundle / "bundle.json").read_text())
            self.assertEqual(data["build_mode"], "release")
            self.assertEqual(data["dtb_source"], "stock-rom")
            self.assertEqual(data["sources"]["device_rpms"], "device-rpms-sentinel")
            self.assertIn("rootfs-sentinel", data["sources"]["rootfs"])
            self.assertEqual(data["kernel_release"], "test-kernel")
            self.assertIsNone(data["qemu_validation"])
            self.assertFalse(data["device_ready"])
            self.assertTrue(data["apply_boot_contract"]["requires_explicit_device_write_flag"])


class BootToolsConsistency(unittest.TestCase):
    def test_existing_gate_accepts_matching_payload_and_rejects_drift(self):
        source = (PROJECT / "scripts/build-boot-tools-rpm.sh").read_text()
        checker = re.search(r"if python3 .*?repo-consistency.txt.*?<<'PY'\n(.*?)^PY$",
                            source, re.M | re.S).group(1)
        pairs_node = next(node.value for node in ast.parse(checker).body
                          if isinstance(node, ast.Assign) and
                          any(isinstance(t, ast.Name) and t.id == "PAIRS" for t in node.targets))
        with tempfile.TemporaryDirectory() as temp:
            project, work, report = (Path(temp) / name for name in ("project", "work", "report"))
            boot = work / "roots/boot-tools"
            kernel = work / "roots/kernel"
            pairs = eval(compile(ast.Expression(pairs_node), "pairs", "eval"),
                         {"assets": boot / "usr/libexec/liuqin/boot-assets",
                          "boot_tools": boot, "kernel": kernel})
            for name, packaged in pairs:
                repo = project / name
                repo.parent.mkdir(parents=True, exist_ok=True)
                packaged.parent.mkdir(parents=True, exist_ok=True)
                repo.write_text(name)
                packaged.write_text(name)
            command = ["python3", "-c", checker, str(project), str(work), str(report)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("failures=0", report.read_text())
            pairs[0][1].write_text("stale packaged builder")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("failures=1", report.read_text())


if __name__ == "__main__":
    unittest.main()
