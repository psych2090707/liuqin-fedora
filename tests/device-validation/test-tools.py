#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for tools/collect-logs.sh and tools/diagnose.sh.

Everything runs against synthetic sysroots under a temporary directory (and,
for the skeleton test, a chroot of the qemu-validated aarch64 rootfs in
out/rootfs/rootfs).  No device, block device, fastboot or qbootctl is used.

Covered:
  * shell syntax under /bin/sh and, when present, the project's static busybox
    aarch64 (`busybox sh -n`);
  * collect-logs --root skeleton bundle + SUMMARY + tar layout;
  * collect-logs redaction with fake command outputs containing hostname/user/
    serial/MAC/SSID/PSK/fingerprint paths (and --no-redact behaviour);
  * diagnose healthy sysroot => 0 FAIL, expected PASS count and known-gap SKIPs;
  * diagnose broken sysroot => expected FAIL ids, remediation text, JSON schema;
  * diagnose/report JSON validity;
  * chroot skeleton run of both scripts inside out/rootfs/rootfs (aarch64 via
    qemu-user binfmt) => exit 0, reports produced, expected offline SKIPs.

Run: python3 tests/device-validation/test-tools.py
The legacy chroot tests write into a retained rootfs and are opt-in only:
LIUQIN_TEST_CHROOT=1 (after reviewing that exact rootfs path). No full-system VM.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
COLLECT = PROJECT / "tools/collect-logs.sh"
DIAGNOSE = PROJECT / "tools/diagnose.sh"
ROOTFS = PROJECT / "out/rootfs/rootfs"
BUSYBOX = PROJECT / "out/boot/toolchain/busybox-1.36.1-aarch64-static"

FW_FILES = [
    "novatek/liuqin/novatek_nt36532_m81_fw_csot.bin",
    "novatek/liuqin/novatek_nt36532_m81_fw_tm.bin",
    "updates/ath11k/WCN6855/hw2.0/amss.bin",
    "updates/ath11k/WCN6855/hw2.0/board-2.bin",
    "updates/ath11k/WCN6855/hw2.0/m3.bin",
    "updates/ath11k/WCN6855/hw2.0/regdb.bin",
    "qca/hpbtfw20.tlv", "qca/hpnv20.bin",
    "qcom/sm8475/liuqin/adsp.mbn", "qcom/sm8475/liuqin/cdsp.mbn",
    "qcom/sm8475/liuqin/slpi.mbn", "qcom/sm8475/liuqin/a730_zap.mbn",
    "updates/qcom/a730_sqe.fw", "updates/qcom/gmu_gen70000.bin",
    "updates/qcom/vpu/vpu20_4v.mbn",
    "qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin",
    "regulatory.db",
]

UNITS = [
    "NetworkManager.service", "bluetooth.service", "pipewire.service",
    "iio-sensor-proxy.service", "liuqin-mipps-auth.service",
    "liuqin-slpi.service", "liuqin-hexagonrpcd-sdsp.service",
    "fprintd.service", "liuqin-power-keyd.service",
]

INPUT_NAMES = {
    "event0": "NVT-ts",
    "event1": "Xiaomi Keyboard",
    "event2": "Xiaomi Touch",
    "event3": "pmic_pwrkey",
    "event4": "gpio-keys",
}


