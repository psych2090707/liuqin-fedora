#!/bin/sh
# SPDX-License-Identifier: MIT
# Upstream: xiaomipad-6pro-mainline commit f5a535f5c1c980f042b58cb77467ff8f02a5518e
#           tools/lib/install-root.sh (MIT).  This file is the Fedora adaptation;
#           every change carries a "# FEDORA:" comment.  The Ubuntu-original
#           stays at upstream/xiaomipad-6pro-mainline/tools/lib/install-root.sh.
# Device-side installer, intended only for the dedicated read-only RAM image.
# Fedora changes (flat install contract):
#   * FLAT installation: the rootfs archive is extracted onto the partition root
#     (no /native-root subdirectory), matching root.img, the boot image's Fedora
#     profile and the admission contract; the old nested layout is gone;
#   * login manager is plasmalogin (Plasma Login Manager); SDDM is not checked,
#     not installed and not enabled;
#   * the installer image embeds the Fedora admission contract v2, validated
#     before the first write, applied to the extracted tree after extraction and
#     re-applied after a read-only remount; mutable content hashes are never
#     compared (topology contract);
#   * /etc/fstab is written with the filesystem UUID created here, the
#     machine-id is cleared and random-seed removed; files owned by the RPMs /
#     listed in the contract are never rewritten by the installer.
# The upstream partition/layout and persist provisioning logic is otherwise
# unchanged.
set -eu
die() { printf 'liuqin-install: %s\n' "$*" >&2; exit 1; }
# Privileged-file expectations are generated at image assembly from the REAL
# assembled rootfs (scripts/build-image.sh) and embedded in installer.img; this
# helper only verifies that the extraction preserved them (no hardcoded
# distribution guesses such as "ping must have cap_net_raw").
. /usr/lib/liuqin/install-privileges.sh
usage='usage: install-root.sh BOOT_ID ROOTFS_URL SHA256 BYTES ERASE-LIUQIN-USERDATA ROOT_PARTNAME HOME_PARTNAME [ENABLE-USB-RESCUE] [KEEP-HOME] [BATTERY-UNAVAILABLE-OK] [SWITCH-STORE ubuntu URL SHA256 BYTES android URL SHA256 BYTES]'
[ "$#" -ge 7 ] || die "$usage"
[ "$5" = ERASE-LIUQIN-USERDATA ] || die 'explicit data-erasure acknowledgement required'
root_name=$6
home_name=$7
# The options follow the seven fixed arguments.  ENABLE-USB-RESCUE and
# KEEP-HOME may each be given once, in either order (the host sends them in
# the order of the usage line).  KEEP-HOME reinstalls the system and keeps the
# existing LIUQIN_HOME filesystem.  The dual layout adds the switch store: the
# Ubuntu and Android boot images that liuqin-switch rotates through boot_a,
# fetched from the host like the root archive.  SWITCH-STORE and its eight
# fields are always last.
rescue=
keep_home=
battery_unavailable_ok=
store=
switch_store=${0%/*}/install-switch-store.sh
store_ubuntu_url='' store_ubuntu_sha='' store_ubuntu_bytes=''
store_android_url='' store_android_sha='' store_android_bytes=''
store_fields() { # SWITCH-STORE ubuntu URL SHA256 BYTES android URL SHA256 BYTES
	shift
	[ -f "$switch_store" ] || die 'the switch-store step is missing from the installer image'
	# Validate everything before anything is formatted.
	sh "$switch_store" --check "$@"
	store=SWITCH-STORE
	store_ubuntu_url=$2 store_ubuntu_sha=$3 store_ubuntu_bytes=$4
	store_android_url=$6 store_android_sha=$7 store_android_bytes=$8
}
parse_options() { # the script's own arguments
	shift 7
	while [ "$#" -gt 0 ]; do
		case $1 in
		ENABLE-USB-RESCUE)
			[ -z "$rescue" ] || die "option given twice: $1; $usage"
			rescue=$1
			;;
		KEEP-HOME)
			[ -z "$keep_home" ] || die "option given twice: $1; $usage"
			keep_home=$1
			;;
		BATTERY-UNAVAILABLE-OK)
			# FEDORA: the RAM image has no ADSP battery manager, so the
			# pack attributes can be unreadable on real hardware.  The host
			# passes this only with Fastboot battery evidence.
			[ -z "$battery_unavailable_ok" ] || die "option given twice: $1; $usage"
			battery_unavailable_ok=true
			;;
		SWITCH-STORE)
			[ "$#" = 9 ] || die "$usage"
			store_fields "$@"
			return 0
			;;
		*) die "unsupported option: $1; $usage" ;;
		esac
		shift
	done
}
parse_options "$@"
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$1" ] || die 'RAM boot identity changed'
[ "$(cat /etc/liuqin-installer 2>/dev/null)" = liuqin ] || die 'not the installer RAM image'
ln -sf /proc/self/fd/0 /dev/stdin
# The host checks Fastboot product/serial; boot_id binds this operation to it.
# Partition numbers and offsets are not pinned: liuqin capacity variants place
# the tail partitions differently, and the layout step may have just created
# these two.  PARTNAME is the identity, read from sysfs rather than from
# /dev/disk/by-partlabel, which is built once at boot from a fixed name list
# and therefore cannot describe a table the layout step has changed.
find_part() {
	found=
	for info in /sys/class/block/sd*/uevent; do
		/bin/busybox grep -qx "PARTNAME=$1" "$info" || continue
		[ -z "$found" ] || die "duplicate partition name: $1"
		node=${info%/uevent}
		found=/dev/${node##*/}
	done
	[ -n "$found" ] && [ -b "$found" ] ||
		die "partition is missing: $1 —— 该设备不是受支持的小米平板 6 Pro（liuqin），或分区步骤未完成"
	printf '%s' "$found"
}
# The label is the identity of the home filesystem, as it is in fstab.
# e2label comes with the installer's e2fsprogs.  The installer's BusyBox has no
# blkid, so an image built without e2label reads the ext2/3/4 superblock
# itself: magic 0xEF53 at byte 1080, the 16-byte volume name at byte 1144.
home_label() { # <device>
	if [ -x /usr/sbin/e2label ]; then
		/usr/sbin/e2label "$1"
		return
	fi
	[ "$(/bin/busybox dd if="$1" bs=1 skip=1080 count=2 2>/dev/null |
		/bin/busybox od -An -tx1 | /bin/busybox tr -d ' \n')" = 53ef ] || return 1
	/bin/busybox dd if="$1" bs=1 skip=1144 count=16 2>/dev/null | /bin/busybox tr -d '\000'
}
check_home() { # <device>: KEEP-HOME keeps only the filesystem this installer made
	ch_label=$(home_label "$1") || ch_label=
	[ "$ch_label" = LIUQIN_HOME ] ||
		die "KEEP-HOME: $1 does not hold the LIUQIN_HOME filesystem (label '$ch_label');" \
			'nothing was formatted —— linux_home 上没有可保留的 LIUQIN_HOME 文件系统，未格式化任何分区'
}
# Without KEEP-HOME the home partition is formatted.  With it, the existing
# filesystem must carry the LIUQIN_HOME label and pass `e2fsck -p` (status 0,
# nothing to fix, or 1, fixed); anything else stops the installation.  This
# runs in the write window before the system partition is formatted, so a
# home that cannot be kept stops the installation with nothing changed.
prepare_home() { # <device> <KEEP-HOME or empty>
	case $2 in
	'')
		/usr/sbin/mkfs.ext4 -F -L LIUQIN_HOME -m 0 "$1"
		return 0
		;;
	KEEP-HOME) ;;
	*) die 'unsupported home mode' ;;
	esac
	check_home "$1"
	ph_status=0
	/usr/sbin/e2fsck -p "$1" || ph_status=$?
	[ "$ph_status" -lt 2 ] ||
		die "KEEP-HOME: e2fsck -p $1 exited with status $ph_status; nothing was formatted" \
			'—— linux_home 文件系统检查未通过，未格式化任何分区'
}
# Whether the root archive's /home skeleton is copied onto the mounted home:
# always onto a fresh filesystem; onto a kept one only when it holds nothing
# but lost+found.
home_needs_skeleton() { # <mounted home> <KEEP-HOME or empty>
	[ "$2" = KEEP-HOME ] || return 0
	hs_count=0
	for hs_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
		[ -e "$hs_entry" ] || [ -L "$hs_entry" ] || continue
		[ "${hs_entry##*/}" != lost+found ] || continue
		hs_count=$((hs_count + 1))
	done
	if [ "$hs_count" -gt 0 ]; then
		printf 'liuqin-install: keeping existing /home (%s entries)\n' "$hs_count"
		return 1
	fi
	printf 'liuqin-install: home partition is empty; seeding the skeleton\n'
}
# FEDORA: the Ubuntu installer proved that tar restored file capabilities by
# probing snap-confine.  Fedora has no snapd and no single canonical file: the
# expectation list is derived from the assembled rootfs at image build time
# (every setuid/setgid file plus every security.capability xattr) and embedded
# in installer.img as /etc/liuqin-installer-privileges.  This check proves tar
# restored exactly those modes/xattrs.  Fedora 44 specifics this avoids:
# /usr/bin/ping is 0755 with NO file capability (iputils uses
# net.ipv4.ping_group_range), while e.g. /usr/bin/kwin_wayland does carry
# cap_sys_nice=ep.  Both facts come from the image, not from this script; the
# function itself lives in /usr/lib/liuqin/install-privileges.sh (sourced at the
# top of this script and also exercised directly by the offline tests).

