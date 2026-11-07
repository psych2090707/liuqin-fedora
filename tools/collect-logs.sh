#!/bin/sh
# SPDX-License-Identifier: MIT
#
# collect-logs.sh — collect liuqin device diagnostics for verification/reporting.
#
# Designed to run ON THE TABLET (Fedora, busybox-compatible POSIX sh) and also
# offline against a prepared sysroot (--root DIR) for rehearsing the procedure.
# It never changes configuration/partitions or calls fastboot/qbootctl.
# It writes temporary reports and archives. Permission/missing-tool errors are
# evidence, not proof of a broken device; no sensor activation is attempted.
#
# Output: <out>/liuqin-logs-<timestamp>[-<label>].tar.gz containing the raw
# command outputs plus SUMMARY.txt, and a sibling *.summary.txt.  Sensitive
# values (hostname, user names, serial numbers, MAC/BSSID/Bluetooth addresses,
# Wi-Fi SSIDs, Wi-Fi PSKs/passwords, fingerprint template paths) are redacted
# by default BEFORE packaging.  SSID is omitted from the wifi scan command by
# design (the list still shows signal/security/BSSID[redacted]).
#
# Usage:
#   tools/collect-logs.sh [--quick|--full] [--out DIR] [--label NAME]
#                         [--root DIR] [--no-redact] [-h]
#
#   --quick  default: boot/kernel/services/firmware summary, warning+ journal
#   --full   also full current-boot journal, lsusb -v, rpm -qa, libinput list,
#            upower -d, passive sensor inventory, staged boot image hashes
#   --root   offline mode: read files below DIR; device commands are skipped
#            (unless the test-only --fake-cmd-dir supplies canned outputs)
#   --no-redact  DANGER: keep raw values; only for an already-private host
#
# Exit: 0 logs collected (some items may be SKIPped), 1 cannot write output,
#       2 usage error.
set -u

VERSION=1.0.1
MODE=quick
OUT_BASE=${LIUQIN_LOGS_OUT:-/var/tmp/liuqin-logs}
ROOT=
FAKE_CMD_DIR=
REDACT=1
LABEL=
KEEP_WORK=0
CAP_QUICK=4000000
CAP_FULL=40000000

usage() {
	cat <<'EOF'
usage: collect-logs.sh [--quick|--full] [--out DIR] [--label NAME]
                       [--root DIR] [--no-redact] [-h]

  --quick          default: kernel/firmware/services summary, warning+ journal
  --full           full journal, lsusb -v, rpm -qa, libinput/upower/inventory
  --out DIR        output directory (default $LIUQIN_LOGS_OUT or /var/tmp/liuqin-logs)
  --label NAME     suffix for the tarball name (e.g. V2-first-boot)
  --root DIR       offline sysroot (device commands are skipped)
  --no-redact      DANGER: package raw values (only on a private host)
  -h, --help       show this help

Redaction (default on): hostname, user names, serials, MAC/BSSID/BT addresses,
Wi-Fi SSID/PSK/passwords, fingerprint template paths.
EOF
}

die() { printf 'collect-logs: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
	case $1 in
	--quick) MODE=quick; shift ;;
	--full) MODE=full; shift ;;
	--out) OUT_BASE=${2:-}; [ -n "$OUT_BASE" ] || die "--out needs a value" 2; shift 2 ;;
	--label) LABEL=${2:-}; shift 2 ;;
	--root) ROOT=${2:-}; [ -d "$ROOT" ] || die "--root is not a directory: $ROOT" 2; shift 2 ;;
	--no-redact) REDACT=0; shift ;;
	--fake-cmd-dir) FAKE_CMD_DIR=${2:-}; shift 2 ;;
	--keep-work) KEEP_WORK=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" 2 ;;
	esac
done

TS=$(date -u '+%Y%m%dT%H%M%SZ')
NAME="liuqin-logs-$TS"
[ -z "$LABEL" ] || NAME="$NAME-$LABEL"
WORK_BASE=$OUT_BASE
mkdir -p "$WORK_BASE" || die "cannot create output directory: $WORK_BASE"
WORK="$WORK_BASE/$NAME"
rm -rf "$WORK" || die "cannot clear work directory: $WORK"
mkdir -p "$WORK/data" "$WORK/meta" || die "cannot create work tree: $WORK"
DATA=$WORK/data
TSV=$WORK/meta/commands.tsv
printf 'id\tsection\tstatus\tdetail\n' >"$TSV"

