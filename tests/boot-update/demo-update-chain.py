#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproducible offline evidence for the boot update/rollback chain.

Runs the deliverable sequence on a simulated tablet (regular files only):

    install A  ->  dnf upgrade kernel-liuqin to B + kernel-install hook staging
               ->  pre-reboot state check
               ->  apply B (boot_a), boot_b keeps the install-time known-good copy
               ->  rollback to A (boot payload + matching kernel modules pair)
               ->  dnf upgrade to C -> apply C (still no manual equalize/override)

Everything is written under out/boot-update/tn0032/ (git-ignored):
  transcript.log      full command/output transcript
  evidence.json       machine-readable checks + hashes
  staging/            the producer (schema v2 merge+stage) outputs that apply consumed
  pair/               archived kernel pair metadata + file index (A) and pair.json
  pre-reboot-status.json  liuqin-apply-boot status --json at the pre-reboot point

No block device, no loop device, no tablet involved.  This is verified-offline
evidence only; it does not prove real ABL/boot partition behaviour.

Run: python3 tests/boot-update/demo-update-chain.py
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))

import fixture_artifacts as fx  # noqa: E402

PROJECT = fx.PROJECT
OUT = PROJECT / "out/boot-update/tn0032"
CHECKS: list[dict] = []
TRANSCRIPT: list[str] = []


def emit(title: str) -> None:
    TRANSCRIPT.append("")
    TRANSCRIPT.append(f"===== {title} =====")


def check(check_id: str, ok: bool, detail: str = "") -> bool:
    CHECKS.append({"id": check_id, "ok": bool(ok), "detail": detail})
    status = "PASS" if ok else "FAIL"
    TRANSCRIPT.append(f"[{status}] {check_id}" + (f": {detail}" if detail else ""))
    return ok


def run(tablet, args, *, tool=None, env=None):
    kwargs = {"env": env} if env else {}
    if tool is not None:
        kwargs["tool"] = tool
    result = tablet.run(*args, **kwargs)
    TRANSCRIPT.append("$ " + " ".join(map(str, args)))
    TRANSCRIPT.append(f"[exit {result.returncode}]")
    if result.stdout.strip():
        TRANSCRIPT.append("--- stdout ---")
        TRANSCRIPT.append(result.stdout.rstrip())
    if result.stderr.strip():
        TRANSCRIPT.append("--- stderr ---")
        TRANSCRIPT.append(result.stderr.rstrip())
    return result