# FEDORA: enable a unit exactly as systemd's [Install] section says, without
# needing systemctl inside the RAM image.  Used for the KDE display manager.
# The symlink target is the IN-ROOT absolute path (/usr/lib/systemd/system/...),
# never the installer's temporary mount prefix: a link written as
# /mnt/install/usr/... would dangle on the next boot and the tablet would start
# without a login manager.
enable_unit() { # <target root> <unit file name>
	eu_root=$1
	eu_unit=$2
	eu_source=
	eu_target_abs=
	for eu_dir in etc/systemd/system usr/lib/systemd/system lib/systemd/system; do
		if [ -f "$eu_root/$eu_dir/$eu_unit" ]; then
			eu_source=$eu_root/$eu_dir/$eu_unit
			eu_target_abs=/$eu_dir/$eu_unit
			break
		fi
	done
	[ -n "$eu_source" ] ||
		die "systemd unit is missing from the rootfs: $eu_unit —— Fedora KDE 根文件系统不完整"
	eu_wants=$(/bin/busybox awk -F= '/^WantedBy=/ {print $2}' "$eu_source")
	eu_aliases=$(/bin/busybox awk -F= '/^Alias=/ {print $2}' "$eu_source")
	for eu_target in $eu_wants; do
		mkdir -p "$eu_root/etc/systemd/system/$eu_target.wants"
		ln -sf "$eu_target_abs" "$eu_root/etc/systemd/system/$eu_target.wants/$eu_unit"
	done
	for eu_alias in $eu_aliases; do
		mkdir -p "$eu_root/etc/systemd/system"
		ln -sf "$eu_target_abs" "$eu_root/etc/systemd/system/$eu_alias"
	done
}

