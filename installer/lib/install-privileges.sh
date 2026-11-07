#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Privileged-file validation for the Fedora RAM installer (ADR-0004 D3/D4).
#
# The expectation list is NOT hardcoded here: scripts/build-image.sh scans the
# real assembled rootfs (every setuid/setgid file and every file carrying a
# security.capability xattr) and embeds /etc/liuqin-installer-privileges in
# installer.img.  This file only verifies that tar extraction preserved those
# exact modes/xattrs on the target root.
#
# Why this exists: a hardcoded "ping must carry cap_net_raw" check was wrong for
# Fedora 44 (iputils ping is mode 0755 and uses net.ipv4.ping_group_range), so a
# real installation aborted after extracting the rootfs.  At the same time real
# files do carry capabilities (e.g. /usr/bin/kwin_wayland cap_sys_nice=ep), so the
# check must be driven by the actual tree, not by a distribution guess.
#
# Expectation file format (comments start with '#'; one entry per line):
#   setuid <octal-mode> <absolute in-root path>
#   setgid <octal-mode> <absolute in-root path>
#   cap    <getcap-caps> <absolute in-root path>
#
# The caller must define die() and have the installer runtime on PATH
# (busybox stat, getcap); install-root.sh and the offline tests both do.

fedora_privileged_files() { # <target root> [expectations file]
	fpf_root=$1
	fpf_file=${2:-/etc/liuqin-installer-privileges}
	[ -f "$fpf_file" ] ||
		die 'the installer image carries no privileged-file expectations' \
			'—— 安装器镜像缺少特权文件期望列表（/etc/liuqin-installer-privileges）'
	fpf_total=0
	fpf_setuid=0
	fpf_caps=0
	while IFS=' ' read -r fpf_kind fpf_expect fpf_path; do
		case $fpf_kind in ''|'#'*) continue ;; esac
		case $fpf_path in
		/*) ;;
		*) die "malformed privileged-file expectation: $fpf_kind $fpf_expect $fpf_path" ;;
		esac
		fpf_total=$((fpf_total + 1))
		[ -f "$fpf_root$fpf_path" ] && [ ! -L "$fpf_root$fpf_path" ] ||
			die "privileged file is missing after extraction: $fpf_path" \
				'—— 解包后缺少构建期记录的 setuid/setgid/capability 文件'
		case $fpf_kind in
		setuid|setgid)
			fpf_got=$(/bin/busybox stat -c '%a' "$fpf_root$fpf_path" 2>/dev/null || true)
			[ "$fpf_got" = "$fpf_expect" ] ||
				die "privileged mode was not restored: $fpf_path is $fpf_got, not $fpf_expect" \
					'—— 根文件系统解包时丢失了 setuid/setgid 权限位'
			fpf_setuid=$((fpf_setuid + 1))
			;;
		cap)
			fpf_got=$(getcap "$fpf_root$fpf_path" 2>/dev/null || true)
			case $fpf_got in
			*"$fpf_expect"*) ;;
			*) die "file capabilities were not restored: $fpf_path has '$fpf_got', expected '$fpf_expect'" \
				'—— 根文件系统解包时丢失了文件 capability' ;;
			esac
			fpf_caps=$((fpf_caps + 1))
			;;
		*)
			die "unknown privileged-file expectation kind: $fpf_kind"
			;;
		esac
	done <"$fpf_file"
	if [ "$fpf_total" -eq 0 ]; then
		printf 'liuqin-install: warning: the embedded privileged-file expectation list is empty\n' >&2
	fi
	return 0
}