def sha256_file(path: Path) -> str:
    return fx.sha256_file(path)


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    tablet = fx.make_tablet(OUT / "work")
    A, B, C = tablet.release("A"), tablet.release("B"), tablet.release("C")

    # ---------------------------------------------------------------- install A
    emit("step 1: install A (factory state: boot_a == boot_b == A, modules A)")
    tablet.install(A)
    a_padded = tablet.padded_sha(A)
    check("install.boot_a == boot_b == padded(A)",
          tablet.device_sha(tablet.device_a) == tablet.device_sha(tablet.device_b)
          == a_padded, a_padded)
    check("install.installed pair == sha256(Image A)",
          tablet.installed_pair_id() == fx.sha256_bytes(A.kernel_image))
    check("install.no journal", tablet.journal() == {})
    check("install.no archived pair", tablet.pair_list() == [])

    # ---------------------------------------------------------- upgrade to B
    emit("step 2: dnf upgrade kernel-liuqin -> B (RPM %pre archives pair A, "
         "kernel-install hook stages schema v2 metadata)")
    upgrade = run(tablet, ["archive", "--reason", "rpm-upgrade"], tool=fx.PAIR)
    check("upgrade.%pre pair archive A rc=0", upgrade.returncode == 0,
          upgrade.stdout.strip().splitlines()[-1] if upgrade.stdout.strip() else upgrade.stderr)
    tablet._install_rootfs_payload(B)  # rpm replaces the fixed-path modules tree
    produced = tablet.produce_staging(B)
    if not check("producer.merge rc=0", produced["merge"].returncode == 0,
                 produced["merge"].stderr):
        return finish()
    check("producer.stage rc=0 (schema v2 validated against staged bytes + installed "
          "kernel/DTB)", produced["stage"].returncode == 0, produced["stage"].stderr)
    staging_dir = OUT / "staging"
    staging_dir.mkdir()
    for path in (produced["image"], produced["build_info"], produced["manifest"],
                 produced["sums"]):
        shutil.copyfile(path, staging_dir / path.name)
    metadata = json.loads(produced["build_info"].read_text())
    check("schema_v2.version == 2", metadata["schema_version"] == 2)
    check("schema_v2.flat artifact == nested payload artifact",
          metadata["artifact_sha256"] == metadata["bootimg_sha256"]
          == metadata["payload"]["artifact"]["sha256"])
    check("schema_v2.staged kernel Image == installed vmlinuz",
          metadata["kernel_image_sha256"] == tablet.installed_pair_id())
    check("schema_v2.manifest schema_version=2",
          "schema_version=2" in produced["manifest"].read_text())

    # ------------------------------------------------------- pre-reboot state
    emit("step 3: apply B, then check the pre-reboot state")
    dry = run(tablet, ["apply", "--image", produced["image"]])
    check("apply dry-run rc=0 (producer output accepted, no override)", dry.returncode == 0)
    applied = run(tablet, ["apply", "--image", produced["image"], "--yes-write"])
    check("apply B --yes-write rc=0", applied.returncode == 0, applied.stderr)
    check("apply.boot_a == padded(B)",
          tablet.device_sha(tablet.device_a) == tablet.padded_sha(B))
    check("apply.boot_b untouched (install-time A)",
          tablet.device_sha(tablet.device_b) == a_padded)
    status = json.loads(run(tablet, ["status", "--json", "--hashes"]).stdout)
    (OUT / "pre-reboot-status.json").write_text(json.dumps(status, indent=2) + "\n")
    check("pre_reboot.journal applied", status["journal"]["phase"] == "applied")
    check("pre_reboot.staged metadata schema 2",
          status["staged_images"][0].get("metadata_schema_version") == 2)
    check("pre_reboot.installed pair == B",
          status["installed_kernel_pair"] == fx.sha256_bytes(B.kernel_image))
    check("pre_reboot.boot_b recorded fallback",
          status.get("boot_b_fallback_state") == "recorded known-good fallback")
    check("pre_reboot.archived pairs contains A",
          fx.sha256_bytes(A.kernel_image) in
          {entry["pair_id"] for entry in status["kernel_pairs"]["pairs"]})

    # --------------------------------------------------------------- rollback A
    emit("step 4: rollback to A (boot_a bytes + matching kernel modules pair)")
    rollback = run(tablet, ["rollback", "--yes-write"])
    check("rollback rc=0", rollback.returncode == 0, rollback.stderr)
    journal = tablet.journal()
    check("rollback.journal rolled_back", journal["phase"] == "rolled_back")
    check("rollback.pair_restored true", journal.get("pair_restored") is True)
    check("rollback.boot_a == padded(A)",
          tablet.device_sha(tablet.device_a) == a_padded)
    payload_image = tablet.partition_kernel_image_sha(tablet.device_a)
    installed_pair = tablet.installed_pair_id()
    module_path = tablet.modules_dir / fx.KVER / "kernel/drivers/liuqin_sim.ko"
    check("rollback.boot payload Image == restored vmlinuz sha",
          payload_image == installed_pair == fx.sha256_bytes(A.kernel_image),
          payload_image)
    check("rollback.modules tree is release A",
          module_path.read_bytes() == A.kernel_modules_files()[
              "kernel/drivers/liuqin_sim.ko"])
    for pair_id in {entry["pair_id"] for entry in tablet.pair_list()}:
        verified = run(tablet, ["verify", "--pair-id", pair_id], tool=fx.PAIR)
        check(f"rollback.pair {pair_id[:12]} verifies", verified.returncode == 0,
              verified.stdout.strip())
    # archive the A/B pair metadata + size evidence
    pair_evidence = OUT / "pair"
    pair_evidence.mkdir()
    for entry in tablet.pair_list():
        source = Path(entry["path"])
        target = pair_evidence / entry["pair_id"]
        target.mkdir()
        for name in ("pair.json", "files.sha256"):
            shutil.copyfile(source / name, target / name)
    real_artifacts = real_pair_size_estimate()
    (OUT / "pair-size.json").write_text(json.dumps(real_artifacts, indent=2) + "\n")
    check("pair_size.real aarch64 pair documented",
          real_artifacts.get("estimated_pair_bytes", 0) > 0,
          f"{real_artifacts.get('estimated_pair_bytes')} bytes "
          f"(Image+modules+identity, real kernel build inputs)")

    # ------------------------------------------------------------- update to C
    emit("step 5: dnf upgrade to C -> apply C after the rollback (no override)")
    run(tablet, ["archive", "--reason", "rpm-upgrade"], tool=fx.PAIR)
    tablet._install_rootfs_payload(C)
    produced_c = tablet.produce_staging(C)
    check("producer.stage C rc=0", produced_c["stage"].returncode == 0,
          produced_c["stage"].stderr)
    dry_c = run(tablet, ["apply", "--image", produced_c["image"]])
    check("apply C dry-run rc=0, no --allow-differing-boot-b", dry_c.returncode == 0
          and "--allow-differing-boot-b" not in dry_c.stdout)
    applied_c = run(tablet, ["apply", "--image", produced_c["image"], "--yes-write"])
    check("apply C --yes-write rc=0", applied_c.returncode == 0, applied_c.stderr)
    check("apply_C.boot_a == padded(C)",
          tablet.device_sha(tablet.device_a) == tablet.padded_sha(C))
    check("apply_C.boot_b still install-time A (known-good fallback)",
          tablet.device_sha(tablet.device_b) == a_padded)
    journal_c = tablet.journal()
    check("apply_C.journal applied + pair C",
          journal_c["phase"] == "applied"
          and journal_c["kernel_image_sha256"] == fx.sha256_bytes(C.kernel_image))

    # ------------------------------------------------------------- summary
    emit("hashes")
    evidence = {
        "scope": "boot update/rollback chain",
        "simulation": "regular files only (no block/loop device, no tablet)",
        "releases": {
            tag: {
                "bootimg_sha256": fx.sha256_bytes(release.image),
                "padded_partition_sha256": tablet.padded_sha(release),
                "kernel_image_sha256": fx.sha256_bytes(release.kernel_image),
                "modules_manifest_sha256": fx.sha256_bytes(
                    release.modules_manifest(tablet.modules_dir / fx.KVER).encode()),
            }
            for tag, release in (("A", A), ("B", B), ("C", C))
        },
        "rollback": {
            "backup_boot_payload_kernel_image_sha256": payload_image,
            "restored_vmlinuz_sha256": installed_pair,
            "modules_file_sha256": fx.sha256_file(module_path),
        },
        "pair_size": real_artifacts,
        "checks": CHECKS,
        "transcript": str(OUT / "transcript.log"),
    }
    TRANSCRIPT.append(json.dumps(evidence["releases"], indent=2))
    (OUT / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return finish()


def real_pair_size_estimate() -> dict:
    """Actual bytes of one real aarch64 kernel pair (from the real kernel build)."""
    dist = PROJECT / "out/kernel-fedora/dist"
    result = {"source": str(dist), "available": False,
              "image_bytes": 0, "modules_tree_bytes": 0, "identity_bytes": 0,
              "estimated_pair_bytes": 0}
    image = dist / "Image"
    modules_tar = dist / "modules.tar.gz"
    if not image.is_file() or not modules_tar.is_file():
        return result
    result["available"] = True
    result["image_bytes"] = image.stat().st_size
    # uncompressed modules tree size from the tar member sizes (no extraction)
    import tarfile
    total = 0
    with tarfile.open(modules_tar, "r:gz") as archive:
        for member in archive:
            if member.isreg():
                total += member.size
    result["modules_tree_bytes"] = total
    identity = 0
    for name in ("kernel.release", "kernel-modules.manifest", "kernel-build-info.json",
                 "kernel-config", "Module.symvers"):
        candidates = [PROJECT / "out/rpms-kernel" / name,
                      PROJECT / "out/kernel-fedora/dist" / name]
        for candidate in candidates:
            if candidate.is_file():
                identity += candidate.stat().st_size
                break
    result["identity_bytes"] = identity
    result["estimated_pair_bytes"] = (result["image_bytes"]
                                      + result["modules_tree_bytes"] + identity)
    return result


def finish() -> int:
    failed = [item for item in CHECKS if not item["ok"]]
    TRANSCRIPT.append("")
    TRANSCRIPT.append(f"SUMMARY: {len(CHECKS) - len(failed)}/{len(CHECKS)} checks PASS")
    (OUT / "transcript.log").write_text("\n".join(TRANSCRIPT) + "\n")
    print("\n".join(TRANSCRIPT[-40:]))
    print(f"\nevidence: {OUT}/{{transcript.log,evidence.json,pre-reboot-status.json,pair-size.json}}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