# --- Fedora root admission contract v2 (topology contract) --------------------
# Topology only: the installer verifies the extracted tree with the same
# predicate the boot image runs (root role marker, PID1/login manager/Plasma
# programs, kernel identity interface).  Mutable configuration and device-payload
# content hashes are deliberately not part of the contract, so an ordinary RPM
# upgrade or hostname change can never make this check fail.
CONTRACT_FILE=/etc/liuqin-fedora-root.contract
contract_die() { die "root admission contract: $*"; }

contract_normalize_path() { # <absolute in-root path> -> normalized path
	cnp_in=${1#/}
	cnp_out=
	while [ -n "$cnp_in" ]; do
		cnp_comp=${cnp_in%%/*}
		case $cnp_in in
		*/*) cnp_in=${cnp_in#*/} ;;
		*) cnp_in= ;;
		esac
		case $cnp_comp in
		''|.) continue ;;
		..) cnp_out=${cnp_out%/*} ;;
		*) cnp_out=$cnp_out/$cnp_comp ;;
		esac
	done
	[ -n "$cnp_out" ] || cnp_out=/
	printf '%s' "$cnp_out"
}

contract_resolve_path() { # <root> <absolute in-root path> -> resolved path
	crp_root=$1
	crp_path=$(contract_normalize_path "$2") || return 1
	crp_hops=0
	while [ "$crp_hops" -lt 16 ]; do
		if [ -L "$crp_root$crp_path" ]; then
			crp_target=$(/bin/busybox readlink "$crp_root$crp_path" 2>/dev/null || true)
			[ -n "$crp_target" ] || return 1
			case $crp_target in
			/*) crp_path=$(contract_normalize_path "$crp_target") || return 1 ;;
			*)
				crp_parent=${crp_path%/*}
				crp_path=$(contract_normalize_path "$crp_parent/$crp_target") ||
					return 1
				;;
			esac
			crp_hops=$((crp_hops + 1))
			continue
		fi
		[ -e "$crp_root$crp_path" ] || return 1
		printf '%s' "$crp_path"
		return 0
	done
	return 1
}

contract_owned_regular() { # <root> <in-root path>
	[ -f "$1$2" ] && [ ! -L "$1$2" ] || return 1
	[ "$(/bin/busybox stat -c '%u %g' "$1$2" 2>/dev/null || true)" = "0 0" ]
}

contract_executable() { # <root> <in-root path>
	contract_owned_regular "$1" "$2" || return 1
	ce_mode=$(/bin/busybox stat -c '%a' "$1$2" 2>/dev/null || true)
	case $ce_mode in ''|*[!0-7]*) return 1 ;; esac
	[ "$((0$ce_mode & 0111))" -ne 0 ]
}

contract_login_manager_ok() { # <root> <unit>
	clm_root=$1
	clm_unit=$2
	for clm_candidate in \
		/etc/systemd/system/display-manager.service \
		/etc/systemd/system/multi-user.target.wants/$clm_unit \
		/etc/systemd/system/graphical.target.wants/$clm_unit; do
		[ -L "$clm_root$clm_candidate" ] || continue
		clm_resolved=$(contract_resolve_path "$clm_root" "$clm_candidate") || continue
		[ "${clm_resolved##*/}" = "$clm_unit" ] || continue
		contract_owned_regular "$clm_root" "$clm_resolved" && return 0
	done
	return 1
}

