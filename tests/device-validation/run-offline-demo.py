#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproducible offline demo for tools/collect-logs.sh and tools/diagnose.sh.

Builds a synthetic liuqin sysroot + fake command outputs (same fixtures as
tests/device-validation/test-tools.py) under out/device-validation/ and runs:

  * diagnose.sh on the healthy fixture  -> diagnose-healthy.json
  * diagnose.sh on the broken fixture   -> diagnose-broken.json
  * collect-logs.sh with fake command data -> liuqin-logs-<ts>-offline-demo.tar.gz

The output proves the scripts run, produce valid JSON/bundles and that sensitive
values are redacted.  It is NOT device evidence: no tablet, block device, loop
device, fastboot or qbootctl is used.

Run: python3 tests/device-validation/run-offline-demo.py
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
PROJECT = TESTS.parents[1]
OUT = PROJECT / "out/device-validation"


def load_tests():
    spec = importlib.util.spec_from_file_location(
        "liuqin_device_validation_tests", TESTS / "test-tools.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run(args, timeout=300):
    return subprocess.run([str(a) for a in args], text=True, capture_output=True,
                          timeout=timeout, cwd=str(PROJECT))


def main() -> int:
    tests = load_tests()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    work = OUT / "fixtures"
    (work / "healthy").mkdir(parents=True)
    (work / "broken").mkdir(parents=True)
    tests.build_sysroot(work / "healthy")
    tests.build_sysroot(work / "broken", broken=True)
    fakes = tests.build_fake_commands(OUT / "fake-commands")

    transcript = []
    transcript.append("offline demo for tools/collect-logs.sh + tools/diagnose.sh")
    transcript.append(f"project: {PROJECT}")
    transcript.append("synthetic sysroots under out/device-validation/fixtures/ "
                      "(no device/block device/loop device is used)")

    healthy_report = OUT / "diagnose-healthy.json"
    result = run(["sh", PROJECT / "tools/diagnose.sh", "--root",
                  work / "healthy", "--json-out", healthy_report])
    transcript.append(f"diagnose healthy: exit={result.returncode}")
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    healthy = json.loads(healthy_report.read_text())

    broken_report = OUT / "diagnose-broken.json"
    result = run(["sh", PROJECT / "tools/diagnose.sh", "--root",
                  work / "broken", "--json-out", broken_report])
    transcript.append(f"diagnose broken: exit={result.returncode}")
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    broken = json.loads(broken_report.read_text())

    collect = run(["sh", PROJECT / "tools/collect-logs.sh", "--quick",
                   "--root", work / "healthy", "--fake-cmd-dir", fakes,
                   "--out", OUT, "--label", "offline-demo"])
    transcript.append(f"collect-logs: exit={collect.returncode}")
    if collect.returncode != 0:
        print(collect.stderr, file=sys.stderr)
        return collect.returncode
    tarball = sorted(OUT.glob("*.tar.gz"))[-1]
    summary_file = tarball.with_name(tarball.name.replace(".tar.gz", ".summary.txt"))
    summary = summary_file.read_text() if summary_file.is_file() else ""
    secrets_leaked = [secret for secret in
                      ("HomeSecretSSID", "SuperSecretPW", "AA:BB:CC:DD:EE:FF",
                       "SECRETSERIAL123", "secretuser", "secret-host")
                      if secret in summary]
    transcript.append(f"bundle: {tarball.name}")
    transcript.append(f"redaction: {'enabled, no synthetic secrets in summary' if not secrets_leaked else 'LEAK: ' + str(secrets_leaked)}")

    demo_summary = {
        "synthetic": True,
        "note": "offline fixtures only; not device evidence",
        "diagnose_healthy": {
            "total": healthy["summary"]["total"],
            "pass": healthy["summary"]["pass"],
            "fail": healthy["summary"]["fail"],
            "skip": healthy["summary"]["skip"],
            "known_gaps": healthy["summary"]["known_gaps"],
        },
        "diagnose_broken": {
            "total": broken["summary"]["total"],
            "pass": broken["summary"]["pass"],
            "fail": broken["summary"]["fail"],
            "skip": broken["summary"]["skip"],
            "fail_ids": [c["id"] for c in broken["checks"] if c["status"] == "FAIL"],
        },
        "collect_logs_bundle": str(tarball),
        "secrets_leaked_in_summary": secrets_leaked,
    }
    (OUT / "demo-summary.json").write_text(json.dumps(demo_summary, indent=2) + "\n")
    transcript.append("")
    transcript.append("healthy: %d checks, PASS=%d FAIL=%d SKIP=%d known_gaps=%d" % (
        healthy["summary"]["total"], healthy["summary"]["pass"],
        healthy["summary"]["fail"], healthy["summary"]["skip"],
        healthy["summary"]["known_gaps"]))
    transcript.append("broken:  FAIL ids = %s" % ", ".join(demo_summary["diagnose_broken"]["fail_ids"]))
    (OUT / "demo-transcript.log").write_text("\n".join(transcript) + "\n")
    print("\n".join(transcript))
    return 0 if not secrets_leaked else 1


if __name__ == "__main__":
    raise SystemExit(main())
