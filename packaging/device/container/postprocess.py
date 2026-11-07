#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Container-side post-processing after rpmbuild.

  * runs verify-install.py (temporary-root install + payload assertions);
  * writes SHA256SUMS for the RPMs;
  * creates the local dnf repository with createrepo_c;
  * writes build-info.json combining host build inputs, container toolchain
    versions, per-package metadata and the validation summary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_version(*args: str) -> str:
    try:
        result = subprocess.run(args, text=True, capture_output=True, check=False)
    except OSError:
        return "unavailable"
    text = (result.stdout or result.stderr).splitlines()
    return text[0] if text else "unavailable"


def os_release() -> dict:
    data = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key] = value.strip().strip('"')
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    work, out = args.work, args.out

    rpms = sorted(out.glob("*.rpm"))
    if not rpms:
        raise SystemExit(f"no RPMs in {out}")

    validation_rc = subprocess.run(
        [sys.executable, str(work / "scripts/verify-install.py"), "--out", str(out)],
        check=False)
    report_path = out / "validation-report.json"
    validation = json.loads(report_path.read_text()) if report_path.is_file() else {
        "ok": False, "checks": [], "packages": {}, "systemd_verify": {}}
    if validation_rc.returncode != 0 or not validation.get("ok"):
        print("WARNING: install validation reported failures", file=sys.stderr)

    # SHA256SUMS over the RPMs only (repo metadata is generated afterwards).
    lines = []
    for rpm in rpms:
        lines.append(f"{sha256(rpm)}  {rpm.name}")
    (out / "SHA256SUMS").write_text("\n".join(sorted(lines)) + "\n")

    repo = subprocess.run(["createrepo_c", "--quiet", "--no-database", str(out)],
                          text=True, capture_output=True, check=False)
    if repo.returncode != 0:
        print(f"createrepo_c failed: {repo.stderr}", file=sys.stderr)
        return 1

    host_inputs = json.loads((work / "build-inputs.json").read_text())
    packages = []
    for rpm in rpms:
        meta = validation.get("packages", {}).get(_rpm_name(rpm), {})
        packages.append({
            "rpm": rpm.name,
            "sha256": sha256(rpm),
            "size_bytes": rpm.stat().st_size,
            "name": meta.get("name", _rpm_name(rpm)),
            "version": meta.get("version", ""),
            "release": meta.get("release", ""),
            "arch": meta.get("arch", "aarch64"),
            "license": meta.get("license", ""),
            "installed_size": meta.get("installed_size", 0),
            "file_count": len(meta.get("file_list", [])),
            "validation": {
                "install_ok": meta.get("install_ok", False),
                "install_stderr": meta.get("install_stderr", ""),
            },
        })

    checks = validation.get("checks", [])
    info = {
        "schema_version": 1,
        "kind": "liuqin-device-rpms-build-info",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "package_version": host_inputs.get("package_version"),
        "source_date_epoch": host_inputs.get("source_date_epoch"),
        "upstream_project": host_inputs.get("upstream_project"),
        "upstream_kernel": host_inputs.get("upstream_kernel"),
        "host_build_inputs": {
            "toolchain": host_inputs.get("toolchain"),
            "jobs": host_inputs.get("jobs"),
        },
        "builder": {
            "os_release": os_release(),
            "kernel": platform.release(),
            "machine": platform.machine(),
            "rpmbuild": command_version("rpmbuild", "--version"),
            "systemd": command_version("systemd-analyze", "--version"),
            "m4": command_version("m4", "--version"),
            "alsatplg": command_version("alsatplg", "-v"),
            "git": command_version("git", "--version"),
            "createrepo_c": command_version("createrepo_c", "--version"),
            "python3": platform.python_version(),
        },
        "sources": host_inputs.get("sources", {}),
        "packages": packages,
        "validation_summary": {
            "ok": bool(validation.get("ok")),
            "checks_total": len(checks),
            "checks_failed": [check["id"] for check in checks if not check["ok"]],
            "root_install": {name: pkg.get("install_ok")
                             for name, pkg in validation.get("packages", {}).items()},
            "systemd_analyze_verify": {
                "exit_code": validation.get("systemd_verify", {}).get("exit_code"),
                "fatal": validation.get("systemd_verify", {}).get("fatal", []),
                "warnings": len(validation.get("systemd_verify", {}).get("warnings", [])),
            },
        },
        "licensing": {
            "liuqin-firmware": "Proprietary vendor firmware -- LOCAL PRIVATE BUILD, not redistributable",
            "liuqin-audio": "BSD-3-Clause AND MIT",
            "liuqin-device-support": "MIT AND GPL-2.0-only",
        },
    }
    (out / "build-info.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
    print(f"build-info.json written: {len(packages)} packages, validation ok={info['validation_summary']['ok']}")
    if not info["validation_summary"]["ok"]:
        print("ERROR: install validation failed; see validation-report.json", file=sys.stderr)
        return 1
    return 0


def _rpm_name(rpm: Path) -> str:
    result = subprocess.run(["rpm", "-qp", "--qf", "%{NAME}", str(rpm)],
                            text=True, capture_output=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else rpm.name


if __name__ == "__main__":
    raise SystemExit(main())