# Read the 16-byte ext4 UUID (superblock offset 0x468 = 1128) without blkid:
# the installer runtime ships e2fsprogs but not util-linux blkid.
fs_uuid() { # <device>
	fsu_hex=$(/bin/busybox dd if="$1" bs=1 skip=1128 count=16 2>/dev/null |
		/bin/busybox od -An -tx1 | /bin/busybox tr -d ' \n')
	[ "${#fsu_hex}" = 32 ] || return 1
	printf '%s\n' "$fsu_hex" |
		/bin/busybox sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
}

# Format-only validation: runs before the first write to the target partitions.
contract_validate() {
	[ -f "$CONTRACT_FILE" ] && [ ! -L "$CONTRACT_FILE" ] ||
		die 'the Fedora root admission contract is missing from the installer image' \
			'—— 安装器镜像缺少 Fedora 根准入契约（/etc/liuqin-fedora-root.contract）'
	cv_size=$(/bin/busybox stat -c '%s' "$CONTRACT_FILE")
	[ "$cv_size" -ge 256 ] && [ "$cv_size" -le 16384 ] ||
		contract_die "size is outside the parser bounds ($cv_size bytes)"
	cv_lines=$(/bin/busybox wc -l <"$CONTRACT_FILE")
	[ "$cv_lines" -ge 8 ] && [ "$cv_lines" -le 128 ] ||
		contract_die "line count is outside the parser bounds ($cv_lines lines)"
	[ "$(/bin/busybox head -n 1 "$CONTRACT_FILE")" = LIUQIN_FEDORA_ROOT_CONTRACT_V2 ] ||
		contract_die 'header is not LIUQIN_FEDORA_ROOT_CONTRACT_V2'
	cv_entries=0
	while IFS= read -r cv_line; do
		case $cv_line in ''|'#'*) continue ;; esac
		set -f
		# shellcheck disable=SC2086
		set -- $cv_line
		set +f
		case $1 in
		marker) [ "$#" = 4 ] || contract_die "malformed marker line: $cv_line" ;;
		file|exec|display-manager) [ "$#" = 2 ] ||
			contract_die "malformed $1 line: $cv_line" ;;
		resolve) [ "$#" = 3 ] || contract_die "malformed resolve line: $cv_line" ;;
		LIUQIN_FEDORA_ROOT_CONTRACT_V2) continue ;;
		*) contract_die "unknown contract entry: $1" ;;
		esac
		cv_entries=$((cv_entries + 1))
	done <"$CONTRACT_FILE"
	[ "$cv_entries" -ge 8 ] || contract_die "only $cv_entries topology entries"
	printf 'liuqin-install: admission contract v2 validated (%s entries)\n' "$cv_entries"
}

