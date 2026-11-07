#!/bin/sh
# SPDX-License-Identifier: MIT
# Build the Fedora installer RAM-image runtime from Fedora aarch64 packages.
#
# This is the Fedora replacement for upstream tools/lib/build-installer-runtime.py
# (which extracts the same seven tools from an Ubuntu root).  It delivers:
#
#   out/installer/pkgroot/          unpacked Fedora aarch64 package root (when downloaded)
#   out/installer/runtime/          the runtime tree: 7 tools + libs + mke2fs.conf + liuqin-reboot
#   out/installer/image-overlay/    everything the RAM image adds to the boot-builder initramfs
#                                   (runtime, device scripts, markers, Fedora root contract)
#   out/installer/SHA256SUMS        hashes of the runtime tree and the overlay
#   out/installer/logs/            container/build logs
#
# The final installer.img is assembled by the boot-builder pipeline
# (scripts/build-initramfs.sh + scripts/build-bootimg.sh, task-7): this script
# produces the INSTALLER_RUNTIME/overlay it consumes and refuses to pretend it
# can build a boot image without that pipeline.  Nothing here touches a device.
#
# Package sources, in order of preference:
#   --from-rootfs DIR   already-unpacked Fedora aarch64 root (e.g. a mkosi rootfs
#                       or out/rootfs/rootfs produced by task-6)
#   --from-rpms DIR     a directory of Fedora aarch64 *.rpm files
#   --download          (default) pull packages with dnf inside an emulated
#                       Fedora aarch64 container and export its rootfs
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=$project_root/out/installer
container=${LIUQIN_FEDORA_CONTAINER:-quay.io/fedora/fedora:45}
source_root=
from_rpms=
download=auto
force=0
verify=1
assemble=0
busybox=
contract=
privileges=
qemu=${QEMU_AARCH64:-$(command -v qemu-aarch64-static 2>/dev/null || true)}
downloaded_root=

usage() {
	printf '%s\n' \
		'usage: scripts/build-installer.sh [--from-rootfs DIR | --from-rpms DIR | --download]' \
		'                                  [--out DIR] [--force] [--no-verify]' \
		'                                  [--assemble [--busybox PATH] [--contract PATH] [--privileges PATH]]' \
		'' \
		'  --from-rootfs DIR  use an unpacked Fedora aarch64 root tree' \
		'  --from-rpms DIR    extract a directory of Fedora aarch64 RPMs into a root tree' \
		'  --download         (default) install the packages in a Fedora aarch64 container' \
		'  --assemble         also build out/installer/image-overlay for the boot-builder image' \
		'  --busybox PATH     static aarch64 BusyBox from the boot-builder pipeline' \
		'                     (recorded in the overlay manifest; required for the RAM image)' \
		'  --contract PATH    Fedora root admission contract v2 (single producer:
                     tools/build-root-contract.py; see ADR-0004 D1/D2)
  --privileges PATH  rootfs-derived privileged-file expectations
                     (setuid/setgid modes + security.capability xattrs; required
                     for installer.img, produced by scripts/build-image.sh)'
}
die() { printf 'build-installer: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-installer: %s\n' "$*"; }
run_logged() { # LOG COMMAND...
	rl_log=$1
	shift
	if "$@" >"$rl_log" 2>&1; then
		cat "$rl_log"
	else
		cat "$rl_log" >&2
		die "command failed (log: $rl_log): $*"
	fi
}

while [ "$#" -gt 0 ]; do
	case $1 in
	--from-rootfs) [ "$#" -ge 2 ] || die '--from-rootfs needs a directory'; source_root=$2; shift 2 ;;
	--from-rpms) [ "$#" -ge 2 ] || die '--from-rpms needs a directory'; from_rpms=$2; download=0; shift 2 ;;
	--download) download=1; shift ;;
	--out) [ "$#" -ge 2 ] || die '--out needs a directory'; out=$2; shift 2 ;;
	--container) [ "$#" -ge 2 ] || die '--container needs an image reference'; container=$2; shift 2 ;;
	--force) force=1; shift ;;
	--no-verify) verify=0; shift ;;
	--assemble) assemble=1; shift ;;
	--busybox) [ "$#" -ge 2 ] || die '--busybox needs a path'; busybox=$2; shift 2 ;;
	--contract) [ "$#" -ge 2 ] || die '--contract needs a path'; contract=$2; shift 2 ;;
	--privileges) [ "$#" -ge 2 ] || die '--privileges needs a path'; privileges=$2; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