SECTIONS="system kernel firmware systemd power sensors audio network bluetooth display input boot storage gpu fingerprint camera"

section_dir() {
	dir=$DATA/$1
	mkdir -p "$dir"
	printf '%s\n' "$dir"
}

record() { # id section status detail
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TSV"
}

rootpath() { printf '%s%s' "$ROOT" "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# cap stdin to N bytes (busybox head supports -c)
cap_stream() { head -c "${1:-$CAP_QUICK}" 2>/dev/null || cat; }

# run_cmd <id> <section> <required-tool> <shell-command> [cap-bytes]
run_cmd() {
	id=$1 section=$2 tool=$3 cmd=$4 limit=${5:-$CAP_QUICK}
	dir=$(section_dir "$section")
	out=$dir/$id.txt
	if [ -n "$FAKE_CMD_DIR" ] && [ -f "$FAKE_CMD_DIR/$id.out" ]; then
		cp "$FAKE_CMD_DIR/$id.out" "$out" 2>/dev/null
		record "$id" "$section" "FAKE" "test hook output"
		return 0
	fi
	if [ -n "$ROOT" ]; then
		record "$id" "$section" "SKIP" "offline --root mode (device command not run)"
		return 0
	fi
	if ! have "$tool"; then
		record "$id" "$section" "SKIP" "tool not found: $tool"
		return 0
	fi
	if have timeout; then
		timeout 40 sh -c "$cmd" 2>&1 | cap_stream "$limit" >"$out"
	else
		sh -c "$cmd" 2>&1 | cap_stream "$limit" >"$out"
	fi
	rc=$?
	record "$id" "$section" "OK" "exit=$rc bytes=$(wc -c <"$out" 2>/dev/null || echo 0)"
}

# read_file <id> <section> <absolute-path>
read_file() {
	id=$1 section=$2 path=$3
	dir=$(section_dir "$section")
	src=$(rootpath "$path")
	if [ -d "$src" ]; then
		record "$id" "$section" "SKIP" "directory, not a file: $path"
		return 0
	fi
	if [ -r "$src" ]; then
		cp "$src" "$dir/$id.txt" 2>/dev/null || cat "$src" >"$dir/$id.txt"
		record "$id" "$section" "OK" "$path"
	else
		record "$id" "$section" "SKIP" "not readable: $path"
	fi
}

# dump_dir <id> <section> <absolute-dir> <attribute...>
dump_dir() {
	id=$1 section=$2 dir_path=$3
	shift 3
	dir=$(section_dir "$section")
	out=$dir/$id.txt
	: >"$out"
	src=$(rootpath "$dir_path")
	if [ ! -d "$src" ]; then
		record "$id" "$section" "SKIP" "directory missing: $dir_path"
		return 0
	fi
	for entry in "$src"/*; do
		[ -e "$entry" ] || continue
		printf '### %s\n' "${entry#"$src"/}" >>"$out"
		for attr in "$@"; do
			if [ -r "$entry/$attr" ]; then
				printf '%s: ' "$attr" >>"$out"
				cap_stream 4096 <"$entry/$attr" >>"$out" 2>/dev/null || true
				printf '\n' >>"$out"
			fi
		done
	done
	record "$id" "$section" "OK" "$dir_path"
}

# ---------------------------------------------------------------------------
# collectors
# ---------------------------------------------------------------------------
collect_system() {
	section_dir system >/dev/null
	run_cmd uname system uname 'uname -a'
	read_file os-release system /etc/os-release
	read_file hostname system /etc/hostname
	read_file cmdline system /proc/cmdline
	read_file uptime system /proc/uptime
	read_file date system /proc/driver/rtc
	read_file model system /proc/device-tree/model
	read_file socinfo system /sys/devices/soc0/machine
	run_cmd rpm-list system rpm 'rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n" | sort' "$CAP_FULL"
	run_cmd kernel-rpm system rpm 'rpm -q kernel-liuqin kernel 2>&1'
	run_cmd fedora-release system cat 'cat /etc/fedora-release 2>/dev/null'
	if [ "$MODE" = full ]; then
		read_file product-serial system /sys/class/dmi/id/product_serial
		read_file cpuinfo system /proc/cpuinfo
		read_file meminfo system /proc/meminfo
	fi
}

collect_kernel() {
	run_cmd dmesg kernel dmesg 'dmesg 2>&1' "$CAP_FULL"
	run_cmd dmesg-firmware kernel grep \
		'dmesg 2>&1 | grep -i -E "firmware|ath11k|adsp|cdsp|slpi|qcom_scm|msm" | tail -n 400'
	run_cmd lsmod kernel lsmod 'lsmod 2>&1 | sort'
	run_cmd kernel-release kernel cat 'cat /proc/sys/kernel/osrelease 2>/dev/null'
	read_file kernel-release-file kernel /usr/share/liuqin/kernel.release
	run_cmd modules kernel ls 'ls -1 /usr/lib/modules 2>&1'
	run_cmd config kernel cat 'zcat /proc/config.gz 2>/dev/null || cat /boot/config-$(uname -r) 2>/dev/null'
	run_cmd taint kernel cat 'cat /proc/sys/kernel/tainted 2>/dev/null'
	run_cmd devicetree-symbols kernel sh \
		'ls /proc/device-tree/__symbols__ 2>/dev/null | head -n 5; ls /sys/firmware/devicetree/base 2>/dev/null | head -n 20'
	if [ "$MODE" = full ]; then
		read_file iomem kernel /proc/iomem
		read_file interrupts kernel /proc/interrupts
	fi
}

collect_firmware() {
	dir=$(section_dir firmware)
	out=$dir/firmware-files.txt
	: >"$out"
	for rel in \
		novatek/liuqin/novatek_nt36532_m81_fw_csot.bin \
		novatek/liuqin/novatek_nt36532_m81_fw_tm.bin \
		qca/hpbtfw20.tlv qca/hpnv20.bin \
		qcom/sm8475/liuqin/adsp.mbn qcom/sm8475/liuqin/cdsp.mbn \
		qcom/sm8475/liuqin/slpi.mbn qcom/sm8475/liuqin/a730_zap.mbn \
		updates/qcom/a730_sqe.fw updates/qcom/gmu_gen70000.bin \
		updates/qcom/vpu/vpu20_4v.mbn \
		updates/ath11k/WCN6855/hw2.0/amss.bin \
		updates/ath11k/WCN6855/hw2.0/board-2.bin \
		updates/ath11k/WCN6855/hw2.0/m3.bin \
		updates/ath11k/WCN6855/hw2.0/regdb.bin \
		ath11k/WCN6855/hw2.0/board.bin \
		qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin \
		regulatory.db \
		cirrus/cs35l41-dsp1-spk-prot.wmfw \
		cirrus/cs35l41-dsp1-spk-prot.bin; do
		src=$(rootpath "/usr/lib/firmware/$rel")
		if [ -e "$src" ]; then
			printf 'PRESENT %s %s\n' "$(wc -c <"$src" 2>/dev/null || echo '?')" "$rel" >>"$out"
		elif [ -e "$src.xz" ] || [ -e "$src.zst" ] || [ -e "$src.gz" ]; then
			printf 'PRESENT-COMPRESSED %s\n' "$rel" >>"$out"
		else
			printf 'MISSING - %s\n' "$rel" >>"$out"
		fi
	done
	# per-device CS35L41 calibration provisioned from persist
	for ch in TL TR BL BR; do
		if [ -e "$(rootpath "/usr/lib/firmware/cirrus/cs35l41-liuqin-$ch-calr.bin")" ]; then
			printf 'CALR %s present\n' "$ch" >>"$out"
		else
			printf 'CALR %s missing\n' "$ch" >>"$out"
		fi
	done
	record firmware-files firmware OK "inventory written"
	run_cmd dmesg-firmware-errors firmware grep \
		'dmesg 2>&1 | grep -i -E "failed to load firmware|direct firmware load|firmware: .*failed|request_firmware" | tail -n 200'

}

collect_systemd() {
	run_cmd systemctl-failed systemd systemctl \
		'systemctl --failed --no-legend --plain 2>&1'
	run_cmd systemctl-list-units systemd systemctl \
		'systemctl list-units --type=service --state=running --no-legend --plain 2>&1 | head -n 60'
	for unit in display-manager NetworkManager bluetooth iio-sensor-proxy chronyd; do
		run_cmd "unit-$unit" systemd systemctl \
			"systemctl status --no-pager --lines=0 $unit 2>&1 | head -n 12"
	done
	for unit in pipewire wireplumber; do
		run_cmd "user-unit-$unit" systemd systemctl \
			"systemctl --user status --no-pager --lines=0 $unit 2>&1 | head -n 12"
	done
	for unit in liuqin-power-keyd liuqin-backlight-default liuqin-wlan-mac liuqin-mipps-auth liuqin-hide-gunyah-node; do
		run_cmd "unit-$unit" systemd systemctl \
			"systemctl status --no-pager --lines=0 $unit 2>&1 | head -n 12"
	done
	run_cmd journal-warnings systemd journalctl \
		'journalctl -b --no-pager -p warning -o short-precise 2>&1' "$CAP_QUICK"
	if [ "$MODE" = full ]; then
		run_cmd journal-full systemd journalctl \
			'journalctl -b --no-pager 2>&1' "$CAP_FULL"
		run_cmd journal-kernel systemd journalctl \
			'journalctl -k -b --no-pager 2>&1' "$CAP_FULL"
	fi
}

collect_power() {
	dump_dir power-supply power /sys/class/power_supply \
		type status capacity voltage_now current_now power_now online present health \
		charge_control_end_threshold \
		uevent manufacturer model_name serial_number
	dir=$(section_dir power)
	out=$dir/xiaomi-attributes.txt
	: >"$out"
	for candidate in /sys/devices/platform/pmic-glink/*/xiaomi /sys/class/power_supply/*/xiaomi; do
		src=$(rootpath "$candidate")
		for entry in "$src"/*; do
			[ -e "$entry" ] || continue
			printf '%s: ' "${entry#"$src"/}" >>"$out"
			cap_stream 256 <"$entry" >>"$out" 2>/dev/null || true
			printf '\n' >>"$out"
		done
	done
	[ -s "$out" ] || record xiaomi-attributes power SKIP "no pmic-glink xiaomi attribute group"
	run_cmd upower power upower 'upower -d 2>&1' "$CAP_FULL"
}

collect_sensors() {
	# Reading *_raw may request a sample too; inventory only, never sample.
	dump_dir iio-devices sensors /sys/bus/iio/devices \
		name
	for dev in /sys/bus/iio/devices/iio:device*; do
		dir=$(rootpath "$dev")
		[ -d "$dir" ] || continue
		[ -r "$dir/name" ] && cat "$dir/name" >>"$(section_dir sensors)/iio-names.txt" 2>/dev/null
	done
	# Passive collection must not activate the known-resetting SLPI stack or
	# acquire sensor claims merely to collect logs (even outside --full).
	record sensor-active-probes sensors SKIP "monitor-sensors/ssccli excluded; preserve SLPI workaround"
	run_cmd sensor-registry sensors sh \
		'ls /var/lib/liuqin-sensors/registry 2>/dev/null | wc -l'
	run_cmd slpi-service sensors systemctl \
		'systemctl status --no-pager --lines=0 liuqin-slpi.service liuqin-hexagonrpcd-sdsp.service 2>&1 | head -n 30'
}

collect_audio() {
	run_cmd wpctl audio wpctl 'wpctl status 2>&1' "$CAP_QUICK"
	run_cmd aplay audio aplay 'aplay -l 2>&1'
	run_cmd arecord audio arecord 'arecord -l 2>&1'
	run_cmd asound-cards audio cat 'cat /proc/asound/cards 2>&1'
	run_cmd asound-pcm audio cat 'cat /proc/asound/pcm 2>&1'
	run_cmd ucm-files audio sh \
		'ls -l /usr/share/alsa/ucm2/conf.d/sm8450/ /usr/share/alsa/ucm2/Qualcomm/sm8450/ 2>&1 | head -n 20'
	if [ "$MODE" = full ]; then
		run_cmd wpctl-inspect audio sh \
			'wpctl status -n 2>&1 | head -n 120'
		run_cmd pipewire-journal audio journalctl \
			'journalctl --user -b --no-pager -u pipewire -u wireplumber 2>&1 | tail -n 200'
	fi
}

collect_network() {
	run_cmd nmcli-device network nmcli 'nmcli device status 2>&1'
	# SSID deliberately omitted; BSSIDs are redacted by the generic MAC rule.
	run_cmd nmcli-wifi network nmcli \
		'nmcli -t -f ACTIVE,SIGNAL,SECURITY device wifi list --rescan no 2>&1 | head -n 40'
	run_cmd nmcli-connections network nmcli \
		'nmcli -t -f NAME,TYPE,DEVICE connection show 2>&1'
	run_cmd ip-addr network ip 'ip -brief addr 2>&1'
	run_cmd ip-link network ip 'ip -brief link 2>&1'
	run_cmd iw-dev network iw 'iw dev 2>&1'
	run_cmd rfkill network rfkill 'rfkill list 2>&1'
	run_cmd lspci network lspci 'lspci -nn 2>&1'
	run_cmd lsusb network lsusb 'lsusb 2>&1'
	run_cmd dmesg-net network sh \
		'dmesg 2>&1 | grep -i -E "ath11k|wcn6855|qca|bluetooth|hci_qca|usb" | tail -n 300'
	read_file wlan-mac-file network /var/lib/liuqin-private/wlan-mac
	read_file bt-address-file network /var/lib/liuqin-private/bluetooth-address
}

collect_bluetooth() {
	run_cmd bluetooth-show bluetooth bluetoothctl 'bluetoothctl show 2>&1'
	run_cmd bluetooth-devices bluetooth bluetoothctl \
		'bluetoothctl devices 2>&1 | head -n 40'
	run_cmd hci-devices bluetooth sh \
		'ls /sys/class/bluetooth 2>&1; for d in /sys/class/bluetooth/hci*; do [ -e "$d/address" ] && cat "$d/address"; done 2>/dev/null'
	run_cmd bluetooth-status bluetooth systemctl \
		'systemctl status --no-pager --lines=0 bluetooth.service 2>&1 | head -n 12'
}

collect_display() {
	run_cmd display-manager display systemctl \
		'systemctl show display-manager -p Id -p ActiveState -p FragmentPath 2>&1'
	run_cmd drm-status display sh \
		'for s in /sys/class/drm/card*-*/status; do echo "$s: $(cat "$s" 2>/dev/null)"; done'
	run_cmd backlight display sh \
		'for b in /sys/class/backlight/*; do [ -e "$b" ] || continue; echo "### $b"; cat "$b/brightness" "$b/max_brightness" 2>/dev/null; done'
	run_cmd qmpphy display sh \
		'dmesg 2>&1 | grep -i -E "dp|displayport|qmp|altmode|aux|edp|dsi|panel" | tail -n 300'
}

collect_input() {
	run_cmd input-devices input cat 'cat /proc/bus/input/devices 2>&1' "$CAP_FULL"
	run_cmd libinput-list input libinput 'libinput list-devices 2>&1' "$CAP_FULL"
	read_file input-names input /sys/class/input
	run_cmd udev-touchpad input udevadm \
		'udevadm info /dev/input/event* 2>/dev/null | grep -E "DEVNAME|ID_INPUT|NAME" | head -n 200'
	if [ "$MODE" = full ]; then
		run_cmd evtest-list input evtest 'evtest --list 2>&1 | head -n 80'
	fi
}

collect_boot() {
	dir=$(section_dir boot)
	boot_dir=$(rootpath /boot/liuqin)
	for staged in "$boot_dir"/*.img; do
		[ -f "$staged" ] || continue
		src=$staged
		base=$(basename "$staged")
		{
			printf 'file: %s\n' "$base"
			printf 'bytes: %s\n' "$(wc -c <"$src" 2>/dev/null || echo '?')"
			printf 'header: '
			dd if="$src" bs=1 count=8 2>/dev/null | od -An -c | head -n 1
			if [ "$MODE" = full ]; then
				printf 'sha256: %s\n' "$(sha256sum "$src" 2>/dev/null | cut -d' ' -f1)"
			fi
		} >>"$dir/staged-images.txt"
	done
	[ -f "$dir/staged-images.txt" ] || record staged-images boot SKIP "no staged /boot/liuqin/*.img"
	for sidecar in "$boot_dir"/*.manifest "$boot_dir"/*.build-info.json "$boot_dir"/apply-state.json; do
		src=$sidecar
		[ -f "$src" ] || continue
		cp "$src" "$dir/$(basename "$sidecar").txt" 2>/dev/null || true
	done
	run_cmd apply-boot-status boot liuqin-apply-boot 'liuqin-apply-boot status --json 2>&1' "$CAP_QUICK"
	run_cmd boot-entries boot sh 'ls -l /boot 2>&1 | head -n 40'
	read_file kernel-release-boot boot /usr/share/liuqin/kernel.release
	run_cmd systemd-boot boot sh 'cat /proc/cmdline 2>&1'
}

collect_storage() {
	run_cmd df storage df 'df -hT 2>&1'
	run_cmd lsblk storage lsblk 'lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>&1'
	run_cmd findmnt storage findmnt 'findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS / /home /boot 2>&1'
	run_cmd mount storage mount 'mount 2>&1 | head -n 40'
	read_file fstab storage /etc/fstab
	read_file partitions storage /proc/partitions
	run_cmd dmesg-ufs storage sh \
		'dmesg 2>&1 | grep -i -E "ufs|scsi|sd [0-9]" | tail -n 150'
}

collect_gpu() {
	run_cmd drm-gpu gpu sh \
		'for c in /sys/class/drm/card*; do [ -e "$c" ] || continue; echo "### $c"; cat "$c/device/uevent" 2>/dev/null | head -n 8; done'
	run_cmd dmesg-msm gpu sh \
		'dmesg 2>&1 | grep -i -E "msm|adreno|gpu|a6xx|freedreno" | tail -n 200'
	run_cmd vulkan gpu vulkaninfo 'vulkaninfo --summary 2>&1 | head -n 60' "$CAP_QUICK"
}

collect_fingerprint() {
	run_cmd fprintd-service fingerprint systemctl \
		'systemctl status --no-pager --lines=0 fprintd.service 2>&1 | head -n 20'
	run_cmd fingerprint-units fingerprint systemctl \
		'systemctl list-units --no-legend --plain "*fingerprint*" 2>&1'
	run_cmd fprintd-journal fingerprint journalctl \
		'journalctl -b --no-pager -u fprintd 2>&1 | tail -n 200'
	run_cmd fingerprint-packages fingerprint rpm \
		'rpm -qa "*fprint*" "*fingerprint*" 2>&1'
	run_cmd fingerprint-files fingerprint sh \
		'ls -l /usr/libexec/liuqin-fingerprint 2>&1 | head -n 30'
	run_cmd fpc-device fingerprint sh \
		'ls -l /dev/fpc* /sys/bus/spi/devices/* 2>/dev/null | head -n 30'
}

collect_camera() {
	run_cmd video-devices camera sh 'ls -l /dev/video* /dev/media* 2>&1 | head -n 30'
	run_cmd dmesg-camera camera sh \
		'dmesg 2>&1 | grep -i -E "camss|s5kjn1|cci|camcc|csiphy" | tail -n 200'
	run_cmd libcamera camera libcamera-hello 'libcamera-hello --list-cameras 2>&1 | head -n 80' "$CAP_QUICK"
}

collect_installer_logs() {
	dir=$(section_dir system)
	for log in /var/log/liuqin-install.log /var/log/liuqin-bootimg/*.log /var/log/liuqin-apply-boot.log; do
		src=$(rootpath "$log")
		[ -f "$src" ] || continue
		cp "$src" "$dir/$(basename "$log").txt" 2>/dev/null || true
	done
	for info in /etc/liuqin-installer /etc/liuqin-fedora-root /etc/liuqin-native-root /etc/liuqin-storage-mode /etc/liuqin-root-profile; do
		src=$(rootpath "$info")
		[ -f "$src" ] || continue
		printf '%s: ' "$(basename "$info")" >>"$dir/liuqin-markers.txt"
		head -c 200 "$src" >>"$dir/liuqin-markers.txt" 2>/dev/null || true
		printf '\n' >>"$dir/liuqin-markers.txt"
	done
	run_cmd installed-bundle system sh 'ls -l /boot/liuqin /usr/share/liuqin 2>&1 | head -n 40'
}

# ---------------------------------------------------------------------------
# redaction
# ---------------------------------------------------------------------------
sed_ere() { # ERE expression file
	if sed -E "$1" "$2" >"$2.redacted" 2>/dev/null; then
		mv "$2.redacted" "$2"
	else
		sed -r "$1" "$2" >"$2.redacted" 2>/dev/null && mv "$2.redacted" "$2"
	fi
}

sed_escape() { printf '%s' "$1" | sed 's/[][\\.*^$/]/\\&/g'; }

redact_all() {
	[ "$REDACT" = 1 ] || { record redaction meta SKIP "--no-redact requested (raw values kept)"; return 0; }
	# literal values replaced first (exact host/user/serial strings)
	lit=$WORK/meta/literals.sed
	: >"$lit"
	add_literal() {
		[ -n "${1:-}" ] || return 0
		esc=$(sed_escape "$1")
		printf 's/%s/<redacted>/g\n' "$esc" >>"$lit"
	}
	hostname_value=
	if [ -r "$(rootpath /etc/hostname)" ]; then
		hostname_value=$(head -n 1 "$(rootpath /etc/hostname)" 2>/dev/null)
	else
		hostname_value=$(uname -n 2>/dev/null)
	fi
	add_literal "$hostname_value"
	serial_value=
	if [ -r "$(rootpath /proc/cmdline)" ]; then
		serial_value=$(tr ' ' '\n' <"$(rootpath /proc/cmdline)" 2>/dev/null |
			sed -n 's/^androidboot.serialno=//p' | head -n 1)
	fi
	if [ -r "$(rootpath /sys/class/dmi/id/product_serial)" ]; then
		serial_value=$(cat "$(rootpath /sys/class/dmi/id/product_serial)" 2>/dev/null)
	fi
	add_literal "$serial_value"
	if [ -r "$(rootpath /etc/passwd)" ]; then
		for name in $(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' "$(rootpath /etc/passwd)" 2>/dev/null); do
			add_literal "$name"
		done
	fi
	add_literal "${SUDO_USER:-}"
	add_literal "$(id -un 2>/dev/null)"

	find "$DATA" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.tsv' \
		-o -name '*.json' -o -name '*.conf' -o -name '*.csv' \) >"$WORK/meta/text-files.list"
	while IFS= read -r file; do
		if [ -s "$lit" ]; then
			sed -f "$lit" "$file" >"$file.redacted" 2>/dev/null &&
				mv "$file.redacted" "$file"
		fi
		# generic patterns: MAC, serials, SSID, secrets, fingerprint paths
		sed_ere 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<redacted-mac>/g' "$file"
		sed_ere 's/([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}/<redacted-mac>/g' "$file"
		sed_ere 's/wlan0=[0-9A-Fa-f]{12}/wlan0=<redacted-mac>/g' "$file"
		sed_ere 's/((serial(no)?|serial_number|Serial Number|SerialNumber)[=: ]+)[A-Za-z0-9]+/\1<redacted-serial>/g' "$file"
		sed_ere 's/(SSID[:=][[:space:]]*)[^,]*/\1<redacted-ssid>/g' "$file"
		sed_ere 's/(([Pp][Ss][Kk]|[Pp]assword|[Pp]asswd|[Pp]assphrase|[Ww][Pp][Aa]-[Pp][Ss][Kk])[=:][[:space:]]*)[^[:space:]]+/\1<redacted-secret>/g' "$file"
		sed_ere 's#/var/lib/liuqin-fingerprint[^[:space:]]*#<fingerprint-data>#g' "$file"
		sed_ere 's#/var/lib/fprintd?[^[:space:]]*#<fingerprint-data>#g' "$file"
	done <"$WORK/meta/text-files.list"
	rm -f "$lit" "$WORK/meta/text-files.list"
	record redaction meta OK "hostname/users/serials/MAC/SSID/PSK/fingerprint paths"
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
make_summary() {
	summary=$WORK/SUMMARY.txt
	kernel=$(head -n 1 "$DATA/system/kernel-release.txt" 2>/dev/null ||
		uname -r 2>/dev/null || echo unknown)
	model=$(head -n 1 "$DATA/system/model.txt" 2>/dev/null || echo unknown)
	failed_count=$(grep -c '\.service' "$DATA/systemd/systemctl-failed.txt" 2>/dev/null || echo '?')
	fw_errors=$(grep -ci 'failed to load firmware\|direct firmware load' \
		"$DATA/firmware/dmesg-firmware-errors.txt" 2>/dev/null || echo 0)
	apply_phase=$(sed -n 's/.*"phase": "\([^"]*\)".*/\1/p' \
		"$DATA/boot/apply-boot-status.txt" 2>/dev/null | head -n 1)
	staged=$(grep -c '^file: ' "$DATA/boot/staged-images.txt" 2>/dev/null || echo 0)
	skipped=$(awk -F'\t' 'NR > 1 && $3 == "SKIP" {c++} END {print c+0}' "$TSV")
	ok=$(awk -F'\t' 'NR > 1 && ($3 == "OK" || $3 == "FAKE") {c++} END {print c+0}' "$TSV")
	{
		echo "liuqin log bundle"
		echo "tool: collect-logs.sh $VERSION"
		echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "mode: $MODE"
		echo "sysroot: ${ROOT:-/ (running system)}"
		echo "redaction: $([ "$REDACT" = 1 ] && echo enabled || echo DISABLED)"
		echo "kernel: $kernel"
		echo "model: $model"
		echo "failed systemd services (line count): $failed_count"
		echo "firmware load errors (dmesg matches): $fw_errors"
		echo "apply-boot journal phase: ${apply_phase:-none}"
		echo "staged boot images: $staged"
		echo "collectors: ok/fake=$ok skipped=$skipped"
		echo
		echo "Sections:"
		for section in system kernel firmware systemd power sensors audio network \
			bluetooth display input boot storage gpu fingerprint camera; do
			[ -d "$DATA/$section" ] || continue
			echo "  $section: $(find "$DATA/$section" -type f 2>/dev/null | wc -l) files"
		done
		echo
		echo "Skipped collectors (tool/dir/offline root):"
		awk -F'\t' 'NR > 1 && $3 == "SKIP" {printf "  %s: %s\n", $1, $4}' "$TSV"
		echo
		echo "How to report:"
		echo "  attach $(basename "$WORK_BASE")/$NAME.tar.gz to the issue; it contains"
		echo "  redacted command outputs only (no device/partition writes were made)."
	} >"$summary"
	printf 'SUMMARY\n%s\n' "$(cat "$summary")" >"$DATA/summary.txt"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
printf 'collect-logs: mode=%s root=%s out=%s\n' "$MODE" "${ROOT:-/}" "$OUT_BASE" >&2
collect_system
collect_kernel
collect_firmware
collect_systemd
collect_power
collect_sensors
collect_audio
collect_network
collect_bluetooth
collect_display
collect_input
collect_boot
collect_storage
collect_gpu
collect_fingerprint
collect_camera
collect_installer_logs
redact_all
make_summary

tarball=$OUT_BASE/$NAME.tar.gz
if have tar; then
	( cd "$OUT_BASE" && tar -czf "$NAME.tar.gz" "$NAME" ) || die "tar failed: $tarball"
else
	die "tar is not available; raw logs left in $WORK"
fi
cp "$WORK/SUMMARY.txt" "$OUT_BASE/$NAME.summary.txt" 2>/dev/null || true
[ "$KEEP_WORK" = 1 ] || rm -rf "$WORK"
printf 'collect-logs: bundle: %s\n' "$tarball"
printf 'collect-logs: summary: %s.summary.txt\n' "$OUT_BASE/$NAME"
exit 0
