#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproducible offline demo of kernel/fedora/liuqin-apply-boot.

Uses the same simulated regular-file partitions and test-only environment hooks
as tests/boot-update/test-boot-update.py, and writes the working tree plus a
full command transcript under out/boot-update/demo/ (git-ignored) as reviewable
evidence.  No block device, no loop device, no tablet involved.

Scenarios: dry-run -> apply -> pre-reboot status -> rollback; then a simulated
power loss during an apply and `recover`.  The boot+modules paired rollback and
the full A->B->rollback->C chain are demonstrated by demo-update-chain.py.

Run: python3 tests/boot-update/demo-apply-boot.py
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
OUT = PROJECT / "out/boot-update/demo"


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    tablet = fx.make_tablet(OUT / "work")
    A, B = tablet.release("A"), tablet.release("B")
    transcript: list[str] = []
    failures = 0

    def emit(title: str) -> None:
        transcript.append("")
        transcript.append(f"===== {title} =====")

    def run(args, *, env=None, tool=None):
        kwargs = {"env": env} if env else {}
        if tool is not None:
            kwargs["tool"] = tool
        result = tablet.run(*args, **kwargs)
        transcript.append("$ " + " ".join(map(str, args)))
        transcript.append(f"[exit {result.returncode}]")
        if result.stdout.strip():
            transcript.append("--- stdout ---")
            transcript.append(result.stdout.rstrip())
        if result.stderr.strip():
            transcript.append("--- stderr ---")
            transcript.append(result.stderr.rstrip())
        return result

    tablet.install(A)
    run(["archive", "--reason", "rpm-upgrade"], tool=fx.PAIR)
    tablet._install_rootfs_payload(B)
    produced = tablet.produce_staging(B)

    emit("dry-run (default): validate the producer's schema v2 output")
    run(["apply", "--image", produced["image"]])

    emit("apply B to boot_a (explicit, double-gated) and inspect the state")
    run(["apply", "--image", produced["image"], "--yes-write"])
    run(["status", "--json", "--hashes"])

    emit("rollback to A (boot_a bytes + matching kernel modules pair)")
    run(["rollback", "--yes-write"])
    run(["status", "--json", "--hashes"])

    emit("simulated power loss during an apply, then recover")
    tablet.rpm_upgrade(B)
    tablet.produce_staging(B)
    run(["apply", "--image", tablet.require_staging(B), "--yes-write"],
        env={"LIUQIN_APPLY_TEST_ABORT_WRITE_AFTER": str(1024 * 1024)})
    run(["status", "--json"])
    run(["recover", "--yes-write"])
    run(["status", "--json"])

    journal = tablet.journal()
    if journal.get("phase") != "rolled_back":
        failures += 1
        transcript.append("FAIL: recovery did not end in phase rolled_back")
    summary = {
        "tool": "liuqin-apply-boot",
        "simulation": "regular files only (no block/loop device, no tablet)",
        "final_device_sha256": {
            "boot_a": tablet.device_sha(tablet.device_a),
            "boot_b": tablet.device_sha(tablet.device_b),
        },
        "final_journal_phase": journal.get("phase"),
        "backups": [str(path) for path in tablet.backups()],
        "failures": failures,
    }
    (OUT / "demo-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (OUT / "demo-transcript.log").write_text("\n".join(transcript) + "\n")
    print("\n".join(transcript[-30:]))
    print(f"\nevidence: {OUT}/{{demo-transcript.log,demo-summary.json}}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
