#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the built liuqin RPMs by installing them into a temporary root.

Runs inside the Fedora 45 builder container.  Checks:
  * every RPM can be installed with rpm --root ... --nodeps --ignorearch;
  * the firmware payload has the expected file/symlink counts and relocated
    paths, and its symlinks resolve inside the installed root;
  * the topology binary exists and its sha256 is the device-validated value;
  * UCM2 files exist;
  * device-support units/helpers exist with the expected modes, helpers are
    static aarch64 ELF, no /usr/local, GNOME or Ubuntu paths survived;
  * systemd-analyze verify reports no fatal unit problems (missing optional
    dependencies in the minimal container are recorded as warnings).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

FIRMWARE_EXPECTED_FILES = 194
FIRMWARE_EXPECTED_LINKS = 4
TOPOLOGY_SHA256 = "9c9f8bfcffde1f52c143d58cba821c5f6b3899553370ab92a88b90d81fef9ee9"

FATAL_UNIT_PATTERNS = (
    r"^Invalid",
    r"Failed to parse",
    r"Unknown (key|lvalue|section)",
    r"Failed to (load|start) unit",
    r"is not a valid unit name",
)
WARN_UNIT_PATTERNS = (
    r"not found",
    r"No such file or directory",
    r"not executable",
    r"Unit .* not loaded",
    r"Failed to (create|resolve)",
)


