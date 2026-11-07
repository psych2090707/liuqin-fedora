#!/bin/sh
# SPDX-License-Identifier: MIT
#
# diagnose.sh — basic liuqin presence/runtime checks, not hardware acceptance.
# It does not parse hardware-support.md or prove user-visible functionality.
#
# Runs ON THE TABLET (Fedora, busybox-compatible POSIX sh) or offline against a
# prepared sysroot (--root DIR) for skeleton rehearsal.  Read-only: it never
# changes configuration or partitions. It does write its report/work directory.
#
# Status semantics:
#   PASS  the check's evidence is present/healthy.
#   FAIL  the check ran and detected a real problem (remediation printed).
#   SKIP  cannot be decided here: offline sysroot, missing tool, requires a
#         running device, or a documented known gap/decision (see "known-gap").
#
# Checks whose data source is a file (firmware, units, config, sysfs trees) run
# in offline mode too; checks that need the running device are SKIPped offline.
# "requires" field: file | device | known-gap.
#
# Output: --json-out FILE (default ./diagnose-report.json) plus a human summary.
# Exit: 0 report produced (even with FAILs), 1 only with --strict and FAILs,
#       2 usage/environment error.
set -u

VERSION=1.0.1
ROOT=
MODE=auto
JSON_OUT=./diagnose-report.json
STRICT=0
TIMEOUT=20

usage() {
	cat <<'EOF'
usage: diagnose.sh [--root DIR] [--mode auto|offline|device] [--json-out FILE]
                   [--strict] [-h]

  --root DIR        offline sysroot (rootfs tree); file checks read below DIR,
                    device checks are SKIPped
  --mode MODE       auto (default): device if /proc/device-tree/model is liuqin,
                    otherwise offline
  --json-out FILE   machine-readable report (default ./diagnose-report.json)
  --strict          exit 1 if any check FAILs (for CI; default always exit 0)
  -h, --help        show help

Evidence commands are printed with each check so a report can be reproduced.
Never writes a device; no fastboot/qbootctl/partition access.
EOF
}

die() { printf 'diagnose: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
	case $1 in
	--root) ROOT=${2:-}; [ -d "$ROOT" ] || die "--root is not a directory: $ROOT"; shift 2 ;;
	--mode) MODE=${2:-}; shift 2 ;;
	--json-out) JSON_OUT=${2:-}; shift 2 ;;
	--strict) STRICT=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

rd() { printf '%s%s' "$ROOT" "$1"; }  # path under sysroot
read_first() { # rel [default]
	if [ -r "$(rd "$1")" ]; then head -n 1 "$(rd "$1")" 2>/dev/null; else printf '%s' "${2:-}"; fi
}

# --- mode detection --------------------------------------------------------
if [ -z "$ROOT" ] && [ -r /proc/device-tree/model ] &&
	grep -qi -E 'xiaomi pad 6 pro|liuqin' /proc/device-tree/model 2>/dev/null; then
	[ "$MODE" = auto ] && MODE=device
elif [ "$MODE" = auto ]; then
	MODE=offline
fi
[ "$MODE" = auto ] && MODE=offline

WORKDIR=$JSON_OUT.diagnose-tmp
rm -rf "$WORKDIR" 2>/dev/null || true
mkdir -p "$WORKDIR" || die "cannot create report work directory: $WORKDIR"
RESULTS=$WORKDIR/results.tsv
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM
printf 'id\tgroup\ttitle\trequires\tstatus\tdetail\tevidence\tremediation\n' >"$RESULTS"

add() { # id group title requires status detail evidence remediation
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" >>"$RESULTS"
}
pass() { add "${1:-}" "${2:-}" "${3:-}" "${4:-}" PASS "${5:-}" "${6:-}" ""; }
fail() { add "${1:-}" "${2:-}" "${3:-}" "${4:-}" FAIL "${5:-}" "${6:-}" "${7:-}"; }
skip() { add "${1:-}" "${2:-}" "${3:-}" "${4:-}" SKIP "${5:-}" "${6:-}" "${7:-}"; }

