#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for the liuqin update/rollback chain.

Every test simulates the tablet with regular files (no loop device, no block
device, no tablet) under a temporary directory, and runs the REAL tools as
subprocesses with their documented test-only environment hooks.

The staging metadata consumed by liuqin-apply-boot is never hand-written: it is
produced by running the real producer commands (liuqin_boot_metadata.py `merge`
+ `stage`, the same code liuqin-bootimg-refresh and the kernel-install hook run).
Recorded real producer documents are kept in fixtures/.

Coverage:
  * schema v2 producer/consumer contract: merge -> stage -> apply dry-run,
    alias/nesting consistency, legacy v1 read-only migration, real samples;
  * status/stage/apply/rollback/recover/confirm, dry-run default, write gates,
    boot header validation, identity/kernel-pair gate, device checks,
    whole-partition write + read-back, backup/restore, simulated power loss,
    concurrent lock, legacy CLI;
  * continuous updates A->B->C without manual equalize or overrides;
  * boot+modules paired rollback (liuqin-kernel-pair archive/verify/restore),
    boot-only boundary, retention;
  * the full deliverable chain: install A -> update B -> pre-reboot state ->
    rollback A -> update C.

Run: python3 tests/boot-update/test-boot-update.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))

import fixture_artifacts as fx  # noqa: E402

PROJECT = fx.PROJECT
TOOL = fx.TOOL
METADATA = fx.METADATA
PAIR = fx.PAIR
KVER = fx.KVER
PARTITION_BYTES = fx.PARTITION_BYTES