def write(path: Path, content: str = "x\n") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def build_sysroot(root: Path, *, broken: bool = False) -> Path:
    """Synthetic offline syroot mirroring a provisioned liuqin installation."""
    os.makedirs(root, exist_ok=True)
    write(root / "etc/os-release", 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=44\n')
    write(root / "etc/fedora-release", "Fedora release 44 (Forty Four)\n")
    write(root / "etc/hostname", "secret-host\n")
    write(root / "etc/passwd",
          "root:x:0:0:root:/root:/bin/bash\n"
          "secretuser:x:1000:1000:Dev User:/home/secretuser:/bin/bash\n")
    write(root / "etc/fstab", "LABEL=LIUQIN_ROOT / ext4 defaults 0 1\n")
    write(root / "etc/selinux/config", "SELINUX=disabled\nSELINUXTYPE=targeted\n")
    write(root / "proc/sys/kernel/osrelease", "6.17.0-test\n")
    write(root / "proc/cmdline",
          "BOOT_IMAGE=/vmlinuz root=LABEL=LIUQIN_ROOT androidboot.serialno=SECRETSERIAL123\n")
    write(root / "usr/share/liuqin/kernel.release", "6.17.0-test\n")
    write(root / "usr/lib/modules/6.17.0-test/vmlinuz", "kernel\n")
    write(root / "boot/config-6.17.0-test",
          "CONFIG_DRM_MSM=y\nCONFIG_HID_NANOSIC=y\nCONFIG_ATH11K=m\nCONFIG_QCOM_FASTRPC=y\n")
    for rel in FW_FILES:
        if broken and rel.endswith("novatek_nt36532_m81_fw_csot.bin"):
            continue
        write(root / "usr/lib/firmware" / rel, "fw\n")
    if broken:
        (root / "usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin").unlink()
    write(root / "usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot.wmfw.xz", "wmfw\n")
    write(root / "usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot.bin.xz", "bin\n")
    for unit in UNITS:
        if broken and unit.startswith("liuqin-slpi"):
            continue
        write(root / "usr/lib/systemd/system" / unit, "[Unit]\nDescription=test\n")
    if broken:
        (root / "usr/lib/systemd/system/liuqin-hexagonrpcd-sdsp.service").unlink()
    write(root / "etc/systemd/system/display-manager.service", "[Unit]\nDescription=dm\n")
    write(root / "usr/lib/systemd/logind.conf.d/90-liuqin.conf", "[Login]\nHandlePowerKey=ignore\n")
    for event, name in INPUT_NAMES.items():
        write(root / "sys/class/input" / event / "name", name + "\n")
    write(root / "proc/asound/cards", " 0 [XiaomiPad6Pro]: sm8450 - Xiaomi Pad 6 Pro\n")
    write(root / "usr/share/alsa/ucm2/conf.d/sm8450/Xiaomi-Pad-6-Pro.conf", "Syntax 3\n")
    write(root / "usr/share/alsa/ucm2/Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf", "SectionVerb {}\n")
    write(root / "sys/class/net/wlan0/address", "02:00:00:00:00:01\n")
    write(root / "sys/class/bluetooth/hci0/address", "02:00:00:00:00:02\n")
    write(root / "var/lib/liuqin-private/wlan-mac", "02:00:00:00:00:01\n")
    write(root / "var/lib/liuqin-private/bluetooth-address", "02:00:00:00:00:02\n")
    write(root / "sys/class/power_supply/qcom-battmgr-bat/uevent", "POWER_SUPPLY_CAPACITY=80\n")
    write(root / "sys/class/power_supply/qcom-battmgr-usb/uevent", "POWER_SUPPLY_ONLINE=1\n")
    write(root / "sys/bus/iio/devices/iio:device0/name", "ssc-accel\n")
    for i in range(101):
        write(root / "var/lib/liuqin-sensors/registry" / f"registry-{i:03d}.json", "{}\n")
    write(root / "var/lib/plasmalogin/.config/kwinoutputconfig.json",
          '{"outputs":[{"name":"DSI-1","autoRotation":"InTabletMode"}]}\n')
    write(root / "sys/class/typec/port0/data_role", "host\n")
    write(root / "sys/class/drm/card0/device/uevent", "DRIVER=msm\n")
    write(root / "sys/class/drm/card0-DP-1/status", "connected\n")
    write(root / "dev/video0", "video\n")
    write(root / "dev/disk/by-partlabel/boot_a", "block\n")
    write(root / "boot/liuqin/boot-6.17.0-test.img", "ANDROID!" + "0" * 100)
    if broken:
        write(root / "boot/liuqin/apply-state.json", '{"phase": "writing"}\n')
    else:
        write(root / "boot/liuqin/apply-state.json", '{"phase": "applied"}\n')
    if broken:
        (root / "etc/fstab").unlink()
        (root / "usr/share/alsa/ucm2/conf.d/sm8450/Xiaomi-Pad-6-Pro.conf").unlink()
        (root / "usr/share/alsa/ucm2/Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf").unlink()
    return root


def build_fake_commands(directory: Path) -> Path:
    os.makedirs(directory, exist_ok=True)
    (directory / "dmesg.out").write_text(
        "ath11k: firmware ready, MAC AA:BB:CC:DD:EE:FF\n"
        "serial SECRETSERIAL123 in cmdline\n"
        "direct firmware load for qcom/test.bin failed\n")
    (directory / "dmesg-firmware.out").write_text(
        "ath11k: MAC AA:BB:CC:DD:EE:FF\n")
    (directory / "nmcli-wifi.out").write_text(
        "yes:80:WPA2\nno:61:WPA2\n")
    (directory / "iw-dev.out").write_text(
        "phy#0\n\tInterface wlan0\n\t\tSSID: HomeSecretSSID\n")
    (directory / "journal-warnings.out").write_text(
        "user secretuser logged in on host secret-host\n"
        "wpa-psk=SuperSecretPW\n")
    (directory / "apply-boot-status.out").write_text(
        '{"journal": {"phase": "applied"}, "tool": "liuqin-apply-boot"}\n')
    (directory / "fingerprint-files.out").write_text(
        "/var/lib/liuqin-fingerprint/templates/tpl-secretuser.bin\n")
    (directory / "lsusb.out").write_text("Bus 001 Device 002: 05c6:9025\n")
    return directory


def run(*args, timeout=180, **kwargs):
    return subprocess.run([*map(str, args)], text=True, capture_output=True,
                          timeout=timeout, **kwargs)


class ShellTests(unittest.TestCase):
    def test_posix_syntax(self):
        for script in (COLLECT, DIAGNOSE):
            result = run("sh", "-n", script)
            self.assertEqual(result.returncode, 0, f"{script}: {result.stderr}")

    @unittest.skipUnless(BUSYBOX.is_file(), "project static busybox not built")
    def test_busybox_syntax(self):
        for script in (COLLECT, DIAGNOSE):
            result = run(BUSYBOX, "sh", "-n", script, timeout=120)
            self.assertEqual(result.returncode, 0,
                             f"busybox sh -n {script}: {result.stderr}")


class CollectLogsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="liuqin-collect-test-")
        self.root = Path(self.tmp.name)
        self.sysroot = build_sysroot(self.root / "sysroot")
        self.fakes = build_fake_commands(self.root / "fakes")
        self.out = self.root / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def test_bundle_and_redaction(self):
        result = run("sh", COLLECT, "--quick", "--root", self.sysroot,
                     "--fake-cmd-dir", self.fakes, "--out", self.out,
                     "--label", "redaction-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        tarballs = list(self.out.glob("*.tar.gz"))
        self.assertEqual(len(tarballs), 1)
        work = self.root / "extract"
        work.mkdir()
        with tarfile.open(tarballs[0]) as tar:
            tar.extractall(work)
        content = b"".join(p.read_bytes() for p in work.rglob("*") if p.is_file()).decode(
            "utf-8", "replace")
        for secret in ("HomeSecretSSID", "SuperSecretPW", "AA:BB:CC:DD:EE:FF",
                       "SECRETSERIAL123", "secretuser", "secret-host",
                       "liuqin-fingerprint/templates/tpl"):
            self.assertNotIn(secret, content, f"secret leaked: {secret}")
        for placeholder in ("<redacted-mac>", "<redacted-ssid>",
                            "<redacted-secret>", "<fingerprint-data>"):
            self.assertIn(placeholder, content, f"missing placeholder {placeholder}")
        self.assertIn("redaction: enabled", content)
        self.assertIn("skipped", content)
        summaries = list(self.out.glob("*.summary.txt"))
        self.assertEqual(len(summaries), 1)

    def test_no_redact_keeps_values(self):
        result = run("sh", COLLECT, "--quick", "--root", self.sysroot,
                     "--fake-cmd-dir", self.fakes, "--out", self.out,
                     "--label", "raw", "--no-redact")
        self.assertEqual(result.returncode, 0, result.stderr)
        tarball = next(self.out.glob("*.tar.gz"))
        work = self.root / "extract-raw"
        work.mkdir()
        with tarfile.open(tarball) as tar:
            tar.extractall(work)
        content = b"".join(p.read_bytes() for p in work.rglob("*") if p.is_file()).decode(
            "utf-8", "replace")
        self.assertIn("HomeSecretSSID", content)
        self.assertIn("--no-redact requested", content)

    def test_missing_root_fails_usage(self):
        result = run("sh", COLLECT, "--root", self.root / "does-not-exist")
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_full_is_passive_for_sensors_and_accepts_compressed_firmware(self):
        result = run("sh", COLLECT, "--full", "--root", self.sysroot,
                     "--out", self.out, "--label", "passive")
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(next(self.out.glob("*.tar.gz"))) as archive:
            files = {member.name: archive.extractfile(member).read().decode()
                     for member in archive.getmembers() if member.isfile()}
        commands = next(text for name, text in files.items() if name.endswith("commands.tsv"))
        self.assertIn("sensor-active-probes\tsensors\tSKIP", commands)
        self.assertNotIn("kscreen-display", commands)
        inventory = next(text for name, text in files.items() if name.endswith("firmware-files.txt"))
        self.assertIn("PRESENT-COMPRESSED cirrus/cs35l41-dsp1-spk-prot.wmfw", inventory)
        # Guard against reintroducing active sensor claims/samples or Wi-Fi scans.
        source = COLLECT.read_text()
        self.assertNotIn("run_cmd monitor-sensors", source)
        self.assertNotIn("run_cmd ssccli", source)
        self.assertNotIn("in_accel_x_raw", source)
        self.assertIn("device wifi list --rescan no", source)


class DiagnoseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="liuqin-diagnose-test-")
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_diagnose(self, sysroot: Path, name: str):
        report = self.root / f"{name}.json"
        result = run("sh", DIAGNOSE, "--root", sysroot,
                     "--json-out", report)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(report.read_text())
        return result, data

    def test_healthy_sysroot(self):
        sysroot = build_sysroot(self.root / "healthy")
        result, data = self.run_diagnose(sysroot, "healthy")
        self.assertEqual(data["summary"]["fail"], 0,
                          [c for c in data["checks"] if c["status"] == "FAIL"])
        self.assertGreaterEqual(data["summary"]["pass"], 30,
                                data["summary"])
        ids = {c["id"]: c for c in data["checks"]}
        # Missing TOD is an absent file, not an unimplemented/blocked ABI.
        self.assertEqual(ids["fingerprint.libfprint_tod"]["status"], "SKIP")
        self.assertEqual(ids["fingerprint.libfprint_tod"]["requires"], "file")
        for known in ("security.selinux", "gaps.front_camera"):
            self.assertEqual(ids[known]["status"], "SKIP", known)
            self.assertEqual(ids[known]["requires"], "known-gap", known)
        self.assertGreaterEqual(len(data["known_gaps"]), 9)
        self.assertIn("summary:", result.stdout)
        self.assertIn("JSON report:", result.stdout)
        groups = data["summary"]["by_group"]
        self.assertGreater(groups["firmware"]["pass"], 0)
        self.assertGreater(groups["services"]["pass"], 0)

    def test_broken_sysroot_fails_with_remediation(self):
        sysroot = build_sysroot(self.root / "broken", broken=True)
        _, data = self.run_diagnose(sysroot, "broken")
        ids = {c["id"]: c for c in data["checks"]}
        expected_fail = {
            "firmware.touch", "firmware.topology", "audio.ucm",
            "services.sensor_stack", "boot.apply_journal", "storage.root_label",
        }
        actual_fail = {cid for cid, c in ids.items() if c["status"] == "FAIL"}
        missing = expected_fail - actual_fail
        self.assertFalse(missing, f"expected FAIL ids missing: {missing}; got {sorted(actual_fail)}")
        for cid in expected_fail:
            self.assertTrue(ids[cid]["remediation"], f"{cid} has no remediation")
        self.assertGreater(data["summary"]["fail"], 0)

    def test_known_gap_and_offline_reasons(self):
        sysroot = build_sysroot(self.root / "healthy2")
        _, data = self.run_diagnose(sysroot, "healthy2")
        offline_skips = [c for c in data["checks"]
                         if c["status"] == "SKIP" and c["requires"] == "device"]
        self.assertGreaterEqual(len(offline_skips), 4)
        self.assertTrue(all(c["detail"] for c in offline_skips))

    def test_gnome_disabled_sensor_path(self):
        sysroot = build_sysroot(self.root / "gnome", broken=True)
        write(sysroot / "etc/liuqin-slpi-disabled", "")
        write(sysroot / "etc/liuqin/power-policy.conf", "power_short=blank\n")
        write(sysroot / "etc/fstab", "UUID=example / ext4 defaults 0 1\n")
        write(sysroot / "usr/lib/systemd/user/pipewire.service", "[Unit]\n")
        shutil.rmtree(sysroot / "var/lib/liuqin-sensors/registry")
        shutil.rmtree(sysroot / "sys/bus/iio/devices")
        shutil.rmtree(sysroot / "var/lib/plasmalogin")
        _, data = self.run_diagnose(sysroot, "gnome")
        ids = {c["id"]: c for c in data["checks"]}
        for cid in ("services.sensor_stack", "sensors.iio", "sensors.registry",
                    "sensors.rotation_config", "firmware.cs35l41_calr"):
            self.assertEqual(ids[cid]["status"], "SKIP", ids[cid])
        self.assertEqual(ids["services.pipewire"]["status"], "PASS")
        self.assertEqual(ids["storage.root_label"]["status"], "PASS")

    def test_runtime_checks_use_user_audio_and_skip_disabled_sensors(self):
        sysroot = build_sysroot(self.root / "runtime")
        write(sysroot / "etc/liuqin-slpi-disabled", "")
        write(sysroot / "etc/liuqin/power-policy.conf", "power_short=blank\n")
        (sysroot / "run/systemd/system").mkdir(parents=True)
        commands = self.root / "commands"
        commands.mkdir()
        log = self.root / "systemctl.log"
        write(commands / "systemctl", '#!/bin/sh\nprintf "%s\\n" "$*" >>"$TEST_CALLS"\n'
              'case "$*" in --failed*) exit 0;; *is-active*) echo active; exit 0;; *) exit 1;; esac\n')
        write(commands / "dmesg", "#!/bin/sh\nexit 0\n")
        for script in commands.iterdir():
            script.chmod(0o755)
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"], TEST_CALLS=str(log))
        report = self.root / "runtime.json"
        result = run("sh", DIAGNOSE, "--root", sysroot, "--mode", "device",
                     "--json-out", report, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        ids = {c["id"]: c for c in json.loads(report.read_text())["checks"]}
        for cid in ("services.sddm", "services.pipewire", "services.wireplumber", "audio.pipewire"):
            self.assertEqual(ids[cid]["status"], "PASS", ids[cid])
        self.assertEqual(ids["services.iio_sensor_proxy"]["status"], "SKIP")
        calls = log.read_text()
        self.assertIn("--user is-active --quiet pipewire", calls)
        self.assertIn("is-active display-manager", calls)
        self.assertNotIn("is-active plasmalogin", calls)
        self.assertNotIn("is-active iio-sensor-proxy", calls)


class AfkAuditTests(unittest.TestCase):
    """Run command bodies with mocked helpers: no SSH, sudo or network setup."""

    def test_doctor_does_not_require_kde(self):
        source = (PROJECT / "tools/afk/afk.sh").read_text().split(
            "# --------------------------------------------------------------------- main ---")[0]
        source = source.replace('. "$AFK_TOOLS_DIR/lib/common.sh"', "# helpers mocked below")
        source = "\n".join('AFK_TOOLS_DIR=/nonexistent-fixture' if line.startswith('AFK_TOOLS_DIR=') else line
                           for line in source.splitlines())
        with tempfile.TemporaryDirectory(prefix="liuqin-afk-audit-") as directory:
            key = Path(directory) / "fake-key"
            key.touch()
            mocks = r'''
AFK_SSH_KEY=$1 AFK_HOST_IP=192.0.2.10 AFK_DEV_HOST=192.0.2.2
afk_state_init() { :; }
section() { :; }
ok() { :; }
say() { echo "$*"; }
warn() { echo "$*"; }
err() { echo "$*"; }
note() { :; }
have_cmd() { return 0; }
afk_detect_iface() { echo fake-usb; }
iface_addr4() { echo 192.0.2.10/24; }
port_open() { [ "$2" = 22 ]; }
ssh_run() {
  case "$2" in
    *krdp*|*plasmalogin*|*Plasma*) return 1 ;;
    *version*) echo mock-version ;;
    *addr*) echo 192.0.2.2/24 ;;
    *afk-health*) return 1 ;;
    *) return 0 ;;
  esac
}
cmd_doctor
'''
            result = run("bash", "-c", source + mocks, "audit", key)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("failures: 0", result.stdout)

    def test_retired_commands_fail_without_remote_work(self):
        source = (PROJECT / "tools/afk/afk.sh").read_text().split(
            "# --------------------------------------------------------------------- main ---")[0]
        source = source.replace('. "$AFK_TOOLS_DIR/lib/common.sh"', "# no real helpers")
        source = "\n".join('AFK_TOOLS_DIR=/nonexistent-fixture' if line.startswith('AFK_TOOLS_DIR=') else line
                           for line in source.splitlines())
        for command in ("cmd_shot", "cmd_rdp"):
            result = run("bash", "-c", source + '\ndie() { echo "$*" >&2; exit 1; }\n' + command)
            self.assertEqual(result.returncode, 1)
            self.assertIn("retired", result.stderr)

    def test_no_host_network_reload_in_offline_check(self):
        source = (PROJECT / "tools/afk/tests/offline-check.sh").read_text()
        self.assertNotIn("nmcli general reload", source)
        source = (PROJECT / "tools/afk/afk.sh").read_text()
        setup = source.split("cmd_setup() {", 1)[1].split("# ------------------------------------------------------------------------ up", 1)[0]
        self.assertNotIn("build-overlay.sh", setup)


@unittest.skipUnless(os.environ.get("LIUQIN_TEST_CHROOT") == "1" and ROOTFS.is_dir(),
                     "legacy retained-rootfs writes require explicit LIUQIN_TEST_CHROOT=1")
class ChrootSkeletonTests(unittest.TestCase):
    """Run both scripts inside the qemu-validated aarch64 rootfs (read-only-ish)."""

    @classmethod
    def setUpClass(cls):
        probe = run("sudo", "-n", "chroot", ROOTFS, "/bin/sh", "-c",
                    "echo ok >/dev/null", timeout=120)
        if probe.returncode != 0:
            raise unittest.SkipTest(f"chroot/qemu-user unavailable: {probe.stderr}")
        cls.dir = tempfile.mkdtemp(prefix="liuqin-chroot-tools-")
        # Unique per process: parallel test runs (CI + agent) must not clobber
        # each other's staging directory inside the shared rootfs.
        cls.work = ROOTFS / f"var/tmp/liuqin-tools-test-{os.getpid()}"
        run("sudo", "-n", "rm", "-rf", cls.work)
        run("sudo", "-n", "mkdir", "-p", cls.work)
        for script in (COLLECT, DIAGNOSE):
            run("sudo", "-n", "cp", script, cls.work / script.name)
        # Fake every command the collector may run: inside the chroot each
        # aarch64 command goes through qemu-user, and rpm/systemctl/journalctl
        # would make the skeleton test take minutes.  File collectors still run
        # against the real rootfs, so POSIX/busybox compatibility is exercised.
        import re as _re
        ids = sorted(set(_re.findall(r"\brun_cmd\s+([a-z0-9-]+)", COLLECT.read_text())))
        fakes_host = Path(cls.dir) / "fakes"
        fakes_host.mkdir(parents=True, exist_ok=True)
        for cid in ids:
            (fakes_host / f"{cid}.out").write_text("")
        run("sudo", "-n", "mkdir", "-p", cls.work / "fakes")
        for fake in fakes_host.iterdir():
            run("sudo", "-n", "cp", fake, cls.work / "fakes" / fake.name)
        cls.work_rel = "/" + str(cls.work.relative_to(ROOTFS))

    @classmethod
    def tearDownClass(cls):
        run("sudo", "-n", "rm", "-rf", cls.work)
        shutil.rmtree(cls.dir, ignore_errors=True)

    def test_collect_logs_in_rootfs(self):
        result = run("sudo", "-n", "chroot", ROOTFS, "/bin/sh", "-c",
                     f"{self.work_rel}/collect-logs.sh --quick --out {self.work_rel}/out "
                     f"--label chroot --fake-cmd-dir {self.work_rel}/fakes", timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        listing = run("sudo", "-n", "chroot", ROOTFS, "/bin/sh", "-c",
                      f"ls {self.work_rel}/out/*.tar.gz", timeout=60)
        self.assertIn("liuqin-logs-", listing.stdout)
        cat = run("sudo", "-n", "chroot", ROOTFS, "/bin/sh", "-c",
                  f"cat {self.work_rel}/out/*.summary.txt", timeout=60)
        self.assertIn("redaction: enabled", cat.stdout)
        self.assertIn("sysroot: / (running system)", cat.stdout)

    def test_diagnose_in_rootfs(self):
        result = run("sudo", "-n", "chroot", ROOTFS, "/bin/sh", "-c",
                     f"{self.work_rel}/diagnose.sh --json-out {self.work_rel}/diagnose.json",
                     timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        cat = run("sudo", "-n", "chroot", ROOTFS, "/bin/sh", "-c",
                  f"cat {self.work_rel}/diagnose.json", timeout=60)
        data = json.loads(cat.stdout)
        self.assertEqual(data["mode"], "offline")
        self.assertGreater(len(data["checks"]), 40)
        self.assertGreater(len(data["known_gaps"]), 5)
        statuses = {c["status"] for c in data["checks"]}
        self.assertTrue({"PASS", "FAIL", "SKIP"} & statuses)


if __name__ == "__main__":
    unittest.main(verbosity=2)