present() { [ -e "$(rd "$1")" ] || [ -L "$(rd "$1")" ]; }
count_dirs() { ls -1d "$(rd "$1")"/*/ 2>/dev/null | wc -l; }
count_files() { ls -1 "$(rd "$1")"/* 2>/dev/null | wc -l; }

device_skip() { # id group title detail evidence
	skip "$1" "$2" "$3" device "$4" "$5" "run on the tablet (Phase 6)"
}
file_or_device() { # id group title rel evidence remediation
	# file presence check; in device mode a missing path is a real FAIL
	if present "$4"; then
		pass "$1" "$2" "$3" file "present: $4" "$5"
	elif [ "$MODE" = device ]; then
		fail "$1" "$2" "$3" device "missing: $4" "$5" "$6"
	else
		skip "$1" "$2" "$3" file "absent in offline sysroot: $4" "$5" "check on the device"
	fi
}

# ---------------------------------------------------------------------------
# kernel / modules
# ---------------------------------------------------------------------------
kernel=$(read_first /proc/sys/kernel/osrelease unknown)
if present /proc/sys/kernel/osrelease; then
	pass kernel.osrelease kernel "kernel running: $kernel" file "cat /proc/sys/kernel/osrelease"
else
	device_skip kernel.osrelease kernel "kernel release" "offline sysroot has no /proc" "uname -r"
fi

rootfs_release=$(read_first /usr/share/liuqin/kernel.release "")
if [ -n "$rootfs_release" ] && [ "$kernel" != unknown ]; then
	if [ "$kernel" = "$rootfs_release" ]; then
		pass kernel.release_match kernel "booted kernel matches rootfs ($kernel)" file \
			"cat /usr/share/liuqin/kernel.release; uname -r"
	else
		fail kernel.release_match kernel "booted kernel '$kernel' != rootfs '$rootfs_release'" device \
			"cat /usr/share/liuqin/kernel.release; uname -r" \
			"if a kernel update was just installed: liuqin-apply-boot apply --image /boot/liuqin/boot-<kver>.img --dry-run"
	fi
elif [ -n "$rootfs_release" ]; then
	pass kernel.release_match kernel "rootfs kernel.release=$rootfs_release (booted kernel unknown offline)" file \
		"cat /usr/share/liuqin/kernel.release"
else
	skip kernel.release_match kernel "rootfs kernel.release missing" file \
		"/usr/share/liuqin/kernel.release" "install kernel-liuqin + device layer"
fi
kernel_name=$(read_first /usr/share/liuqin/kernel.release "")
if [ -n "$kernel_name" ] && present "/usr/lib/modules/$kernel_name/vmlinuz"; then
	pass kernel.modules kernel "modules tree for $kernel_name present (vmlinuz+ko)" file \
		"ls /usr/lib/modules/$kernel_name"
else
	file_or_device kernel.modules kernel "kernel modules tree + vmlinuz" \
		"/usr/lib/modules/$kernel_name/vmlinuz" "ls -l /usr/lib/modules/$kernel_name" \
		"install the matching kernel-liuqin RPM"
fi
modules_count=$(count_dirs /usr/lib/modules)
if [ "$modules_count" = 1 ]; then
	pass kernel.modules_single kernel "exactly one kernel module tree" file \
		"ls -1d /usr/lib/modules/*/"
elif [ "$modules_count" = 0 ]; then
	skip kernel.modules_single kernel "no module tree (device layer not installed?)" file \
		"ls -1d /usr/lib/modules/*/" "install kernel-liuqin"
else
	fail kernel.modules_single kernel "$modules_count kernel trees (apply-boot requires 1)" file \
		"ls -1d /usr/lib/modules/*/" "remove stale kernel trees before applying a new boot.img"
fi
cfg=
for candidate in "/boot/config-$kernel_name" "/boot/config-$kernel" /proc/config.gz; do
	[ -n "$candidate" ] || continue
	if present "$candidate"; then
		cfg=$candidate
		break
	fi
done
if [ -n "$cfg" ]; then
	if [ "$cfg" = /proc/config.gz ]; then
		config_text=$(zcat "$(rd "$cfg")" 2>/dev/null | head -n 4000)
	else
		config_text=$(head -n 4000 "$(rd "$cfg")" 2>/dev/null)
	fi
	missing=""
	for sym in CONFIG_DRM_MSM CONFIG_HID_NANOSIC CONFIG_ATH11K CONFIG_QCOM_FASTRPC; do
		printf '%s' "$config_text" | grep -q "^$sym=" || missing="$missing $sym"
	done
	if [ -z "$missing" ]; then
		pass kernel.config kernel "required kernel config symbols present" file "zcat /proc/config.gz"
	else
		fail kernel.config kernel "kernel config missing:$missing" file "zcat /proc/config.gz" \
			"rebuild kernel-liuqin with the Fedora config fragments"
	fi
else
	skip kernel.config kernel "kernel config not exposed (IKCONFIG or /boot/config)" file \
		"zcat /proc/config.gz; ls /boot/config-*" "install kernel config / enable IKCONFIG"
fi

# ---------------------------------------------------------------------------
# firmware presence (file checks; work offline too)
# ---------------------------------------------------------------------------
fw_check() { # id title path... (globs allowed expanded by caller via present checks)
	id=$1 title=$2
	shift 2
	missing=""
	for rel in "$@"; do
		present "$rel" || missing="$missing $rel"
	done
	if [ -z "$missing" ]; then
		pass "$id" firmware "$title" file "present: $*"
	else
		fail "$id" firmware "$title" file "missing:$missing" "ls /usr/lib/firmware" \
			"check the pinned upstream device/firmware pool and early initramfs"
	fi
}
fw_check firmware.touch "NT36532 touch firmware (both panel variants)" \
	/usr/lib/firmware/novatek/liuqin/novatek_nt36532_m81_fw_csot.bin \
	/usr/lib/firmware/novatek/liuqin/novatek_nt36532_m81_fw_tm.bin
fw_check firmware.wlan "ath11k WCN6855 firmware + HSP2 tuple" \
	/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0/amss.bin \
	/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0/board-2.bin \
	/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0/m3.bin \
	/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0/regdb.bin
fw_check firmware.bt "QCA6490 Bluetooth firmware" \
	/usr/lib/firmware/qca/hpbtfw20.tlv /usr/lib/firmware/qca/hpnv20.bin
fw_check firmware.dsp "SM8475 ADSP/CDSP/SLPI + Adreno zap" \
	/usr/lib/firmware/qcom/sm8475/liuqin/adsp.mbn \
	/usr/lib/firmware/qcom/sm8475/liuqin/cdsp.mbn \
	/usr/lib/firmware/qcom/sm8475/liuqin/slpi.mbn \
	/usr/lib/firmware/qcom/sm8475/liuqin/a730_zap.mbn
fw_check firmware.gpu "Adreno 730 SQE/GMU" \
	/usr/lib/firmware/updates/qcom/a730_sqe.fw \
	/usr/lib/firmware/updates/qcom/gmu_gen70000.bin
fw_check firmware.vpu "VPU (Iris2 decode) firmware" \
	/usr/lib/firmware/updates/qcom/vpu/vpu20_4v.mbn
fw_check firmware.topology "AudioReach topology (project-built)" \
	/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin
if present /usr/lib/firmware/regulatory.db; then
	pass firmware.regulatory firmware "regulatory.db present" file "ls /usr/lib/firmware/regulatory.db*"
else
	fail firmware.regulatory firmware "regulatory.db missing" file \
		"no regulatory.db in /usr/lib/firmware" "ls /usr/lib/firmware/regulatory.db*" \
		"install wireless-regdb (or liuqin-firmware's pinned copy)"
fi
# Fedora ships these in the cirrus-audio-firmware subpackage, xz-compressed
# (F44/F45 both provide the same generic bytes).
cs35_dsp=0
for base in cirrus/cs35l41-dsp1-spk-prot.wmfw cirrus/cs35l41-dsp1-spk-prot.bin; do
	for candidate in "$base" "$base.xz" "$base.zst" "$base.gz"; do
		if present "/usr/lib/firmware/$candidate"; then
			cs35_dsp=$((cs35_dsp + 1))
			break
		fi
	done
done
if [ "$cs35_dsp" = 2 ]; then
	pass firmware.cs35l41_dsp firmware \
		"CS35L41 protection DSP firmware present (cirrus-audio-firmware)" file \
		"ls /usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot*; rpm -q cirrus-audio-firmware"
else
	if [ "$MODE" = device ]; then
		fail firmware.cs35l41_dsp firmware \
			"CS35L41 protection DSP firmware missing ($cs35_dsp/2)" device \
			"ls /usr/lib/firmware/cirrus/; rpm -q cirrus-audio-firmware" \
			"install cirrus-audio-firmware (Fedora F44/F45) — speakers fail-closed without it"
	else
		skip firmware.cs35l41_dsp firmware \
			"CS35L41 generic firmware not in this offline sysroot" file \
			"ls /usr/lib/firmware/cirrus/; rpm -q cirrus-audio-firmware" \
			"expected in a Fedora 44/45 rootfs via cirrus-audio-firmware"
	fi
fi
calr=0
for ch in TL TR BL BR; do
	present "/usr/lib/firmware/cirrus/cs35l41-liuqin-$ch-calr.bin" && calr=$((calr + 1))
done
if [ "$calr" = 4 ]; then
	pass firmware.cs35l41_calr firmware "per-device CS35L41 calibration provisioned (4 channels)" file \
		"ls /usr/lib/firmware/cirrus/cs35l41-liuqin-*-calr.bin"
else
	skip firmware.cs35l41_calr firmware "per-device calibration incomplete ($calr/4); not proof of silence" device \
		"ls /usr/lib/firmware/cirrus/cs35l41-liuqin-*-calr.bin" \
		"do not re-provision automatically"
fi
if [ "$MODE" = device ]; then
	out=$(timeout "$TIMEOUT" sh -c 'dmesg 2>/dev/null | grep -i -E "failed to load firmware|direct firmware load" | head -n 20' 2>/dev/null)
	if [ -z "$out" ]; then
		pass firmware.load_errors firmware "no firmware load errors in dmesg" device \
			"dmesg | grep -i 'failed to load firmware'"
	else
		fail firmware.load_errors firmware "firmware load errors detected" device \
			"dmesg | grep -i 'failed to load firmware'" "see journal; verify paths with 'ls /usr/lib/firmware'"
	fi
else
	device_skip firmware.load_errors firmware "firmware load errors (dmesg)" \
		"offline mode" "dmesg | grep -i 'failed to load firmware'"
fi

# ---------------------------------------------------------------------------
# systemd services
# ---------------------------------------------------------------------------
if [ -d "$(rd /run/systemd/system)" ] && [ "$MODE" = device ]; then
	failed=$(timeout "$TIMEOUT" systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
	if [ "$failed" = 0 ]; then
		pass services.failed services "no failed systemd units" device "systemctl --failed"
	else
		fail services.failed services "$failed failed systemd units" device "systemctl --failed" \
			"systemctl status <unit>; collect-logs.sh"
	fi
	service_check() { # id title unit
		state=$(timeout "$TIMEOUT" systemctl is-active "$3" 2>/dev/null)
		if [ "$state" = active ]; then
			pass "$1" services "$2 active" device "systemctl is-active $3"
		else
			fail "$1" services "$2 not active ($state)" device "systemctl is-active $3" \
				"systemctl status $3; journalctl -b -u $3"
		fi
	}
	# Keep the legacy report id for consumers, but follow the selected manager.
	service_check services.sddm "selected display manager" display-manager
	service_check services.networkmanager "NetworkManager" NetworkManager
	service_check services.bluetooth "BlueZ" bluetooth
	# Fedora audio daemons are user services, not system services.
	for unit in pipewire wireplumber; do
		if timeout "$TIMEOUT" systemctl --user is-active --quiet "$unit" 2>/dev/null; then
			pass "services.$unit" services "$unit user service active" device "systemctl --user is-active $unit"
		else
			skip "services.$unit" services "$unit user state unavailable/inactive in this caller session" device \
				"systemctl --user status $unit" "check as the active desktop user, not the root system manager"
		fi
	done
	if present /etc/liuqin-slpi-disabled; then
		skip services.iio_sensor_proxy services "sensors intentionally disabled (SLPI reset workaround)" known-gap \
			"/etc/liuqin-slpi-disabled present" "preserve the marker; do not start SLPI"
	else
		service_check services.iio_sensor_proxy "iio-sensor-proxy" iio-sensor-proxy
	fi
else
	for item in \
		"services.sddm|display manager|/etc/systemd/system/display-manager.service|systemctl is-active display-manager" \
		"services.networkmanager|NetworkManager|/usr/lib/systemd/system/NetworkManager.service|systemctl is-active NetworkManager" \
		"services.bluetooth|BlueZ|/usr/lib/systemd/system/bluetooth.service|systemctl is-active bluetooth" \
		"services.iio_sensor_proxy|iio-sensor-proxy|/usr/lib/systemd/system/iio-sensor-proxy.service|systemctl is-active iio-sensor-proxy"; do
		id=${item%%|*}
		rest=${item#*|}
		title=${rest%%|*}
		rest=${rest#*|}
		unitfile=${rest%%|*}
		cmd=${rest#*|}
		if present "$unitfile"; then
			pass "$id" services "$title unit present (active state needs a running device)" file "ls -l $unitfile"
		elif [ "$MODE" = device ]; then
			fail "$id" services "$title unit missing" device "ls -l $unitfile" "reinstall the device layer RPM"
		else
			skip "$id" services "$title unit missing in offline rootfs" file "ls -l $unitfile" \
				"install the device layer in the image"
		fi
	done
	for unit in pipewire wireplumber; do
		if present "/usr/lib/systemd/user/$unit.service"; then
			pass "services.$unit" services "$unit user unit present (runtime unverified)" file \
				"ls /usr/lib/systemd/user/$unit.service"
		else
			skip "services.$unit" services "$unit user unit absent in this sysroot" file \
				"ls /usr/lib/systemd/user/$unit.service" "check the selected desktop package set"
		fi
	done
fi
if present /etc/liuqin-slpi-disabled; then
	skip services.sensor_stack services "sensor stack intentionally disabled" known-gap \
		"/etc/liuqin-slpi-disabled present" "preserve the reset workaround; do not enable SLPI"
elif present /usr/lib/systemd/system/liuqin-slpi.service &&
	present /usr/lib/systemd/system/liuqin-hexagonrpcd-sdsp.service; then
	pass services.sensor_stack services "sensor stack units present (SLPI + hexagonrpcd)" file \
		"ls /usr/lib/systemd/system/liuqin-*sensor* /usr/lib/systemd/system/liuqin-slpi.service"
else
	fail services.sensor_stack services "sensor stack units missing" file \
		"liuqin-slpi.service / liuqin-hexagonrpcd-sdsp.service missing" \
		"rpm -q liuqin-sensors-support" "install liuqin-sensors-support"
fi

# ---------------------------------------------------------------------------
# input devices (sysfs names; file-checkable, device-only realistically)
# ---------------------------------------------------------------------------
input_names=$(cat "$(rd /sys/class/input)"/*/name 2>/dev/null || true)
input_check() { # id title pattern evidence
	if printf '%s' "$input_names" | grep -q -E "$3"; then
		pass "$1" input "$2 detected" file "cat /sys/class/input/*/name"
	elif [ "$MODE" = device ]; then
		fail "$1" input "$2 not detected" device "cat /sys/class/input/*/name /proc/bus/input/devices" \
			"check kernel driver/module, dmesg and the DT node"
	else
		skip "$1" input "$2 (needs device input subsystem)" device "cat /sys/class/input/*/name" \
			"run diagnose on the tablet"
	fi
}
input_check input.touch "touchscreen (NVT-ts/novatek)" 'NVT-ts|Novatek|novatek'
input_check input.keyboard "magnetic keyboard (Xiaomi Keyboard/nanosic)" 'Xiaomi Keyboard|nanosic|WN8030'
input_check input.touchpad "keyboard touchpad (Xiaomi Touch)" 'Xiaomi Touch'
input_check input.powerkey "power key (pmic_pwrkey)" 'pmic_pwrkey'
input_check input.hall "hall switches / gpio-keys" 'gpio-keys|hall'

# ---------------------------------------------------------------------------
# audio
# ---------------------------------------------------------------------------
if present /proc/asound/cards; then
	if grep -q -E 'sm8450|Xiaomi' "$(rd /proc/asound/cards)" 2>/dev/null; then
		pass audio.card audio "ALSA card sm8450 / Xiaomi-Pad-6-Pro present" file "cat /proc/asound/cards"
	else
		fail audio.card audio "ALSA card not found" file "cat /proc/asound/cards" \
			"check dmesg for sc8280xp/sndcard probe; kernel/DT config"
	fi
elif [ "$MODE" = device ]; then
	fail audio.card audio "no /proc/asound/cards" device "cat /proc/asound/cards" "kernel sound stack missing"
else
	device_skip audio.card audio "ALSA card" "offline mode" "cat /proc/asound/cards"
fi
if present /usr/share/alsa/ucm2/conf.d/sm8450/Xiaomi-Pad-6-Pro.conf &&
	present /usr/share/alsa/ucm2/Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf; then
	pass audio.ucm audio "UCM2 profile present" file "ls /usr/share/alsa/ucm2/conf.d/sm8450/"
else
	fail audio.ucm audio "UCM2 profile missing" file "no UCM2 conf for Xiaomi-Pad-6-Pro" \
		"rpm -q liuqin-audio" "install liuqin-audio"
fi
if [ "$MODE" = device ]; then
	if timeout "$TIMEOUT" systemctl --user is-active --quiet pipewire 2>/dev/null; then
		pass audio.pipewire audio "PipeWire user service active" device "systemctl --user is-active pipewire"
	else
		skip audio.pipewire audio "PipeWire user state unavailable/inactive in this caller session" device \
			"systemctl --user status pipewire" "check the active desktop user's bus; system-manager inactivity is not audio failure"
	fi
else
	device_skip audio.pipewire audio "PipeWire/WirePlumber runtime" "offline mode" "systemctl --user is-active pipewire"
fi

# ---------------------------------------------------------------------------
# network / bluetooth
# ---------------------------------------------------------------------------
if present /sys/class/net/wlan0; then
	pass network.wlan_device network "wlan0 interface exists" file "ls /sys/class/net/"
else
	file_or_device network.wlan_device network "wlan0 interface" /sys/class/net/wlan0 \
		"ls /sys/class/net/" "check firmware + dmesg ath11k; NetworkManager"
fi
if present /var/lib/liuqin-private/wlan-mac; then
	pass network.mac_provisioned network "WLAN MAC provisioned from persist" file \
		"cat /var/lib/liuqin-private/wlan-mac"
elif [ "$MODE" = device ]; then
	fail network.mac_provisioned network "WLAN MAC not provisioned" device \
		"ls /var/lib/liuqin-private/" "re-run persist provisioning (install/collect-logs)"
else
	skip network.mac_provisioned network "WLAN MAC is per-device (needs persist provisioning)" device \
		"ls /var/lib/liuqin-private/" "provision on the tablet"
fi
if present /sys/class/bluetooth/hci0; then
	pass network.bt_hci network "hci0 present" file "ls /sys/class/bluetooth/"
else
	file_or_device network.bt_hci network "Bluetooth hci0" /sys/class/bluetooth/hci0 \
		"ls /sys/class/bluetooth/" "check qca BT firmware + liuqin-bt-preconfigure.service"
fi
if present /var/lib/liuqin-private/bluetooth-address; then
	pass network.bt_address_provisioned network "Bluetooth address provisioned" file \
		"cat /var/lib/liuqin-private/bluetooth-address"
else
	skip network.bt_address_provisioned network "Bluetooth address is per-device" device \
		"ls /var/lib/liuqin-private/" "provision on the tablet"
fi

# ---------------------------------------------------------------------------
# power / charging
# ---------------------------------------------------------------------------
file_or_device power.battery power "battery (qcom-battmgr-bat)" \
	/sys/class/power_supply/qcom-battmgr-bat "cat /sys/class/power_supply/*/uevent" \
	"check kernel qcom_battmgr + ADSP firmware"
file_or_device power.usb_charger power "USB charger (qcom-battmgr-usb)" \
	/sys/class/power_supply/qcom-battmgr-usb "cat /sys/class/power_supply/*/uevent" \
	"check pmic-glink/charger firmware"
if present /usr/lib/systemd/system/liuqin-mipps-auth.service; then
	pass power.mipps_unit power "MiPPS charger-auth unit present" file \
		"ls /usr/lib/systemd/system/liuqin-mipps-auth.service"
else
	fail power.mipps_unit power "MiPPS auth unit missing" file "rpm -q liuqin-device-support" \
		"install liuqin-device-support"
fi
if present /usr/lib/systemd/logind.conf.d/90-liuqin.conf; then
	pass power.powerkey_policy power "logind power-key handoff configured" file \
		"cat /usr/lib/systemd/logind.conf.d/90-liuqin.conf"
else
	fail power.powerkey_policy power "power-key handoff drop-in missing" file \
		"ls /usr/lib/systemd/logind.conf.d/" "install liuqin-device-support"
fi
skip power.powerdevil_decision power "power-key ownership needs selected desktop policy" known-gap \
	"current GNOME uses the custom policy; the native action is nothing" \
	"read /etc/liuqin/power-policy.conf; do not apply old KDE defaults"

# ---------------------------------------------------------------------------
# sensors / rotation
# ---------------------------------------------------------------------------
iio_count=$(ls -1d "$(rd /sys/bus/iio/devices)"/iio:device* 2>/dev/null | wc -l)
if present /etc/liuqin-slpi-disabled; then
	skip sensors.iio sensors "SLPI intentionally disabled; IIO absence expected" known-gap \
		"/etc/liuqin-slpi-disabled present" "preserve the reset workaround; do not start SLPI"
elif [ "$iio_count" -gt 0 ]; then
	pass sensors.iio sensors "$iio_count IIO device(s) present" file "ls /sys/bus/iio/devices/"
elif [ "$MODE" = device ]; then
	fail sensors.iio sensors "no IIO devices" device "ls /sys/bus/iio/devices/" \
		"check hexagonrpcd/SLPI/iio-sensor-proxy; journalctl -b -u iio-sensor-proxy"
else
	skip sensors.iio sensors "IIO devices (needs SSC/SLPI runtime)" device "ls /sys/bus/iio/devices/" \
		"run on the tablet"
fi
registry=$(count_files /var/lib/liuqin-sensors/registry)
if [ "$registry" -gt 100 ]; then
	pass sensors.registry sensors "SSC sensor registry provisioned ($registry files)" file \
		"ls /var/lib/liuqin-sensors/registry | wc -l"
elif present /etc/liuqin-slpi-disabled; then
	skip sensors.registry sensors "SSC registry not required for the disabled sensor path" known-gap \
		"/etc/liuqin-slpi-disabled present" "do not re-provision or start SLPI to satisfy this check"
elif [ "$MODE" = device ]; then
	fail sensors.registry sensors "SSC sensor registry missing/short ($registry files)" device \
		"ls /var/lib/liuqin-sensors/registry | wc -l" "re-run persist provisioning"
else
	skip sensors.registry sensors "registry is per-device (needs persist provisioning)" device \
		"ls /var/lib/liuqin-sensors/registry | wc -l" "provision on the tablet"
fi
if present /etc/liuqin/power-policy.conf || present /usr/share/wayland-sessions/gnome.desktop; then
	skip sensors.rotation_config sensors "legacy KWin rotation configuration not applicable to GNOME" known-gap \
		"GNOME session/config present" "do not restore KDE to satisfy this check"
elif present /var/lib/plasmalogin/.config/kwinoutputconfig.json; then
	if grep -q 'autoRotation' "$(rd /var/lib/plasmalogin/.config/kwinoutputconfig.json)" 2>/dev/null; then
		pass sensors.rotation_config sensors "KWin autoRotation configured" file \
			"cat /var/lib/plasmalogin/.config/kwinoutputconfig.json"
	else
		fail sensors.rotation_config sensors "autoRotation missing in KWin config" file \
			"cat /var/lib/plasmalogin/.config/kwinoutputconfig.json" "fix kwinoutputconfig"
	fi
else
	skip sensors.rotation_config sensors "KWin output config not found" file \
		"ls /var/lib/plasmalogin/.config/" "login as the desktop user once (greeter config is baked)"
fi

# ---------------------------------------------------------------------------
# fingerprint runtime presence (enrollment still requires device acceptance), camera, usb/dp
# ---------------------------------------------------------------------------
if present /usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2 && \
   present /usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so; then
	pass fingerprint.libfprint_tod fingerprint "Private TOD library and adapter installed (not an enrollment result)" file \
		"rpm -q libfprint-tod liuqin-fpc1264-tod"
else
	skip fingerprint.libfprint_tod fingerprint "Private TOD runtime not installed" file \
		"install the source-built libfprint-tod and liuqin-fpc1264-tod RPMs" \
		"no TOD ABI port is required"
fi
if present /dev/fpc1020; then
	pass fingerprint.device fingerprint "FPC1264 device node visible" file "ls -l /dev/fpc* /sys/bus/spi/devices/"
else
	skip fingerprint.device fingerprint "FPC1264 device node (needs kernel TEE/QSEECOM + DT)" device \
		"no /dev/fpc1020 in offline sysroot" "ls -l /dev/fpc* /sys/bus/spi/devices/" \
		"run on the tablet after kernel boot"
fi
if present /usr/lib/systemd/system/fprintd.service; then
	pass fingerprint.fprintd_unit fingerprint "fprintd unit present" file "ls /usr/lib/systemd/system/fprintd.service"
else
	skip fingerprint.fprintd_unit fingerprint "fprintd unit not installed" file "rpm -q fprintd" \
		"install fprintd and the matching private TOD runtime"
fi
if present /dev/video0; then
	pass camera.video_devices camera "video device present (rear camera, experimental)" file "ls -l /dev/video*"
else
	skip camera.video_devices camera "camera is experimental upstream (no AF/calibration)" known-gap \
		"upstream support is experimental; front camera unsupported" "ls -l /dev/video*" \
		"see the kernel notes in kernel/README.md"
fi
file_or_device usbdp.typec usb-dp "USB-C typec port (UCSI)" /sys/class/typec/port0 \
	"ls /sys/class/typec/" "check pmic-glink/UCSI + dwc3"
if present /sys/class/drm/card0-DP-1/status; then
	status=$(read_first /sys/class/drm/card0-DP-1/status unknown)
	if [ "$status" = connected ]; then
		pass usbdp.dp_status usb-dp "DP output connected" device "cat /sys/class/drm/card0-DP-1/status"
	else
		skip usbdp.dp_status usb-dp "DP output status=$status (no external display)" device \
			"cat /sys/class/drm/card0-DP-1/status" "attach a DP adapter and re-run"
	fi
else
	skip usbdp.dp_status usb-dp "DP connector not exposed" device "ls /sys/class/drm/" \
		"check QMP combo PHY/altmode on the tablet"
fi
skip usbdp.dp_audio usb-dp "DP audio / high refresh (upstream unverified)" known-gap \
	"upstream v0.6.0 only verified picture + recovery" "phase-6 manual test"

# ---------------------------------------------------------------------------
# boot / update / security / storage / gpu / known gaps
# ---------------------------------------------------------------------------
staged=$(ls -1 "$(rd /boot/liuqin)"/*.img 2>/dev/null | wc -l)
if [ "$staged" -gt 0 ]; then
	pass boot.staged_images boot "$staged staged boot image(s) under /boot/liuqin" file \
		"ls -l /boot/liuqin/*.img; liuqin-apply-boot status --json"
else
	skip boot.staged_images boot "no staged boot image" file "ls -l /boot/liuqin/" \
		"no staged image is required for diagnostics; read kernel/fedora/README.kernel-liuqin before updating"
fi
if present /boot/liuqin/apply-state.json; then
	phase=$(sed -n 's/.*"phase": "\([^"]*\)".*/\1/p' "$(rd /boot/liuqin/apply-state.json)" 2>/dev/null | head -n 1)
	if [ "$phase" = applied ] || [ "$phase" = rolled_back ]; then
		pass boot.apply_journal boot "apply-boot journal phase=$phase" file "cat /boot/liuqin/apply-state.json"
	else
		fail boot.apply_journal boot "apply-boot journal phase=$phase (incomplete apply)" file \
			"the last apply did not finish (phase=$phase)" \
			"cat /boot/liuqin/apply-state.json" "liuqin-apply-boot recover --yes-write"
	fi
else
	skip boot.apply_journal boot "no apply-boot journal yet" file "cat /boot/liuqin/apply-state.json" \
		"no update applied since install"
fi
# boot tool stack installed? (kernel-liuqin + liuqin-boot-tools RPMs)
if present /usr/libexec/liuqin/boot-assets; then
	pass boot.boot_assets boot "boot-assets installed (on-device boot rebuild assets)" file \
		"ls -l /usr/libexec/liuqin/boot-assets"
else
	file_or_device boot.boot_assets boot "boot-assets directory" /usr/libexec/liuqin/boot-assets \
		"ls -l /usr/libexec/liuqin/" "install liuqin-boot-tools (boot-assets RPM)"
fi
if present /usr/libexec/liuqin/liuqin-bootimg-refresh; then
	pass boot.refresh_tool boot "liuqin-bootimg-refresh present (kernel update pipeline)" file \
		"ls -l /usr/libexec/liuqin/liuqin-bootimg-refresh"
else
	file_or_device boot.refresh_tool boot "liuqin-bootimg-refresh" \
		/usr/libexec/liuqin/liuqin-bootimg-refresh "ls -l /usr/libexec/liuqin/" \
		"install kernel-liuqin (ships liuqin-bootimg-refresh)"
fi
if present /usr/sbin/liuqin-apply-boot; then
	pass boot.apply_tool boot "liuqin-apply-boot present" file "ls -l /usr/sbin/liuqin-apply-boot"
else
	file_or_device boot.apply_tool boot "liuqin-apply-boot" /usr/sbin/liuqin-apply-boot \
		"ls -l /usr/sbin/liuqin-apply-boot" "install kernel-liuqin"
fi
if present /dev/disk/by-partlabel/boot_a; then
	pass boot.boot_partition boot "boot_a partition label present" device "ls -l /dev/disk/by-partlabel/boot_a"
else
	file_or_device boot.boot_partition boot "boot_a partition label" /dev/disk/by-partlabel/boot_a \
		"ls -l /dev/disk/by-partlabel/" "check the UFS GPT (boot_a/boot_b on the separate boot GPT)"
fi
selinux=$(read_first /etc/selinux/config disabled)
if grep -qi '^SELINUX=enforcing' "$(rd /etc/selinux/config)" 2>/dev/null; then
	pass security.selinux security "SELinux enforcing" file "getenforce"
elif grep -qi '^SELINUX=permissive' "$(rd /etc/selinux/config)" 2>/dev/null; then
	pass security.selinux security "SELinux permissive (first-release decision, ADR-0002)" file "getenforce"
elif grep -qi '^SELINUX=disabled' "$(rd /etc/selinux/config)" 2>/dev/null; then
	skip security.selinux security \
		"SELinux still disabled: rebuild pending (decision: permissive, ADR-0002 addendum)" known-gap \
		"etc/selinux/config: SELINUX=disabled" \
		"rebuild the rootfs/image with SELINUX=permissive"
else
	fail security.selinux security "SELinux config missing/unparseable" file "cat /etc/selinux/config" \
		"restore /etc/selinux/config (permissive for first release)"
fi
if present /etc/fstab; then
	# Keep the legacy id. Root is mounted by initramfs; UUID and rootless fstab
	# layouts are valid too. Presence is not a mount-identity/partition test.
	pass storage.root_label storage "fstab present (root resolution belongs to initramfs)" file "cat /etc/fstab"
else
	fail storage.root_label storage "fstab missing" file \
		"/etc/fstab missing" "ls -l /etc/fstab; findmnt /" \
		"check the current layout; do not restore the old separate-home template"
fi
if [ -d "$(rd /sys/class/drm/card0)" ]; then
	pass gpu.adreno gpu "DRM card0 present (Adreno 730/freedreno)" file "ls /sys/class/drm/"
else
	file_or_device gpu.adreno gpu "DRM card0" /sys/class/drm/card0 "ls /sys/class/drm/" \
		"check kernel msm/adreno + firmware z"
fi
skip gaps.front_camera gaps "front camera unsupported upstream" known-gap \
	"upstream v0.6.0 enables rear camera only" "no action (document only)"
skip gaps.auto_brightness gaps "automatic brightness unsupported upstream" known-gap \
	"no ambient-light integration in v0.6.0" "no action (document only)"
skip gaps.stylus gaps "stylus unverified upstream" known-gap "NVTCapacitivePen untested" "phase-6 manual test"
skip gaps.suspend gaps "deep sleep / peripheral resume unverified" known-gap \
	"upstream suspend partially verified" "phase-6 manual test"
skip gaps.rtc gaps "RTC retention pending (HLOS cannot write RTC)" known-gap \
	"chrony no-RTC bootstrap configured" "phase-6 manual test"
skip gaps.waydroid gaps "Waydroid experimental/not ported" known-gap \
	"kernel config present but Fedora packaging not done" "not in first release"
skip gaps.wifi_ap gaps "Wi-Fi AP mode pending" known-gap "upstream AP untested" "phase-6 manual test"
skip gaps.dp_audio gaps "DP audio / high refresh pending" known-gap "upstream unverified" "phase-6 manual test"

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t\n' '  '
}
pass_n=$(awk -F'\t' 'NR > 1 && $5 == "PASS" {c++} END {print c+0}' "$RESULTS")
fail_n=$(awk -F'\t' 'NR > 1 && $5 == "FAIL" {c++} END {print c+0}' "$RESULTS")
skip_n=$(awk -F'\t' 'NR > 1 && $5 == "SKIP" {c++} END {print c+0}' "$RESULTS")
total=$((pass_n + fail_n + skip_n))
kgap_n=$(awk -F'\t' 'NR > 1 && $5 == "SKIP" && $4 == "known-gap" {c++} END {print c+0}' "$RESULTS")

mkdir -p "$(dirname "$JSON_OUT")" 2>/dev/null || true
tmp_json=$WORKDIR/report.json
{
	printf '{\n'
	printf '  "schema_version": 1,\n'
	printf '  "tool": "diagnose.sh",\n  "version": "%s",\n' "$VERSION"
	printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf '  "mode": "%s",\n  "root": "%s",\n' "$MODE" "$(json_escape "${ROOT:-/}")"
	printf '  "host": {"kernel": "%s", "model": "%s"},\n' \
		"$(json_escape "$(read_first /proc/sys/kernel/osrelease unknown)")" \
		"$(json_escape "$(read_first /proc/device-tree/model unknown)")"
	printf '  "summary": {"total": %s, "pass": %s, "fail": %s, "skip": %s, "known_gaps": %s, "by_group": {' \
		"$total" "$pass_n" "$fail_n" "$skip_n" "$kgap_n"
	first=1
	for group in kernel firmware services input audio network power sensors fingerprint camera usb-dp boot security storage gpu gaps; do
		[ "$first" = 1 ] || printf ', '
		first=0
		printf '"%s": {' "$group"
		for status in PASS FAIL SKIP; do
			n=$(awk -F'\t' -v g="$group" -v s="$status" 'NR > 1 && $2 == g && $5 == s {c++} END {print c+0}' "$RESULTS")
			[ "$status" = PASS ] && printf '"pass": %s, ' "$n"
			[ "$status" = FAIL ] && printf '"fail": %s, ' "$n"
			[ "$status" = SKIP ] && printf '"skip": %s' "$n"
		done
		printf '}'
	done
	printf '}},\n  "checks": [\n'
	first=1
	awk -F'\t' 'NR > 1' "$RESULTS" | while IFS='	' read -r id group title requires status detail evidence remediation; do
		[ "$first" = 1 ] || printf ',\n'
		first=0
		printf '    {"id": "%s", "group": "%s", "title": "%s", "requires": "%s", "status": "%s", "detail": "%s", "evidence": "%s", "remediation": "%s"}' \
			"$(json_escape "$id")" "$(json_escape "$group")" "$(json_escape "$title")" \
			"$(json_escape "$requires")" "$(json_escape "$status")" "$(json_escape "$detail")" \
			"$(json_escape "$evidence")" "$(json_escape "$remediation")"
	done
	printf '\n  ],\n'
	printf '  "known_gaps": [\n'
	first=1
	awk -F'\t' 'NR > 1 && $5 == "SKIP" && $4 == "known-gap" {print $1 "\t" $3 "\t" $6}' "$RESULTS" |
		while IFS='	' read -r id title detail; do
			[ "$first" = 1 ] || printf ',\n'
			first=0
			printf '    {"id": "%s", "title": "%s", "detail": "%s"}' \
				"$(json_escape "$id")" "$(json_escape "$title")" "$(json_escape "$detail")"
		done
	printf '\n  ],\n'
	printf '  "hardware_support_ref": "docs/hardware-support.md",\n'
	printf '  "checklist_ref": "device validation checklist"\n'
	printf '}\n'
} >"$tmp_json" || die "cannot write JSON report"
mv "$tmp_json" "$JSON_OUT" || die "cannot write JSON report to $JSON_OUT"

printf '\nliuqin diagnose %s  (mode=%s root=%s)\n' "$VERSION" "$MODE" "${ROOT:-/}"
printf 'summary: %s PASS / %s FAIL / %s SKIP (%s known gaps)\n\n' "$pass_n" "$fail_n" "$skip_n" "$kgap_n"
for group in kernel firmware services input audio network power sensors fingerprint camera usb-dp boot security storage gpu gaps; do
	n=$(awk -F'\t' -v g="$group" 'NR > 1 && $2 == g {c++} END {print c+0}' "$RESULTS")
	[ "$n" -gt 0 ] || continue
	p=$(awk -F'\t' -v g="$group" 'NR > 1 && $2 == g && $5 == "PASS" {c++} END {print c+0}' "$RESULTS")
	f=$(awk -F'\t' -v g="$group" 'NR > 1 && $2 == g && $5 == "FAIL" {c++} END {print c+0}' "$RESULTS")
	s=$(awk -F'\t' -v g="$group" 'NR > 1 && $2 == g && $5 == "SKIP" {c++} END {print c+0}' "$RESULTS")
	printf '  %-10s PASS=%-2s FAIL=%-2s SKIP=%-2s\n' "$group" "$p" "$f" "$s"
	if [ "$f" -gt 0 ]; then
		awk -F'\t' -v g="$group" 'NR > 1 && $2 == g && $5 == "FAIL" {printf "      FAIL %-28s %s\n        evidence: %s\n        fix: %s\n", $1, $6, $7, $8}' "$RESULTS"
	fi
done
if [ "$fail_n" -gt 0 ]; then
	printf '\nNext steps for FAIL items:\n'
	awk -F'\t' 'NR > 1 && $5 == "FAIL" {printf "  %s: %s\n    %s\n", $1, $6, ($8 == "" ? "see docs/hardware-support.md" : $8)}' "$RESULTS"
	printf 'Then collect evidence: tools/collect-logs.sh --full --label diagnose-failures\n'
else
	printf '\nNo FAIL items. Known gaps/decisions are listed as SKIP known-gap in the JSON report.\n'
fi
printf 'JSON report: %s\n' "$JSON_OUT"

if [ "$STRICT" = 1 ] && [ "$fail_n" -gt 0 ]; then
	exit 1
fi
exit 0