def run(args: list[str], check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(args, text=True, capture_output=True, check=check)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def elf_info(path: Path) -> dict:
    data = path.read_bytes()
    if data[:4] != b"\x7fELF":
        return {"elf": False}
    e_machine = struct.unpack_from("<H", data, 18)[0]
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    has_interp = has_dynamic = False
    for index in range(e_phnum):
        p_type = struct.unpack_from("<I", data, e_phoff + index * e_phentsize)[0]
        has_interp |= p_type == 3
        has_dynamic |= p_type == 2
    return {"elf": True, "machine": hex(e_machine), "aarch64": e_machine == 0xB7,
            "dynamic": has_dynamic, "interp": has_interp}


def package_file_list(rpm: Path) -> list[str]:
    result = run(["rpm", "-qpl", str(rpm)])
    if result.returncode != 0:
        raise RuntimeError(f"rpm -qpl failed for {rpm}: {result.stderr}")
    return [line for line in result.stdout.splitlines() if line]


def package_metadata(rpm: Path) -> dict:
    fmt = "%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{SIZE}\t%{LICENSE}"
    result = run(["rpm", "-qp", "--qf", fmt, str(rpm)])
    if result.returncode != 0:
        raise RuntimeError(f"rpm -qp failed for {rpm}: {result.stderr}")
    name, version, release, arch, size, license_ = result.stdout.split("\t")
    listing = run(["rpm", "-qp", "--qf", "[%{FILEMODES:perms}\\t%{FILENAMES}\\n]", str(rpm)])
    if listing.returncode != 0:
        raise RuntimeError(f"rpm file mode query failed for {rpm}: {listing.stderr}")
    regular = links = directories = 0
    fw_regular = fw_links = 0
    for line in listing.stdout.splitlines():
        if "\t" not in line:
            continue
        perms, path = line.split("\t", 1)
        if perms.startswith("l"):
            links += 1
            if path.startswith("/usr/lib/firmware/"):
                fw_links += 1
        elif perms.startswith("d"):
            directories += 1
        else:
            regular += 1
            if path.startswith("/usr/lib/firmware/"):
                fw_regular += 1
    return {"name": name, "version": version, "release": release, "arch": arch,
            "installed_size": int(size), "license": license_,
            "file_count": regular, "symlink_count": links, "directory_count": directories,
            "firmware_payload_files": fw_regular, "firmware_payload_links": fw_links}


class Checks:
    def __init__(self) -> None:
        self.items: list[dict] = []

    def add(self, check_id: str, ok: bool, detail: str = "") -> None:
        self.items.append({"id": check_id, "ok": bool(ok), "detail": detail})

    def ok(self) -> bool:
        return all(item["ok"] for item in self.items)


def verify_firmware(root: Path, checks: Checks, meta: dict) -> None:
    fw = root / "usr/lib/firmware"
    checks.add("firmware.file_count",
               meta.get("firmware_payload_files") == FIRMWARE_EXPECTED_FILES,
               f"{meta.get('firmware_payload_files')} firmware files (expected {FIRMWARE_EXPECTED_FILES})")
    checks.add("firmware.symlink_count",
               meta.get("firmware_payload_links") == FIRMWARE_EXPECTED_LINKS,
               f"{meta.get('firmware_payload_links')} firmware symlinks (expected {FIRMWARE_EXPECTED_LINKS})")
    links = [p for p in fw.rglob("*") if p.is_symlink()]
    broken = []
    for link in links:
        target = Path(os.path.normpath(link.parent / os.readlink(link)))
        try:
            target.resolve().relative_to(root.resolve())
        except (ValueError, OSError):
            broken.append(f"{link} -> {os.readlink(link)}")
            continue
        if not target.exists():
            broken.append(f"{link} -> {os.readlink(link)}")
    checks.add("firmware.symlinks_resolve", not broken, "; ".join(broken))
    required = [
        "qca/hpbtfw20.tlv", "novatek/liuqin/novatek_nt36532_m81_fw_csot.bin",
        "novatek/liuqin/novatek_nt36532_m81_fw_tm.bin",
        "qcom/sm8475/liuqin/adsp.mbn", "qcom/sm8475/liuqin/cdsp.mbn",
        "qcom/sm8475/liuqin/slpi.mbn", "qcom/sm8475/liuqin/a730_zap.mbn",
        "updates/ath11k/WCN6855/hw2.0/amss.bin.zst",
        "updates/ath11k/WCN6855/hw2.1/board.bin",
        "updates/qcom/a730_sqe.fw", "updates/qcom/gmu_gen70000.bin",
        "updates/qcom/vpu/vpu20_4v.mbn",
    ]
    missing = [item for item in required if not (fw / item).exists()]
    checks.add("firmware.required_files", not missing, "missing: " + ", ".join(missing))
    # regulatory.db/.p7s must not come from this package; the topology binary
    # IS installed at this path by liuqin-audio, so it is checked per-package
    # file list below rather than against the installed root.
    forbidden = ["regulatory.db", "regulatory.db.p7s"]
    leftovers = [item for item in forbidden if (fw / item).exists()]
    checks.add("firmware.conflict_policy", not leftovers,
               "unexpected: " + ", ".join(leftovers))
    checks.add("firmware.no_main_ath11k_tree", not (fw / "ath11k").exists(),
               "main-tree ath11k/ directory should have moved to updates/")


def verify_audio(root: Path, checks: Checks) -> None:
    topology = root / "usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin"
    checks.add("audio.topology_exists", topology.is_file(), str(topology))
    if topology.is_file():
        checks.add("audio.topology_sha256", sha256(topology) == TOPOLOGY_SHA256,
                   sha256(topology))
    ucm = root / "usr/share/alsa/ucm2"
    for rel in ("conf.d/sm8450/Xiaomi-Pad-6-Pro.conf",
                "Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf"):
        checks.add(f"audio.ucm2.{rel}", (ucm / rel).is_file(), str(ucm / rel))


def verify_device_support(root: Path, checks: Checks) -> None:
    units = root / "usr/lib/systemd/system"
    expected_units = [
        "liuqin-power-keyd.service", "liuqin-backlight-default.service",
        "liuqin-bt-preconfigure.service", "liuqin-wlan-mac.service",
        "liuqin-mipps-auth.service", "liuqin-hide-gunyah-node.service",
        "liuqin-power-keyd.service.d/20-liuqin-session-runtime.conf",
        "liuqin-mipps-battery-auth.service",
        "bluetooth.service.d/20-liuqin-public-address.conf",
        "NetworkManager.service.d/20-liuqin-wlan-mac.conf",
    ]
    missing = [u for u in expected_units if not (units / u).is_file()]
    checks.add("device.support_units", not missing, "missing: " + ", ".join(missing))
    mode_bad = []
    for unit in expected_units:
        path = units / unit
        if path.is_file() and (path.stat().st_mode & 0o777) != 0o644:
            mode_bad.append(f"{unit}:{oct(path.stat().st_mode & 0o777)}")
    checks.add("device.support_unit_modes", not mode_bad, "; ".join(mode_bad))
    execdir = root / "usr/libexec/liuqin"
    for helper in ("liuqin-power-keyd", "liuqin-reboot", "liuqin-power-key-action",
                   "liuqin-mipps-auth", "liuqin-backlight-default",
                   "liuqin-wlan-mac", "liuqin-bt-public-addr", "liuqin-switch"):
        path = execdir / helper
        checks.add(f"device.helper.{helper}", path.is_file() and os.access(path, os.X_OK),
                   f"{path} mode={oct(path.stat().st_mode & 0o777) if path.exists() else 'missing'}")
    for binary in ("liuqin-power-keyd", "liuqin-reboot"):
        info = elf_info(execdir / binary)
        checks.add(f"device.binary.{binary}",
                   bool(info.get("elf") and info.get("aarch64")
                        and not info.get("dynamic") and not info.get("interp")),
                   json.dumps(info))
    chrony_conf = root / "etc/chrony.d/00-liuqin-no-rtc.conf"
    checks.add("device.chrony_dropin", chrony_conf.is_file(),
               "etc/chrony.d/00-liuqin-no-rtc.conf")
    chrony_text = chrony_conf.read_text() if chrony_conf.is_file() else ""
    checks.add("device.chrony_includes_distro_config",
               "include /etc/chrony.conf" in chrony_text
               and "nocerttimecheck 1" in chrony_text and "authselectmode ignore" in chrony_text,
               "aggregate config includes Fedora config and no-RTC directives")
    checks.add("device.chronyd_unit_override",
               (root / "usr/lib/systemd/system/chronyd.service.d/20-liuqin-no-rtc.conf").is_file(),
               "chronyd.service drop-in")
    rules = root / "usr/lib/udev/rules.d"
    for rule in ("70-liuqin-camera-heap.rules", "70-liuqin-touchpad-external.rules",
                 "90-liuqin-mipps-auth.rules"):
        checks.add(f"device.udev.{rule}", (rules / rule).is_file(), str(rules / rule))
    polkit = root / "usr/share/polkit-1/actions/io.github.liuqin.switch.policy"
    checks.add("device.polkit_relocated",
               polkit.is_file() and "/usr/libexec/liuqin/liuqin-switch" in polkit.read_text(),
               str(polkit))
    desktop = root / "usr/share/applications/liuqin-reboot-to-android.desktop"
    checks.add("device.desktop_relocated",
               desktop.is_file()
               and "Exec=pkexec /usr/libexec/liuqin/liuqin-switch to-android" in desktop.read_text(),
               str(desktop))
    checks.add("device.no_usr_local", not _grep_tree(root, "/usr/local/"),
               "no /usr/local reference in installed payload")
    checks.add("device.no_gnome_payload",
               not any((root / rel).exists() for rel in
                       ("usr/share/gnome", "etc/dconf", "etc/gdm3", "usr/share/gdm", "etc/flash-kernel")),
               "no GNOME/Ubuntu payload directories")


SKIP_SCAN_PREFIXES = ("usr/share/licenses/", "usr/share/doc/", "usr/share/man/")


def _grep_tree(root: Path, needle: str) -> list[str]:
    hits = []
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        rel = str(path.relative_to(root))
        if rel.startswith(SKIP_SCAN_PREFIXES):
            # licence/notice texts quote upstream paths verbatim; they are not
            # executed or parsed by the system and must stay unmodified.
            continue
        if path.stat().st_size > 4 * 1024 * 1024:
            continue
        try:
            if needle in path.read_text(errors="ignore"):
                hits.append(str(path))
        except OSError:
            continue
    return hits


def systemd_verify(root: Path, units: list[str]) -> dict:
    """Offline unit syntax/dependency check with systemd-analyze.

    The units are verified from the installed temporary root by absolute path.
    ExecStart binaries and optional dependency units are not present in that
    bare root (the helper binaries live at the same paths only on the final
    image), so missing binaries/units are recorded as warnings.  Malformed
    units, unknown keys and invalid names are fatal.
    """
    unit_paths = [str(root / "usr/lib/systemd/system" / unit) for unit in units]
    command = ["systemd-analyze", "verify", "--man=no", *unit_paths]
    result = run(command)
    output = (result.stdout + result.stderr).strip()
    fatal = [line for line in output.splitlines()
             if any(re.search(pattern, line) for pattern in FATAL_UNIT_PATTERNS)]
    warnings = [line for line in output.splitlines()
                if line and not any(re.search(p, line) for p in FATAL_UNIT_PATTERNS)]
    return {"command": " ".join(command), "exit_code": result.returncode,
            "fatal": fatal, "warnings": warnings, "output": output}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--log", type=Path, default=None)
    args = parser.parse_args()

    rpms = sorted(args.out.glob("*.rpm"))
    if not rpms:
        raise SystemExit(f"no RPMs in {args.out}")
    root = Path(tempfile.mkdtemp(prefix="liuqin-rpmroot-"))
    log_lines: list[str] = []
    report: dict = {"root": str(root), "packages": {}, "checks": [], "systemd_verify": {}}
    checks = Checks()
    try:
        log_lines.append(str(run(["rpm", "--root", str(root), "--initdb"])))
        # deterministic order: firmware before audio before device-support
        order = {"liuqin-firmware": 0, "liuqin-audio": 1, "liuqin-device-support": 2}
        def order_key(path: Path) -> int:
            for name, index in order.items():
                if path.name.startswith(name + "-"):
                    return index
            return 9
        packages = [(order_key(p), p) for p in rpms]
        for _, rpm in sorted(packages, key=lambda item: (item[0], item[1].name)):
            result = run(["rpm", "--root", str(root), "--nodeps", "--ignorearch",
                          "--nosignature", "-i", str(rpm)])
            log_lines.append(f"install {rpm.name}: rc={result.returncode} {result.stderr.strip()}")
            meta = package_metadata(rpm)
            report["packages"][meta["name"]] = {
                "rpm": rpm.name,
                "sha256": sha256(rpm),
                "size_bytes": rpm.stat().st_size,
                "version": meta["version"],
                "release": meta["release"],
                "arch": meta["arch"],
                "license": meta["license"],
                "installed_size": meta["installed_size"],
                "file_list": package_file_list(rpm),
                "file_count": meta.get("file_count"),
                "symlink_count": meta.get("symlink_count"),
                "firmware_payload_files": meta.get("firmware_payload_files"),
                "firmware_payload_links": meta.get("firmware_payload_links"),
                "install_ok": result.returncode == 0,
                "install_stderr": result.stderr.strip(),
            }
        checks.add("all_rpms_installed",
                   all(pkg["install_ok"] for pkg in report["packages"].values()),
                   ", ".join(f"{name}:{pkg['install_ok']}" for name, pkg in report["packages"].items()))
        firmware_pkg = report["packages"].get("liuqin-firmware")
        if firmware_pkg:
            forbidden_owned = [item for item in firmware_pkg["file_list"]
                               if item.endswith(("/regulatory.db", "/regulatory.db.p7s",
                                                 "/Xiaomi-Pad-6-Pro-tplg.bin"))]
            checks.add("firmware.ownership_policy", not forbidden_owned,
                       "unexpected ownership: " + ", ".join(forbidden_owned))
        if "liuqin-firmware" in report["packages"]:
            verify_firmware(root, checks, report["packages"]["liuqin-firmware"])
        if "liuqin-audio" in report["packages"]:
            verify_audio(root, checks)
        if "liuqin-device-support" in report["packages"]:
            verify_device_support(root, checks)
        # no forbidden distro paths in any file list
        forbidden_paths = [item for pkg in report["packages"].values()
                           for item in pkg["file_list"]
                           if any(item.startswith(prefix) for prefix in
                                  ("/usr/share/gnome", "/etc/dconf", "/etc/gdm3", "/usr/local/"))]
        checks.add("global.no_forbidden_paths", not forbidden_paths,
                   "; ".join(forbidden_paths))
        units = ["liuqin-power-keyd.service", "liuqin-backlight-default.service",
                 "liuqin-bt-preconfigure.service", "liuqin-wlan-mac.service",
                 "liuqin-mipps-auth.service", "liuqin-hide-gunyah-node.service"]
        if "liuqin-device-support" in report["packages"]:
            summary = systemd_verify(root, units)
            report["systemd_verify"] = summary
            checks.add("systemd_analyze_verify", not summary["fatal"],
                       "fatal: " + " | ".join(summary["fatal"]))
        report["checks"] = checks.items
        report["ok"] = checks.ok()
    finally:
        shutil.rmtree(root, ignore_errors=True)
    report_path = args.out / "validation-report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    log_path = args.log or (args.out / "validation.log")
    log_path.write_text("\n".join(log_lines + ["", report["systemd_verify"].get("output", "")]) + "\n")
    for item in checks.items:
        status = "PASS" if item["ok"] else "FAIL"
        print(f"{status}  {item['id']:<40} {item['detail']}")
    print(f"validation report: {report_path}")
    return 0 if checks.ok() else 1


if __name__ == "__main__":
    raise SystemExit(main())