# Apply the contract to a tree: called after extraction (writes are done) and
# again on the read-only remount (post-install verification).
contract_apply() { # <root>
	ca_root=$1
	ca_header=false
	ca_entries=0
	ca_marker=false
	ca_display_manager=false
	while IFS= read -r ca_line; do
		case $ca_line in ''|'#'*) continue ;; esac
		if [ "$ca_header" = false ]; then
			[ "$ca_line" = LIUQIN_FEDORA_ROOT_CONTRACT_V2 ] ||
				contract_die 'header is not LIUQIN_FEDORA_ROOT_CONTRACT_V2'
			ca_header=true
			continue
		fi
		set -f
		# shellcheck disable=SC2086
		set -- $ca_line
		set +f
		ca_entries=$((ca_entries + 1))
		case $1 in
		marker)
			[ "$2" = /etc/liuqin-fedora-root ] ||
				contract_die "marker path is not /etc/liuqin-fedora-root"
			ca_file=$ca_root$2
			[ -f "$ca_file" ] && [ ! -L "$ca_file" ] ||
				die 'the installed root has no root role marker' \
					'—— 安装结果缺少根角色标记 /etc/liuqin-fedora-root'
			ca_marker_mode=${3#0}
			[ "$(/bin/busybox stat -c '%a %u %g' "$ca_file" 2>/dev/null || true)" = "$ca_marker_mode 0 0" ] ||
				contract_die "marker metadata is not $3 0 0: $2"
			[ "$(/bin/busybox sha256sum "$ca_file" | /bin/busybox cut -d' ' -f1)" = "$4" ] ||
				contract_die "marker content mismatch: $2"
			ca_marker=true
			;;
		file)
			contract_owned_regular "$ca_root" "$2" ||
				contract_die "not a root-owned regular file: $2"
			;;
		exec)
			contract_executable "$ca_root" "$2" ||
				contract_die "not an executable root-owned file: $2"
			;;
		resolve)
			ca_resolved=$(contract_resolve_path "$ca_root" "$2") ||
				contract_die "unresolvable symlink: $2"
			[ "${ca_resolved##*/}" = "$3" ] ||
				contract_die "$2 resolves to $ca_resolved"
			contract_owned_regular "$ca_root" "$ca_resolved" ||
				contract_die "$2 resolves to a non-root-owned file"
			;;
		display-manager)
			contract_login_manager_ok "$ca_root" "$2" ||
				contract_die "login manager $2 does not resolve to an existing unit"
			ca_display_manager=true
			;;
		*)
			contract_die "unknown contract entry: $1"
			;;
		esac
	done <"$CONTRACT_FILE"
	[ "$ca_header" = true ] || contract_die 'contract has no header'
	[ "$ca_marker" = true ] || contract_die 'contract has no marker entry'
	[ "$ca_display_manager" = true ] || contract_die 'contract has no display-manager entry'
	[ "$ca_entries" -ge 8 ] || contract_die "only $ca_entries topology entries"
	printf 'liuqin-install: admission topology PASS (%s entries)\n' "$ca_entries"
}
# FEDORA: first-boot state for Fedora KDE Plasma.  The rootfs must already
# ship its desktop user: creating accounts from the installer would need a
# password policy the host cannot supply, so a rootfs without a UID>=1000
# account is refused rather than silently installed without a login.
fedora_desktop() { # <target root>
	[ -f "$1/etc/os-release" ] ||
		die 'the archive is not a Fedora root: /etc/os-release is missing'
	{ grep -q '^ID=fedora' "$1/etc/os-release" ||
		{ grep -qx 'ID=liuqin' "$1/etc/os-release" &&
		  grep -qx 'ID_LIKE=fedora' "$1/etc/os-release"; }; } ||
		die 'the archive is not a Fedora root: /etc/os-release does not say ID=fedora' \
			'—— 根文件系统不是 Fedora（install-root.sh 的 Fedora 版只安装 Fedora 根）'
	# Fedora Workstation uses GDM; the retained KDE profile uses plasmalogin.
	# SDDM is not shipped by either profile and is not checked here.
	if [ -f "$1/usr/lib/systemd/system/gdm.service" ]; then
		fd_lm_unit=gdm.service
		fd_lm_name=gdm
	elif [ -f "$1/usr/lib/systemd/system/plasmalogin.service" ]; then
		fd_lm_unit=plasmalogin.service
		fd_lm_name=plasmalogin
	else
		die 'the Fedora rootfs ships neither gdm.service nor plasmalogin.service' \
			'—— Fedora 根文件系统既没有 GDM 也没有 plasmalogin，不是本项目的桌面镜像'
	fi
	fd_user=$(/bin/busybox awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' "$1/etc/passwd")
	[ -n "$fd_user" ] ||
		die 'the Fedora rootfs ships no desktop user (UID >= 1000)' \
			'—— 根文件系统没有桌面用户；请在镜像构建时内置首个用户'
	printf 'liuqin-install: desktop user: %s (login manager: %s)\n' "$fd_user" "$fd_lm_name"
	enable_unit "$1" "$fd_lm_unit"
	# Both profiles enable the login manager through the systemd alias; the
	# admission contract checks exactly this resolution, so prove it before
	# declaring the installation complete.
	[ -L "$1/etc/systemd/system/display-manager.service" ] ||
		die "could not enable $fd_lm_name (display-manager.service alias missing)" \
			"—— 无法启用 $fd_lm_name（缺少 display-manager.service 别名）"
	[ -f "$1/usr/lib/systemd/system/graphical.target" ] &&
		ln -sf /usr/lib/systemd/system/graphical.target "$1/etc/systemd/system/default.target"
	# A machine-id from the build host must not leak into every tablet.
	for fd_id in "$1/etc/machine-id" "$1/var/lib/dbus/machine-id"; do
		[ -e "$fd_id" ] || continue
		[ -L "$fd_id" ] && continue
		: >"$fd_id"
		/bin/busybox chmod 0444 "$fd_id"
	done
	rm -f "$1/var/lib/systemd/random-seed"
	# SELinux is an image-build decision: an enforcing rootfs without a relabel
	# step may not reach the display manager.  Record it where the operator
	# sees it instead of guessing.
	if [ -f "$1/etc/selinux/config" ] &&
		/bin/busybox grep -q '^SELINUX=enforcing' "$1/etc/selinux/config"; then
		printf '%s\n' \
			'SELinux is enforcing in this rootfs. The installer does not relabel' \
			'it; verify the first boot or build the image with SELINUX=permissive.' \
			>>"$1/etc/liuqin-installer-notes"
		printf 'liuqin-install: WARNING: SELinux is enforcing; first boot needs a relabel check\n' >&2
	fi
}
root=$(find_part "$root_name")
home=$(find_part "$home_name")
[ "$root" != "$home" ] || die 'the system and home partitions must differ'
node=${root##*/}
size=$(cat "/sys/class/block/$node/size")
case $size in ''|*[!0-9]*) die 'system partition size is unavailable' ;; esac
[ "$size" -ge 33554432 ] || die 'the system partition is smaller than 16 GiB —— 不支持该布局'
home_size=$(cat "/sys/class/block/${home##*/}/size")
case $home_size in ''|*[!0-9]*) die 'home partition size is unavailable' ;; esac
[ "$home_size" -ge 16777216 ] || die 'the home partition is smaller than 8 GiB —— 不支持该布局'
parent_path=$(/bin/busybox readlink -f "/sys/class/block/$node/.." 2>/dev/null || true)
[ -n "$parent_path" ] || die 'the system partition parent disk is unavailable'
parent=/dev/${parent_path##*/}
[ -b "$parent" ] || die 'the system partition parent disk is missing'
for target in "$root" "$home"; do
	device_number=$(cat "/sys/class/block/${target##*/}/dev")
	awk -v device="$device_number" '$3 == device {found=1} END {exit !found}' /proc/self/mountinfo &&
		die 'a target partition is mounted (including through a device alias)'
	[ "$(/bin/busybox blockdev --getro "$target")" = 1 ] || die 'a target partition is not initially read-only'
done
# A home that cannot be kept is refused before anything is downloaded; the
# check is repeated in the write window, together with e2fsck.
[ -z "$keep_home" ] || check_home "$home"
# FEDORA: the battery gate.  In the RAM image the pack is exposed through
# qcom-battmgr, whose attributes are ADSP-backed; with no ADSP services running
# every read returns EAGAIN on the real tablet (2026-10-22).  A readable
# percentage is still enforced when the kernel provides one.  When it does not,
# only the explicit BATTERY-UNAVAILABLE-OK token continues, and the host only
# sends it after Fastboot reported battery-soc-ok and a healthy pack voltage --
# an unverified image must not lose power mid-extraction.
battery=
for supply in /sys/class/power_supply/*; do
	[ "$(cat "$supply/type" 2>/dev/null)" = Battery ] || continue
	battery=$(cat "$supply/capacity" 2>/dev/null || true)
	break
done
case $battery in
''|*[!0-9]*)
	[ "$battery_unavailable_ok" = true ] ||
		die 'battery level is unavailable; refusing without Fastboot battery evidence'
	printf 'liuqin-install: WARNING: battery capacity is unreadable in the RAM image; continuing on the host battery check\n' >&2
	;;
*)
	[ "$battery" -ge 30 ] || die 'charge the tablet to at least 30 percent before installation'
	;;
esac
case $3 in *[!0-9a-f]*|'') die 'invalid rootfs hash' ;; esac
[ "${#3}" = 64 ] || die 'invalid rootfs hash length'
case $4 in ''|*[!0-9]*) die 'invalid archive size' ;; esac
available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[ "$4" -gt 0 ] && [ "$(( $4 + 536870912 ))" -lt "$((available * 1024))" ] ||
	die 'insufficient RAM to stage this archive safely'
# FEDORA (flat install contract): every check that can be done without touching the target
# partitions happens before the first write:
#   1. the embedded admission contract v2 is structurally valid;
#   2. the downloaded rootfs archive matches the bundle's size and sha256;
#   3. the archive is a FLAT rootfs (no top-level native-root/) and carries the
#      files the installation and boot depend on.
contract_validate
# The privileged-file expectation list is generated from the real assembled
# rootfs at image build time; a missing/garbled list must stop before writing.
[ -f /etc/liuqin-installer-privileges ] && [ ! -L /etc/liuqin-installer-privileges ] ||
	die 'the installer image carries no privileged-file expectations' \
		'—— 安装器镜像缺少特权文件期望列表（/etc/liuqin-installer-privileges）'
/bin/busybox grep -Eq '^(setuid|setgid|cap) /|^#' /etc/liuqin-installer-privileges ||
	die 'the privileged-file expectation list is malformed' \
		'—— 特权文件期望列表格式错误'
archive=/mnt/install-download/rootfs.tar.gz
mounted=false
home_mounted=false
opened=false
persist_mounted=false
download_mounted=false
cleanup() {
	sync
	if [ "$home_mounted" = true ]; then
		umount /mnt/install-home || return 1
		home_mounted=false
	fi
	if [ "$mounted" = true ]; then
		umount /mnt/install || return 1
		mounted=false
	fi
	if [ "$opened" = true ]; then
		/bin/busybox blockdev --setro "$home"
		/bin/busybox blockdev --setro "$root"
		/bin/busybox blockdev --setro "$parent"
		opened=false
	fi
	if [ "$persist_mounted" = true ]; then
		umount /run/persist || return 1
		persist_mounted=false
	fi
	if [ "$download_mounted" = true ]; then
		umount /mnt/install-download || return 1
		download_mounted=false
	fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
# A default /run tmpfs is too small for some complete desktop archives.
mkdir -p /mnt/install-download /run/persist /mnt/install /mnt/install-home
mount -t tmpfs -o "size=$(( $4 + 16777216 ))" tmpfs /mnt/install-download
download_mounted=true
/bin/busybox wget -O "$archive" "$2"
[ "$(stat -c %s "$archive")" = "$4" ] || die 'downloaded archive size mismatch'
printf '%s  %s\n' "$3" "$archive" | /bin/busybox sha256sum -c -
# FLAT-layout preflight (flat install contract): the archive root must be the rootfs root.
# This is a pure read of the downloaded archive, before any partition write.
archive_entries=/mnt/install-download/rootfs.entries
/usr/bin/tar -tzf "$archive" >"$archive_entries" ||
	die 'the rootfs archive is not a readable tar.gz' \
		'—— 根文件系统归档不是可读的 tar.gz'
if /bin/busybox grep -q '^\./native-root' "$archive_entries"; then
	die 'the rootfs archive uses the obsolete nested /native-root layout' \
		'—— 根文件系统归档是已废弃的 native-root 嵌套布局，不是平铺安装'
fi
for entry in ./etc/os-release ./usr/lib/systemd/systemd \
	./etc/liuqin-fedora-root ./etc/liuqin/image-contract; do
	/bin/busybox grep -qx "$entry" "$archive_entries" ||
		die "the rootfs archive lacks $entry" \
			"—— 根文件系统归档缺少 $entry（不是本项目的 Fedora 根）"
done
/bin/busybox grep -qxE '\./usr/bin/(gdm|plasmalogin)' "$archive_entries" ||
	die 'the rootfs archive lacks /usr/bin/gdm or /usr/bin/plasmalogin' \
		'—— 根文件系统归档缺少桌面登录管理器可执行文件'
/bin/busybox rm -f "$archive_entries"
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$1" ] || die 'RAM identity changed before formatting'
[ -b /dev/disk/by-partlabel/persist ] || die 'persist is missing'
mount -t ext4 -o ro,noload /dev/disk/by-partlabel/persist /run/persist
persist_mounted=true
for item in wlan/wlan_mac.bin bluetooth/.bt_nv.bin audio/crus_calr.bin; do
	[ -f "/run/persist/$item" ] || die 'factory data is incomplete'
done
[ -d /run/persist/sensors/registry/registry ] || die 'factory sensor registry is missing'
/bin/busybox blockdev --setrw "$parent"
opened=true
/bin/busybox blockdev --setrw "$root"
/bin/busybox blockdev --setrw "$home"
prepare_home "$home" "$keep_home"
# A filesystem UUID is generated here so /etc/fstab names the home filesystem by
# UUID (flat install contract); the root filesystem stays discoverable by LABEL=LIUQIN_ROOT
# exactly as the boot image expects.
root_uuid=$(cat /proc/sys/kernel/random/uuid)
case $root_uuid in *[!0-9a-f-]*|'') die 'could not generate a root filesystem UUID' ;; esac
/usr/sbin/mkfs.ext4 -F -L LIUQIN_ROOT -m 0 -U "$root_uuid" "$root"
mount -t ext4 "$root" /mnt/install
mounted=true
# flat install contract: FLAT install.  The partition root IS the rootfs root, exactly
# like root.img and the boot image's Fedora profile; there is no /native-root.
/usr/bin/tar -xzf "$archive" -C /mnt/install \
	--numeric-owner --same-owner --same-permissions --acls --xattrs --xattrs-include='*' --warning=no-timestamp
PERSIST_SRC=/run/persist sh /usr/lib/liuqin/provision.sh /mnt/install
if [ "$rescue" = ENABLE-USB-RESCUE ]; then
	touch /mnt/install/etc/liuqin-rescue-enabled
fi
# /home is a separate partition so that a later system reinstall can keep it.
# nofail keeps a missing or unreadable home partition from holding up the boot
# at the console-less first start.
mount -t ext4 "$home" /mnt/install-home
home_mounted=true
home_uuid=$(fs_uuid "$home") ||
	die 'could not read the home filesystem UUID' \
		'—— 无法读取 home 文件系统的 UUID'
if home_needs_skeleton /mnt/install-home "$keep_home" && [ -d /mnt/install/home ]; then
	/usr/bin/tar -C /mnt/install/home -cf - . --numeric-owner --acls --xattrs \
		--xattrs-include='*' | /usr/bin/tar -C /mnt/install-home -xf - \
		--numeric-owner --same-owner --same-permissions --acls --xattrs --xattrs-include='*' \
		--warning=no-timestamp
fi
if [ -n "$store" ]; then
	sh "$switch_store" /mnt/install \
		ubuntu "$store_ubuntu_url" "$store_ubuntu_sha" "$store_ubuntu_bytes" \
		android "$store_android_url" "$store_android_sha" "$store_android_bytes"
fi
{
	printf '# Written by the liuqin installer. The root filesystem is mounted by\n'
	printf '# the boot image, which finds it by LABEL=LIUQIN_ROOT.\n'
	printf 'UUID=%s\t/home\text4\tdefaults,nofail,x-systemd.device-timeout=30s\t0\t2\n' "$home_uuid"
} >/mnt/install/etc/fstab
chmod 0644 /mnt/install/etc/fstab
# FEDORA: extraction, provisioning and first-boot state.
# The shipped expectation list is derived from the real assembled rootfs (setuid/
# setgid + security.capability).  Numbers are reported so a truncation/drift is
# visible in the install log, and an empty list is recorded (not silently OK).
fedora_privileged_files /mnt/install /etc/liuqin-installer-privileges
printf 'liuqin-install: privileged metadata preserved (%s entries: %s setuid/setgid, %s capabilities)\n' \
	"$fpf_total" "$fpf_setuid" "$fpf_caps"
[ "$fpf_total" -gt 0 ] ||
	printf 'liuqin-install: note: the image declared no privileged files\n' >&2
fedora_desktop /mnt/install
# flat install contract: the extracted+configured tree must satisfy the same admission
# topology the boot image runs.  No mutable content hashes are compared; the
# marker content and the KDE topology are the fail-closed surface.
[ ! -e /mnt/install/native-root ] ||
	die 'the installation produced a nested native-root directory' \
		'—— 安装结果出现 native-root 嵌套目录（平铺安装失败）'
contract_apply /mnt/install
cleanup
# flat install contract: after the writes, remount read-only and re-run the admission
# check; this is the last gate before an install can be reported successful.
mount -t ext4 -o ro "$root" /mnt/install ||
	die 'could not remount the installed root read-only' \
		'—— 无法以只读方式重新挂载安装后的根文件系统'
mounted=true
contract_apply /mnt/install
fedora_privileged_files /mnt/install /etc/liuqin-installer-privileges
[ "$(cat /mnt/install/etc/machine-id 2>/dev/null || true)" = '' ] ||
	die 'the installed machine-id was not cleared' \
		'—— 安装后的 machine-id 未被清空'
[ ! -e /mnt/install/var/lib/systemd/random-seed ] ||
	die 'the installed root still ships var/lib/systemd/random-seed' \
		'—— 安装结果仍带随机种子文件'
/bin/busybox grep -q '^UUID=.*[[:space:]]/home[[:space:]]' /mnt/install/etc/fstab ||
	die 'the installed /etc/fstab has no UUID-based /home entry' \
		'—— 安装后的 /etc/fstab 没有按 UUID 的 /home 条目'
umount /mnt/install || die 'could not unmount the read-only recheck mount'
mounted=false
trap - EXIT HUP INT TERM
printf 'liuqin-install: ROOT_INSTALLED\n'