class ChainTestCase(unittest.TestCase):
    """One simulated tablet with an installed release A."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="liuqin-update-chain-test-")
        self.root = Path(self.tmp.name)
        self.t = fx.make_tablet(self.root / "tablet")
        self.A = self.t.release("A")
        self.B = self.t.release("B")
        self.C = self.t.release("C")
        self.t.install(self.A)

    def tearDown(self):
        self.tmp.cleanup()

    # -- helpers --------------------------------------------------------------
    def staged(self) -> dict:
        staging = self.t.staging
        base = f"boot-{KVER}"
        return {"image": staging / f"{base}.img",
                "build_info": staging / f"{base}.build-info.json",
                "manifest": staging / f"{base}.manifest",
                "sums": staging / f"{base}.SHA256SUMS"}

    def stage(self, release):
        result = self.t.produce_staging(release)
        self.assertEqual(result["stage"].returncode, 0,
                         f"producer stage failed: {result['stage'].stdout}"
                         f"{result['stage'].stderr}")
        return result

    def mutate_build_info(self, mutate) -> dict:
        paths = self.staged()
        data = json.loads(paths["build_info"].read_text())
        mutate(data)
        paths["build_info"].write_text(json.dumps(data, indent=2) + "\n")
        return data

    def mutate_manifest(self, mutate) -> None:
        paths = self.staged()
        lines = paths["manifest"].read_text().splitlines()
        values = {}
        order = []
        for line in lines:
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                values[key] = value
                order.append(key)
        mutate(values)
        paths["manifest"].write_text(
            "# rewritten by the test\n"
            + "\n".join(f"{key}={values[key]}" for key in order if key in values) + "\n")

    def write_legacy_v1_metadata(self) -> None:
        """Reconstruct the legacy refresh output shape from the v2 document
        (documented legacy consumer path; never produced by the new tools)."""
        paths = self.staged()
        v2 = json.loads(paths["build_info"].read_text())
        legacy = {
            "generated_by": "liuqin-bootimg-refresh (legacy v1 shape, test only)",
            "device_ready": True,
            "kernel_release": v2["kernel_release"],
            "kernel_image_sha256": v2["kernel_image_sha256"],
            "dtb_sha256": v2["board_dtb_sha256"],
            "dtb_source": v2["dtb_source"],
            "ramdisk_sha256": v2["ramdisk_sha256"],
            "contract_sha256": v2["contract_sha256"],
            "contract_pins_kernel_identity": False,
            "bootimg_sha256": v2["artifact_sha256"],
            "bootimg_build_info": v2["builders"]["bootimg"],
            "initramfs_build_info": v2["builders"]["initramfs"],
        }
        paths["build_info"].write_text(json.dumps(legacy, indent=2) + "\n")
        manifest = {
            "kernel_release": legacy["kernel_release"],
            "kernel_image_sha256": legacy["kernel_image_sha256"],
            "dtb_source": legacy["dtb_source"],
            "dtb_sha256": legacy["dtb_sha256"],
            "bootimg_sha256": legacy["bootimg_sha256"],
            "device_ready": "true",
            "contract_sha256": legacy["contract_sha256"],
            "ramdisk_sha256": legacy["ramdisk_sha256"],
        }
        paths["manifest"].write_text(
            "\n".join(f"{key}={value}" for key, value in manifest.items()) + "\n")

    def pair_dir(self, pair_id: str) -> Path:
        return self.t.pair_store / "pairs" / pair_id

    def archived_tree_path(self, pair_id: str, absolute: str) -> Path:
        return self.pair_dir(pair_id) / "tree" / absolute.lstrip("/")

    def upgraded_staging(self, release) -> None:
        """Simulate `dnf upgrade kernel-liuqin` + kernel-install hook staging."""
        self.t.rpm_upgrade(release)
        self.stage(release)

    def assert_device_unchanged(self, release=None) -> None:
        release = release or self.A
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(release))

    def apply_write(self, release, *extra):
        result = self.t.apply(release, "--yes-write", *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result


# ---------------------------------------------------------------------------
# schema v2: single producer / single consumer
# ---------------------------------------------------------------------------


class SchemaV2Tests(ChainTestCase):
    def test_producer_output_passes_apply_dry_run(self):
        """Regression for the confirmed defect: the real producer output must be
        accepted by the consumer without hand-written JSON."""
        result = self.stage(self.A)
        build_info = json.loads(result["build_info"].read_text())
        self.assertEqual(build_info["schema"], "liuqin-boot-metadata")
        self.assertEqual(build_info["schema_version"], 2)
        self.assertEqual(build_info["artifact_sha256"], build_info["bootimg_sha256"])
        payload = build_info["payload"]
        self.assertEqual(payload["artifact"]["sha256"], build_info["bootimg_sha256"])
        self.assertEqual(payload["kernel"]["image_sha256"],
                         build_info["kernel_image_sha256"])
        self.assertEqual(payload["kernel"]["release"], build_info["kernel_release"])
        self.assertEqual(payload["dtb"]["source"], build_info["dtb_source"])
        self.assertEqual(payload["dtb"]["sha256"], build_info["dtb_sha256"])
        self.assertNotEqual(build_info["board_dtb_sha256"],
                            build_info["dtb_sha256"])
        dry = self.t.apply(self.A)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("DRY-RUN", dry.stdout)
        self.assertIn("identity gate: OK", dry.stdout)
        manifest = self.staged()["manifest"].read_text()
        self.assertIn("schema_version=2", manifest)
        self.assertIn("board_dtb_sha256=", manifest)
        self.assertIn("contract_pins_kernel_identity=false", manifest)
        self.assertTrue(self.staged()["sums"].is_file())

    def test_merge_rejects_boot_builder_hash_mismatch(self):
        release = self.t.release("E")
        data = release.build_builder_info()
        data["artifact_sha256"] = "0" * 64
        tampered = release.build_dir / "tampered-build-info.json"
        tampered.write_text(json.dumps(data, indent=2) + "\n")
        result = self.t.run(
            "merge", "--build-info", str(tampered),
            "--initramfs-info", str(release.initramfs_info_path),
            "--kernel-out", str(release.kernel_out),
            "--image", str(release.image_path),
            "--ramdisk", str(release.ramdisk_path),
            "--contract", str(release.contract_path),
            "--kver", KVER, "--dtb-source", "stock-rom",
            "--out", str(release.build_dir / "out.json"), tool=METADATA)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("artifact_sha256", result.stderr)

    def test_merge_rejects_device_ready_false(self):
        release = self.t.release("F")
        data = release.build_builder_info()
        data["device_ready"] = False
        tampered = release.build_dir / "notready-build-info.json"
        tampered.write_text(json.dumps(data, indent=2) + "\n")
        result = self.t.run(
            "merge", "--build-info", str(tampered),
            "--initramfs-info", str(release.initramfs_info_path),
            "--kernel-out", str(release.kernel_out),
            "--image", str(release.image_path),
            "--ramdisk", str(release.ramdisk_path),
            "--contract", str(release.contract_path),
            "--kver", KVER, "--dtb-source", "stock-rom",
            "--out", str(release.build_dir / "out.json"), tool=METADATA)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("device_ready", result.stderr)

    def test_stage_rejects_tampered_staged_image(self):
        self.stage(self.A)
        with self.staged()["image"].open("ab") as stream:
            stream.write(b"\x00")
        result = self.t.run(
            "stage", "--build-info", str(self.staged()["build_info"]),
            "--image", str(self.staged()["image"]),
            "--staged-dir", str(self.t.staging), "--kver", KVER,
            tool=METADATA)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("artifact", result.stderr)

    def test_stage_requires_stock_rom_dtb(self):
        release = self.t.release("G")
        data = release.build_builder_info()
        data["payload"]["dtb"]["source"] = "upstream-artifact"
        builder = release.build_dir / "artifact-dtb-build-info.json"
        builder.write_text(json.dumps(data, indent=2) + "\n")
        staged_image = self.t.staging / f"boot-{KVER}.img"
        shutil.copyfile(release.image_path, staged_image)
        merged = release.build_dir / "out.json"
        merge = self.t.run(
            "merge", "--build-info", str(builder),
            "--initramfs-info", str(release.initramfs_info_path),
            "--kernel-out", str(release.kernel_out),
            "--image", str(staged_image), "--ramdisk", str(release.ramdisk_path),
            "--contract", str(release.contract_path), "--kver", KVER,
            "--dtb-source", "upstream-artifact", "--out", str(merged),
            tool=METADATA)
        self.assertEqual(merge.returncode, 0, merge.stderr)
        staged_info = self.t.staging / f"boot-{KVER}.build-info.json"
        shutil.copyfile(merged, staged_info)
        result = self.t.run(
            "stage", "--build-info", str(staged_info), "--image", str(staged_image),
            "--staged-dir", str(self.t.staging), "--kver", KVER, tool=METADATA)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("stock-rom", result.stderr)

    def test_flat_projection_mismatch_is_rejected(self):
        self.stage(self.A)
        self.mutate_build_info(
            lambda data: data.__setitem__("bootimg_sha256", "0" * 64))
        result = self.t.apply(self.A)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("alias mismatch", result.stderr)

    def test_legacy_v1_metadata_is_diagnostic_only(self):
        self.stage(self.A)
        self.write_legacy_v1_metadata()
        dry = self.t.apply(self.A, "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("legacy schema v1", dry.stderr)
        write = self.t.apply(self.A, "--yes-write")
        self.assertEqual(write.returncode, 1, write.stderr)
        self.assertIn("schema v2", write.stderr)
        self.assert_device_unchanged()

    def test_manifest_schema_version_is_required_for_write(self):
        self.stage(self.A)
        self.mutate_manifest(lambda values: values.pop("schema_version"))
        dry = self.t.apply(self.A, "--dry-run")
        self.assertEqual(dry.returncode, 1, dry.stderr)
        self.assertIn("manifest.schema_version", dry.stderr)

    def test_recorded_real_producer_samples(self):
        builder = json.loads(
            (fx.FIXTURES / "boot-builder-build-info.real-sample.json").read_text())
        initramfs = json.loads(
            (fx.FIXTURES / "initramfs-info.real-sample.json").read_text())
        for key in ("artifact_sha256", "payload", "device_ready", "header"):
            self.assertIn(key, builder)
        for key in ("kernel", "dtb", "ramdisk"):
            self.assertIn(key, builder["payload"])
        for key in ("artifact_sha256", "root_contract", "device_ready"):
            self.assertIn(key, initramfs)
        # If the recorded real artifacts are present, the schema implementation
        # must extract exactly the identity the real boot-builder recorded.
        image = PROJECT / "out/boot/boot-liuqin-dev.img"
        if not image.is_file():
            self.skipTest("recorded real boot.img is not present (out/boot)")
        sys.path.insert(0, str(PROJECT / "kernel/fedora"))
        try:
            import liuqin_boot_metadata as metadata
        finally:
            sys.path.pop(0)
        sections = metadata.boot_image_sections(image)
        recorded = builder["payload"]
        self.assertEqual(sections["kernel_gzip_sha256"],
                         recorded["kernel"]["gzip_sha256"])
        self.assertEqual(sections["kernel_image_sha256"],
                         recorded["kernel"]["image_sha256"])
        self.assertEqual(sections["ramdisk_sha256"], recorded["ramdisk"]["sha256"])
        self.assertEqual(sections["dtb_sha256"], recorded["dtb"]["sha256"])


# ---------------------------------------------------------------------------
# apply/rollback/recover/confirm on plain files (the original 18 scenarios)
# ---------------------------------------------------------------------------


class ApplyBootTests(ChainTestCase):
    def test_status_json(self):
        report = self.t.status_json()
        self.assertEqual(report["tool"], "liuqin-apply-boot")
        self.assertEqual(report["version"], "2.1.0")
        self.assertEqual(report["devices"]["boot_a"]["kind"], "regular")
        self.assertEqual(report["devices"]["boot_a"]["size"], PARTITION_BYTES)
        self.assertEqual(report["journal"], {})
        self.assertEqual(report["root_layout"]["profile"], "override")
        self.assertEqual(report["staged_images"], [])
        self.assertIn("kernel_pairs", report)
        self.assertEqual(report["backups"], [])

    def test_stage_command_record(self):
        self.stage(self.A)
        result = self.t.run("stage", "--image", str(self.staged()["image"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.staged()["image"].with_suffix(".stage.json").read_text())
        self.assertEqual(record["image_sha256"], fx.sha256_file(self.staged()["image"]))
        self.assertIn("apply --image", record["apply_command"])
        report = self.t.status_json()
        self.assertTrue(report["staged_images"][0]["stage_record"])
        self.assertEqual(report["staged_images"][0]["metadata_schema_version"], 2)

    def test_dry_run_is_default_and_writes_nothing(self):
        self.stage(self.A)
        before = self.t.device_sha(self.t.device_a)
        result = self.t.apply(self.A)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY-RUN", result.stdout)
        self.assertEqual(self.t.device_sha(self.t.device_a), before)
        self.assertEqual(self.t.backups(), [])
        self.assertEqual(self.t.journal(), {})

    def test_legacy_cli_with_image_flag(self):
        self.stage(self.A)
        result = self.t.run("--image", str(self.staged()["image"]), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY-RUN", result.stdout)

    def test_write_gates(self):
        self.stage(self.A)
        before = self.t.device_sha(self.t.device_a)
        env = {"LIUQIN_EXPERIMENTAL_DEVICE_WRITE": ""}
        result = self.t.apply(self.A, "--yes-write", env=env)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("gated", result.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), before)

    def test_oversized_image_refused(self):
        self.stage(self.A)
        oversized = self.t.staging / "oversized.img"
        blob = bytearray(self.A.image)
        with oversized.open("wb") as stream:
            stream.write(blob)
            stream.truncate(PARTITION_BYTES + 4096)
        result = self.t.run("apply", "--image", str(oversized), "--dry-run")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("larger than", result.stderr)

    def test_non_v2_header_refused(self):
        self.stage(self.A)
        bad = self.t.staging / "boot-v3.img"
        blob = bytearray(self.A.image)
        blob[40:44] = (3).to_bytes(4, "little")  # header_version
        bad.write_bytes(bytes(blob))
        result = self.t.run("apply", "--image", str(bad), "--dry-run")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("header version", result.stderr)

    def test_release_mismatch_refused(self):
        self.stage(self.A)

        def mutate(data):
            data["kernel_release"] = "0.0.0-other"
            data["payload"]["kernel"]["release"] = "0.0.0-other"
        self.mutate_build_info(mutate)
        result = self.t.apply(self.A, "--yes-write")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("kernel_release", result.stderr)
        self.assert_device_unchanged()

    def test_device_ready_false_refused(self):
        self.stage(self.A)
        self.mutate_build_info(lambda data: data.__setitem__("device_ready", False))
        result = self.t.apply(self.A)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("device_ready", result.stderr)

    def test_missing_manifest_refused(self):
        self.stage(self.A)
        self.staged()["manifest"].unlink()
        result = self.t.apply(self.A)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("manifest missing", result.stderr)

    def test_missing_build_info_refused(self):
        self.stage(self.A)
        self.staged()["build_info"].unlink()
        result = self.t.apply(self.A)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("build-info missing", result.stderr)

    def test_upstream_artifact_dtb_gate(self):
        self.upgraded_staging(self.B)

        def mutate(data):
            data["dtb_source"] = "upstream-artifact"
            data["payload"]["dtb"]["source"] = "upstream-artifact"
        self.mutate_build_info(mutate)
        dry = self.t.apply(self.B, "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("gate warning", dry.stderr)
        refused = self.t.apply(self.B, "--yes-write")
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("upstream-artifact", refused.stderr)
        allowed = self.t.apply(self.B, "--yes-write", "--allow-dev-dtb-source")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))

    def test_missing_boot_a_refused(self):
        self.stage(self.A)
        self.t.device_a.unlink()
        result = self.t.apply(self.A, "--yes-write")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("boot_a device not found", result.stderr)

    def test_differing_boot_b_refused_unless_override(self):
        self.upgraded_staging(self.B)
        with self.t.device_b.open("r+b") as stream:
            stream.seek(0)
            stream.write(b"DIFFERENT\n")
        result = self.t.apply(self.A, "--yes-write")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("boot_b differs", result.stderr)
        self.assert_device_unchanged()
        allowed = self.t.apply(self.B, "--yes-write", "--allow-differing-boot-b")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))

    def test_kernel_pair_mismatch_refused(self):
        """A staged image whose embedded kernel Image is not the installed one
        must be refused (kernel identity mismatch is no longer a warning)."""
        self.stage(self.A)
        self.t.rpm_upgrade(self.B)  # rootfs/modules now B, staging still A
        result = self.t.apply(self.A, "--yes-write")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("pair.kernel_image", result.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.A))

    def test_apply_normal_and_rollback(self):
        self.upgraded_staging(self.B)
        original_boot_a = self.t.device_sha(self.t.device_a)
        self.apply_write(self.B)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))
        self.assertEqual(self.t.device_sha(self.t.device_b), original_boot_a)  # untouched
        backups = self.t.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.t.device_sha(backups[0]), original_boot_a)
        journal = self.t.journal()
        self.assertEqual(journal["phase"], "applied")
        self.assertEqual(journal["partition_sha256"], self.t.padded_sha(self.B))
        self.assertEqual(journal["kernel_image_sha256"],
                         fx.sha256_bytes(self.B.kernel_image))
        self.assertEqual(journal["fallback_sha256"], original_boot_a)
        status = self.t.status_json("--hashes")
        self.assertEqual(status["journal"]["phase"], "applied")
        self.assertEqual(len(status["backups"]), 1)
        self.assertEqual(status["boot_b_fallback_state"],
                         "recorded known-good fallback")
        self.assertTrue(status["boot_b_recorded_fallback"])
        self.assertEqual(status["installed_kernel_pair"],
                         fx.sha256_bytes(self.B.kernel_image))
        rollback = self.t.rollback("--yes-write")
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), original_boot_a)
        self.assertEqual(self.t.journal()["phase"], "rolled_back")
        self.assertEqual(self.t.installed_pair_id(), fx.sha256_bytes(self.A.kernel_image))

    def test_readback_mismatch_restores_backup(self):
        self.upgraded_staging(self.B)
        original = self.t.device_sha(self.t.device_a)
        env = {"LIUQIN_APPLY_TEST_READBACK_CORRUPT": "after-write"}
        result = self.t.apply(self.B, "--yes-write", env=env)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("restored from the verified backup", result.stderr)
        self.assertIn("recover --yes-write", result.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), original)
        self.assertEqual(self.t.journal()["phase"], "failed_restored")
        self.assertEqual(len(self.t.backups()), 1)

    def test_simulated_power_loss_then_recover(self):
        self.upgraded_staging(self.B)
        original = self.t.device_sha(self.t.device_a)
        env = {"LIUQIN_APPLY_TEST_ABORT_WRITE_AFTER": str(1024 * 1024)}
        result = self.t.apply(self.B, "--yes-write", env=env)
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(self.t.journal()["phase"], "writing")
        self.assertNotEqual(self.t.device_sha(self.t.device_a), original)
        self.assertEqual(len(self.t.backups()), 1)
        recover = self.t.run("recover", "--yes-write")
        self.assertEqual(recover.returncode, 0, recover.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), original)
        self.assertEqual(self.t.journal()["phase"], "rolled_back")

    def test_concurrent_lock(self):
        self.upgraded_staging(self.B)
        env = {"LIUQIN_APPLY_TEST_HOLD_LOCK_MS": "1500"}
        first = subprocess.Popen(
            [sys.executable, str(TOOL), *map(str, ("apply", "--image",
                                                   str(self.staged()["image"]),
                                                   "--yes-write"))],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**self.t.env, **env}, cwd=str(self.t.root))
        try:
            time.sleep(0.5)
            second = self.t.apply(self.B, "--yes-write")
            self.assertEqual(second.returncode, 3, second.stderr)
            self.assertIn("holds", second.stderr)
        finally:
            _stdout, stderr = first.communicate(timeout=120)
        self.assertEqual(first.returncode, 0, stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))

    def test_rollback_without_backup_refused(self):
        result = self.t.rollback("--yes-write")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("no verified backup", result.stderr)


# ---------------------------------------------------------------------------
# continuous updates: A -> B -> C with no manual equalize / no override
# ---------------------------------------------------------------------------


class ContinuousUpdateTests(ChainTestCase):
    def test_apply_b_after_a_records_boot_b_fallback(self):
        self.upgraded_staging(self.B)
        a_sha = self.t.device_sha(self.t.device_a)  # == boot_b (install state)
        self.apply_write(self.B)
        journal = self.t.journal()
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))
        self.assertEqual(self.t.device_sha(self.t.device_b), a_sha)   # from install
        self.assertEqual(journal["fallback_sha256"], a_sha)
        self.assertEqual(journal["boot_b_sha256"], a_sha)

    def test_continuous_a_b_c_without_intervention_or_override(self):
        # A -> B
        self.t.rpm_upgrade(self.B)
        self.stage(self.B)
        self.apply_write(self.B)
        # B -> C: boot_a != boot_b now, which used to exit 2; the recorded
        # known-good fallback must be accepted with no override.
        self.t.rpm_upgrade(self.C)
        self.stage(self.C)
        dry = self.t.apply(self.C)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("recorded known-good fallback", dry.stdout)
        self.assertNotIn("--allow-differing-boot-b", dry.stdout)
        self.apply_write(self.C)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.C))
        self.assertEqual(self.t.device_sha(self.t.device_b), self.t.padded_sha(self.A))
        journal = self.t.journal()
        self.assertEqual(journal["phase"], "applied")
        self.assertEqual(journal["kernel_image_sha256"],
                         fx.sha256_bytes(self.C.kernel_image))
        self.assertEqual(journal["fallback_sha256"], self.t.padded_sha(self.A))

    def test_unrecorded_differing_boot_b_needs_confirm_or_override(self):
        self.upgraded_staging(self.B)
        with self.t.device_b.open("r+b") as stream:
            stream.seek(0)
            stream.write(self.B.image)  # unknown but structurally valid image
            stream.write(b"\x00" * (PARTITION_BYTES - len(self.B.image)))
        result = self.t.apply(self.B, "--yes-write")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not the fallback recorded", result.stderr)
        self.assertIn("confirm --yes-write", result.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a),
                         self.t.padded_sha(self.A))

    def test_confirm_resyncs_fallback_and_next_update(self):
        self.upgraded_staging(self.B)
        self.apply_write(self.B)
        self.assertEqual(self.t.device_sha(self.t.device_b), self.t.padded_sha(self.A))
        draft = self.t.confirm("--dry-run")
        self.assertEqual(draft.returncode, 0, draft.stderr)
        self.assertIn("DRY-RUN", draft.stdout)
        confirmed = self.t.confirm("--yes-write")
        self.assertEqual(confirmed.returncode, 0, confirmed.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_b), self.t.padded_sha(self.B))
        journal = self.t.journal()
        self.assertEqual(journal["phase"], "fallback_confirmed")
        self.assertEqual(journal["fallback_sha256"], self.t.padded_sha(self.B))
        self.assertEqual(len(self.t.backups("boot_b")), 1)
        # C apply still works after the fallback re-sync
        self.t.rpm_upgrade(self.C)
        self.stage(self.C)
        self.apply_write(self.C)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.C))
        self.assertEqual(self.t.device_sha(self.t.device_b), self.t.padded_sha(self.B))

    def test_confirm_refuses_changed_boot_a(self):
        self.upgraded_staging(self.B)
        self.apply_write(self.B)
        with self.t.device_a.open("r+b") as stream:
            stream.seek(PARTITION_BYTES - 4096)
            stream.write(b"\xAA" * 4096)
        result = self.t.confirm("--yes-write")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("changed since the last apply", result.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_b), self.t.padded_sha(self.A))

    def test_confirm_refuses_inconsistent_kernel_pair(self):
        self.upgraded_staging(self.B)
        self.apply_write(self.B)
        # Corrupt the installed kernel Image itself: the boot payload can then no
        # longer be shown to match the installed modules pair.
        (self.t.modules_dir / KVER / "vmlinuz").write_bytes(b"tampered" * 64)
        result = self.t.confirm("--yes-write")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("kernel identity is inconsistent", result.stderr)


# ---------------------------------------------------------------------------
# rollback consistency: boot payload + kernel modules pair
# ---------------------------------------------------------------------------


class RollbackPairTests(ChainTestCase):
    def test_rollback_restores_matching_modules_pair(self):
        self.t.rpm_upgrade(self.B)
        self.stage(self.B)
        self.apply_write(self.B)
        # The upgrade archived the A pair before replacing the modules tree.
        pairs = self.t.pair_list()
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0]["pair_id"], fx.sha256_bytes(self.A.kernel_image))
        rollback = self.t.rollback("--yes-write")
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        journal = self.t.journal()
        self.assertEqual(journal["phase"], "rolled_back")
        self.assertTrue(journal["pair_restored"])
        # Pair evidence: boot payload kernel Image == restored vmlinuz sha.
        payload_image = self.t.partition_kernel_image_sha(self.t.device_a)
        installed_vmlinuz = self.t.installed_pair_id()
        self.assertEqual(payload_image, fx.sha256_bytes(self.A.kernel_image))
        self.assertEqual(installed_vmlinuz, payload_image)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.A))
        module = self.t.modules_dir / KVER / "kernel/drivers/liuqin_sim.ko"
        self.assertEqual(module.read_bytes(), self.A.kernel_modules_files()[
            "kernel/drivers/liuqin_sim.ko"])
        # The modules manifest of the restored pair verifies against the tree.
        # (verify the surviving archive of the released pair as well)
        live_pairs = {entry["pair_id"] for entry in self.t.pair_list()}
        self.assertTrue(live_pairs)
        for pair_id in live_pairs:
            verify = self.t.pair_verify(pair_id)
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_rollback_refuses_without_archived_pair_then_boot_only(self):
        self.t.rpm_upgrade(self.B)
        self.stage(self.B)
        self.apply_write(self.B)
        shutil.rmtree(self.t.pair_store / "pairs" / fx.sha256_bytes(self.A.kernel_image))
        refused = self.t.rollback("--yes-write")
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("boot-only", refused.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))
        allowed = self.t.rollback("--yes-write", "--boot-only")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.A))
        journal = self.t.journal()
        self.assertFalse(journal["pair_restored"])
        self.assertIn("no archived kernel pair", journal["pair_restore_reason"])

    def test_rollback_refuses_corrupted_archived_pair(self):
        self.t.rpm_upgrade(self.B)
        self.stage(self.B)
        self.apply_write(self.B)
        module = self.archived_tree_path(
            fx.sha256_bytes(self.A.kernel_image),
            f"{self.t.modules_dir}/{KVER}/kernel/drivers/liuqin_sim.ko")
        module.write_bytes(b"corrupted")
        refused = self.t.rollback("--yes-write")
        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("failed verification", refused.stderr)
        self.assertEqual(self.t.device_sha(self.t.device_a), self.t.padded_sha(self.B))

    def test_pair_archive_verify_restore_cycle(self):
        self.t.rpm_upgrade(self.B)  # archives A, installs B
        pair_a = fx.sha256_bytes(self.A.kernel_image)
        verify = self.t.pair_verify(pair_a)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        self.assertIn("PASS", verify.stdout)
        self.assertEqual(self.t.installed_pair_id(), fx.sha256_bytes(self.B.kernel_image))
        restore = self.t.run("restore", "--pair-id", pair_a, "--yes-write", tool=PAIR)
        self.assertEqual(restore.returncode, 0, restore.stderr)
        self.assertEqual(self.t.installed_pair_id(), pair_a)
        self.assertEqual(self.t.release_file.read_text().strip(), KVER)
        # The current (B) pair was preserved before the restore, so it can be
        # restored back (this is what makes a rollback reversible).
        pairs = {entry["pair_id"] for entry in self.t.pair_list()}
        self.assertIn(fx.sha256_bytes(self.B.kernel_image), pairs)

    def test_pair_archive_detects_corruption_and_retention_is_bounded(self):
        self.t.rpm_upgrade(self.B)  # archive A
        self.t.rpm_upgrade(self.C)  # archive B, prune A (default retain=1)
        pairs = self.t.pair_list()
        self.assertEqual(len(pairs), 1, pairs)
        self.assertEqual(pairs[0]["pair_id"], fx.sha256_bytes(self.B.kernel_image))
        (self.archived_tree_path(
            pairs[0]["pair_id"], f"{self.t.modules_dir}/{KVER}/vmlinuz")).write_bytes(b"bad")
        verify = self.t.pair_verify(pairs[0]["pair_id"])
        self.assertEqual(verify.returncode, 1, verify.stdout + verify.stderr)
        self.assertIn("FAIL", verify.stdout)

    def test_pair_restore_refused_without_write_gate(self):
        self.t.rpm_upgrade(self.B)
        pair_a = fx.sha256_bytes(self.A.kernel_image)
        result = self.t.run("restore", "--pair-id", pair_a, "--yes-write",
                            env={"LIUQIN_EXPERIMENTAL_DEVICE_WRITE": ""}, tool=PAIR)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("gated", result.stderr)
        self.assertEqual(self.t.installed_pair_id(), fx.sha256_bytes(self.B.kernel_image))


# ---------------------------------------------------------------------------
# the deliverable chain: install A -> update B -> pre-reboot -> rollback A -> C
# ---------------------------------------------------------------------------


class FullChainTests(ChainTestCase):
    def test_install_a_update_b_check_rollback_a_update_c(self):
        t, A, B, C = self.t, self.A, self.B, self.C
        # --- step 1: installed A -------------------------------------------
        a_sha = t.padded_sha(A)
        self.assertEqual(t.device_sha(t.device_a), a_sha)
        self.assertEqual(t.device_sha(t.device_b), a_sha)
        self.assertEqual(t.installed_pair_id(), fx.sha256_bytes(A.kernel_image))

        # --- step 2: dnf upgrade kernel (B) + kernel-install hook staging ---
        t.rpm_upgrade(B)
        staged = self.stage(B)
        self.assertEqual(staged["stage"].returncode, 0)

        # --- step 3: explicit apply B + pre-reboot state check -------------
        self.apply_write(B)
        pre_reboot = t.status_json("--hashes")
        self.assertEqual(pre_reboot["journal"]["phase"], "applied")
        self.assertEqual(pre_reboot["staged_images"][0]["metadata_schema_version"], 2)
        self.assertEqual(pre_reboot["installed_kernel_pair"],
                         fx.sha256_bytes(B.kernel_image))
        self.assertEqual(pre_reboot["boot_b_fallback_state"],
                         "recorded known-good fallback")
        self.assertEqual(pre_reboot["devices"]["boot_a"]["sha256"], t.padded_sha(B))
        self.assertEqual(pre_reboot["devices"]["boot_b"]["sha256"], a_sha)
        self.assertTrue(pre_reboot["boot_b_recorded_fallback"])
        self.assertEqual({p["pair_id"] for p in pre_reboot["kernel_pairs"]["pairs"]},
                         {fx.sha256_bytes(A.kernel_image)})

        # --- step 4: rollback to A restores boot + the matching modules ----
        rollback = t.rollback("--yes-write")
        self.assertEqual(rollback.returncode, 0, rollback.stderr)
        journal = t.journal()
        self.assertEqual(journal["phase"], "rolled_back")
        self.assertTrue(journal["pair_restored"])
        self.assertEqual(t.device_sha(t.device_a), a_sha)
        self.assertEqual(t.partition_kernel_image_sha(t.device_a),
                         fx.sha256_bytes(A.kernel_image))
        self.assertEqual(t.installed_pair_id(), fx.sha256_bytes(A.kernel_image))

        # --- step 5: update to C after the rollback, still no overrides ----
        t.rpm_upgrade(C)
        self.stage(C)
        dry = t.apply(C)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertNotIn("--allow-differing-boot-b", dry.stdout)
        self.apply_write(C)
        self.assertEqual(t.device_sha(t.device_a), t.padded_sha(C))
        self.assertEqual(t.journal()["phase"], "applied")
        self.assertEqual(t.installed_pair_id(), fx.sha256_bytes(C.kernel_image))
        self.assertEqual(t.journal()["kernel_image_sha256"],
                         fx.sha256_bytes(C.kernel_image))
        # boot_b still holds the install-time known-good fallback A
        self.assertEqual(t.device_sha(t.device_b), a_sha)


# ---------------------------------------------------------------------------
# static integration: the packaged tools and the repo must stay consistent
# ---------------------------------------------------------------------------


class StaticIntegrationTests(unittest.TestCase):
    SPEC = PROJECT / "kernel/fedora/kernel-liuqin.spec"
    HOOK = PROJECT / "kernel/fedora/99-liuqin-android-boot.install"
    REFRESH = PROJECT / "kernel/fedora/liuqin-bootimg-refresh"
    APPLY = PROJECT / "kernel/fedora/liuqin-apply-boot"
    METADATA = PROJECT / "kernel/fedora/liuqin_boot_metadata.py"
    PAIR = PROJECT / "kernel/fedora/liuqin-kernel-pair"
    BUILD_RPM = PROJECT / "scripts/build-kernel-rpm.sh"
    BOOT_TOOLS_RPM = PROJECT / "scripts/build-boot-tools-rpm.sh"

    def test_spec_packages_the_schema_and_pair_tools(self):
        spec = self.SPEC.read_text()
        for source in ("Source17: liuqin_boot_metadata.py",
                       "Source18: liuqin-kernel-pair"):
            self.assertIn(source, spec)
        self.assertIn("/usr/lib/liuqin/liuqin_boot_metadata.py", spec)
        self.assertIn("/usr/sbin/liuqin-kernel-pair", spec)
        # %pre archives the kernel pair before rpm replaces it, and only on a
        # real systemd-booted system (offline image assembly safety).
        pre = spec[spec.index("%pre"):spec.index("%post\n")]
        self.assertIn("liuqin-kernel-pair archive --reason rpm-upgrade", pre)
        self.assertIn("/run/systemd/system", pre)
        self.assertIn("LIUQIN_KERNEL_PAIR_ARCHIVE", pre)
        # fixed kernelrelease: an upgrade must not run kernel-install remove and
        # delete the freshly staged image of the same kver.
        postun = spec[spec.index("%postun"):spec.index("%changelog")]
        self.assertIn('[ "$1" -eq 0 ]', postun)

    def test_build_script_stages_every_spec_source(self):
        spec_sources = []
        for line in self.SPEC.read_text().splitlines():
            if line.startswith("Source") and ":" in line:
                spec_sources.append(line.split(":", 1)[1].strip())
        script = self.BUILD_RPM.read_text()
        missing = [name for name in spec_sources
                   if f'$S/{name}' not in script and name not in
                   {"liuqin_boot_metadata.py", "liuqin-kernel-pair"}]
        # The two metadata sources are staged explicitly (two-line change).
        for name in ("liuqin_boot_metadata.py", "liuqin-kernel-pair"):
            self.assertIn(f"$S/{name}", script)
        self.assertEqual(missing, [], f"spec sources not staged by the build script: {missing}")

    def test_single_producer_consumer_implementation(self):
        hook = self.HOOK.read_text()
        refresh = self.REFRESH.read_text()
        apply = self.APPLY.read_text()
        metadata = self.METADATA.read_text()
        # producer: refresh merges with the shared tool, hook stages with it
        self.assertIn('python3 "$METADATA" merge', refresh)
        self.assertIn('python3 "$METADATA" stage', hook)
        # consumer: apply loads the very same module
        self.assertIn("liuqin_boot_metadata.py", apply)
        self.assertIn("def load_boot_metadata", metadata)
        # no second hand-written staging manifest writer: the hook no longer
        # writes boot-<kver>.manifest itself (the metadata tool does)
        self.assertNotIn("boot-$KVER.manifest\n", hook.replace(
            'cp -f "$OUT/boot-$KVER.manifest"', ""))
        self.assertIn("def stage_metadata", metadata)

    def test_boot_tools_rpm_has_repo_consistency_check(self):
        script = self.BOOT_TOOLS_RPM.read_text()
        # every repository-sourced tool packaged in liuqin-boot-tools and
        # kernel-liuqin is compared byte-for-byte with the repository after the
        # RPM payload is extracted; a mismatch fails the build.
        self.assertIn("repo-consistency", script)
        self.assertIn("REPO_CONSISTENCY", script)
        self.assertIn("repo_consistency", script)
        for packaged in ("liuqin_boot_metadata.py", "liuqin-kernel-pair"):
            self.assertIn(packaged, script)

    def test_docs_state_the_rollback_boundary(self):
        doc_path = PROJECT / "docs/maintenance/boot-update.md"
        if not doc_path.is_file():
            self.skipTest("maintainer documentation is not present in this source tree")
        doc = doc_path.read_text()
        self.assertIn("boot.img 恢复 ≠ 完整系统回滚", doc)
        self.assertIn("schema v2", doc)


if __name__ == "__main__":
    unittest.main(verbosity=2)