command -v python3 >/dev/null || die 'python3 is required'
[ -x "$project_root/installer/build-runtime.py" ] ||
	die 'installer/build-runtime.py is missing from the project'

if [ -n "$source_root" ] && [ "$download" = 1 ]; then
	die '--from-rootfs and --download are mutually exclusive'
fi
if [ -z "$source_root" ] && [ -z "$from_rpms" ] && [ "$download" = auto ]; then
	download=1
fi
if [ "$download" = 1 ] && ! command -v podman >/dev/null; then
	die 'podman is required for --download; use --from-rootfs or --from-rpms'
fi

mkdir -p "$out" "$out/logs"
out=$(CDPATH= cd -- "$out" && pwd)
if [ "$force" = 1 ]; then
	# The package root may be a caller-supplied --from-rootfs tree; only the
	# generated runtime/overlay are removed here (the download modes recreate
	# their own package root).
	rm -rf "$out/runtime" "$out/image-overlay"
fi

# Proxy environment for the emulated container: the host's proxy is never the
# container's unless it is handed over explicitly.  Loopback proxies need
# --network host, which this script always uses (rootless pasta is unavailable
# on this host and the site does not need container isolation for a read-only
# package download).
podman_proxy_env() {
	podman_args=''
	for name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
		eval "value=\${$name:-}"
		[ -n "$value" ] || continue
		podman_args="$podman_args --env $name=$value"
	done
	printf '%s' "$podman_args"
}

container_script_download=$(cat <<'CONTAINER'
set -eu
dnf -q install -y tar coreutils e2fsprogs libcap gdisk
rpm -qa --qf '%{NAME} %{EVR}.%{ARCH}\n' | LC_ALL=C sort >/pkg-versions.txt
for tool in /usr/bin/tar /usr/bin/install /usr/sbin/mkfs.ext4 /usr/sbin/e2fsck \
	/usr/sbin/e2label /usr/sbin/getcap /usr/sbin/sgdisk /etc/mke2fs.conf; do
	[ -e "$tool" ] || { echo "missing from Fedora packages: $tool" >&2; exit 1; }
done
CONTAINER
)

download_pkgroot() {
	[ "$force" = 1 ] || [ ! -d "$out/pkgroot" ] || {
		say "reusing existing package root: $out/pkgroot"
		downloaded_root=$out/pkgroot
		return 0
	}
	log=$out/logs/podman-download.log
	say "installing Fedora aarch64 installer packages in $container (log: $log)"
	# shellcheck disable=SC2046
	podman rm -f liuqin-installer-runtime >/dev/null 2>&1 || true
	# shellcheck disable=SC2046
	podman run --name liuqin-installer-runtime --arch arm64 --network host $(podman_proxy_env) \
		"$container" sh -c "$container_script_download" >"$log" 2>&1 ||
		{ tail -30 "$log" >&2; podman rm -f liuqin-installer-runtime >/dev/null 2>&1 || true;
		  die "the Fedora package download failed (see $log)"; }
	podman export liuqin-installer-runtime >"$out/pkgroot.tar"
	podman rm -f liuqin-installer-runtime >/dev/null
	rm -rf "$out/pkgroot"
	mkdir -p "$out/pkgroot"
	tar -xf "$out/pkgroot.tar" -C "$out/pkgroot"
	rm -f "$out/pkgroot.tar"
	# Rootless podman exports uid-0 modes; make the copy ours so a rebuild can
	# replace it without sudo.
	chmod -R u+rwX "$out/pkgroot"
	downloaded_root=$out/pkgroot
}

extract_rpms() {
	rpm_dir=$(CDPATH= cd -- "$1" && pwd)
	ls "$rpm_dir"/*.rpm >/dev/null 2>&1 || die "no *.rpm files in $rpm_dir"
	log=$out/logs/podman-extract-rpms.log
	say "extracting ${rpm_dir}/*.rpm into a package root (log: $log)"
	podman run --rm --arch arm64 --network host $(podman_proxy_env) \
		-v "$rpm_dir:/rpms:ro" -v "$out:/out" "$container" sh -c '
		set -eu
		command -v cpio >/dev/null || dnf -q install -y cpio
		rm -rf /pkgroot; mkdir -p /pkgroot
		for rpm in /rpms/*.rpm; do rpm2cpio "$rpm" | cpio -idm -D /pkgroot >/dev/null 2>&1; done
		rm -f /out/pkgroot.tar
		tar -C /pkgroot -cf /out/pkgroot.tar .
	' >"$log" 2>&1 || { tail -30 "$log" >&2; die "RPM extraction failed (see $log)"; }
	rm -rf "$out/pkgroot"; mkdir -p "$out/pkgroot"
	tar -xf "$out/pkgroot.tar" -C "$out/pkgroot"
	rm -f "$out/pkgroot.tar"
	chmod -R u+rwX "$out/pkgroot"
}

if [ -n "$source_root" ]; then
	[ -d "$source_root" ] || die "not a directory: $source_root"
	source_root=$(CDPATH= cd -- "$source_root" && pwd)
	# A Fedora aarch64 root always has at least one aarch64 ELF under /usr/bin.
	if ! find "$source_root/usr/bin" -maxdepth 1 -type f 2>/dev/null | head -1 | grep -q .; then
		die "not an unpacked Fedora root tree (no /usr/bin files): $source_root"
	fi
	[ -f "$source_root/etc/mke2fs.conf" ] ||
		die "the package root has no /etc/mke2fs.conf; e2fsprogs was not installed: $source_root"
	say "package source: $source_root"
elif [ -n "$from_rpms" ]; then
	extract_rpms "$from_rpms"
	source_root=$out/pkgroot
	say "package source: $out/pkgroot (extracted RPMs)"
else
	download_pkgroot
	[ -n "$downloaded_root" ] || die 'the package download produced no root'
	source_root=$downloaded_root
	say "package source: $source_root (Fedora container)"
fi

rm -rf "$out/runtime"
run_logged "$out/logs/build-runtime.log" python3 "$project_root/installer/build-runtime.py" \
	--root "$source_root" --out "$out/runtime"

if [ "$verify" = 1 ]; then
	if [ -n "$qemu" ] && [ -x "$qemu" ]; then
		run_logged "$out/logs/verify-runtime.log" python3 "$project_root/installer/build-runtime.py" \
			--verify "$out/runtime" --qemu "$qemu"
	else
		run_logged "$out/logs/verify-runtime.log" python3 "$project_root/installer/build-runtime.py" \
			--verify "$out/runtime"
		say 'qemu-aarch64-static is unavailable: verified hashes/ELF only, not execution'
	fi
fi

(
	cd "$out/runtime"
	find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
		printf '%s  runtime/%s\n' "$(sha256sum "$file" | cut -d' ' -f1)" "${file#./}"
	done
) >"$out/runtime-SHA256SUMS"

if [ "$assemble" = 1 ]; then
	set -- python3 "$project_root/installer/assemble-installer.py" \
		--runtime "$out/runtime" --out "$out/image-overlay" \
		--source-date-epoch "${SOURCE_DATE_EPOCH:-0}"
	[ -z "$busybox" ] || set -- "$@" --busybox "$busybox"
	[ -z "$contract" ] || set -- "$@" --contract "$contract"
	[ -z "$privileges" ] || set -- "$@" --privileges "$privileges"
	run_logged "$out/logs/assemble-installer.log" "$@"
	(
		cd "$out/image-overlay"
		find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
			printf '%s  image-overlay/%s\n' "$(sha256sum "$file" | cut -d' ' -f1)" "${file#./}"
		done
	) >"$out/image-overlay-SHA256SUMS"
fi

say 'runtime ready; no device access'
say 'next: boot-builder (scripts/build-initramfs.sh with INSTALLER_RUNTIME='"$out/image-overlay"','
say '      then scripts/build-bootimg.sh) produces installer.img; see docs/build/installer.md'
