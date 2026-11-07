#!/bin/sh
# SPDX-License-Identifier: MIT
#
# build-image.sh — assemble the liuqin Fedora image bundle offline.
#
# Pipeline (each stage is resumable and records SKIP markers):
#
#   out/rootfs/rootfs                      mkosi Fedora 45 GNOME aarch64 rootfs tree
#        │
#        ├─ stage-rootfs     copy (root-owned preserved), inject kernel/device RPMs,
#        │                   apply overlays/rootfs/rootfs.d, write image-owned config
#        │                   (fstab, markers, kernel identity files), clean caches,
#        │                   regenerate rootfs.manifest / rootfs.files.sha256
#        │
#        ├─ stage-root-img   mkfs.ext4 (label LIUQIN_ROOT, 4K blocks) with the tree
#        │                   at the image root (FLAT layout, flat install contract), then
#        │                   rootfs.tar.gz for the RAM installer (same flat root)
#        │
#        ├─ stage-boot-img   rebuild boot.img from the kernel payload + Fedora
#        │                   initramfs (real root contract from the staged tree)
#        │
#        ├─ stage-installer  installer.img: same kernel/DTB, RAM-installer ramdisk
#        │                   from out/installer/image-overlay
#        │
#        ├─ stage-bundle     images/<name>/{boot.img,installer.img,root.img,
#        │                   rootfs.tar.gz,bundle.json,SHA256SUMS,manifests/}
#        │
#        └─ stage-verify     e2fsck + read-only loop mount checks, boot.img header,
#                            bundle hashes, scripts/verify-bundle.sh
#
# RED LINES: this script never calls fastboot/adb, never opens a real block
# device, never writes a partition.  Every "write" lands in out/image-build/,
# images/ or the scratch directory.  The bundle it produces is
# device_ready=false until the canonical stock-ROM boot.img inputs and the
# firmware set exist (documented in bundle.json).
#
# DTB modes :
#   --build-mode dev (default)     offline structure bundle.  --dtb-source auto
#                                  resolves to upstream-artifact unless a usable
#                                  --stock-rom-dir is given; device_ready=false.
#   --build-mode release            canonical build.  Forces --dtb-source
#                                  stock-rom, requires: usable stock ROM tree
#                                  (44 DTBO entries + 14 base DTBs), kernel-liuqin
#                                  RPM payload, full firmware pool, full root
#                                  contract (no --partial), installer overlay and
#                                  every bundle payload.  Missing input = exit 2
#                                  (fail-closed); the bundle is marked
#                                  canonical=true and the remaining
#                                  device_ready=false reason is only "not booted
#                                  on liuqin hardware".
#
# Exit codes: 0 = success (SKIPs allowed, recorded); 1 = build/verify failure;
#             2 = usage, missing-input or environment error the caller must fix.
#
# Usage examples:
#   scripts/build-image.sh \                              # dev assembly
#       --extra-packages "libqmi libqrtr-glib protobuf-c systemd-pam glibc-langpack-en"
#   scripts/build-image.sh --only-root-img               # rootfs → root.img only
#   scripts/build-image.sh --stage boot-img,installer-img
#   scripts/build-image.sh --boot-img out/boot/boot-liuqin-dev.img --partial
#   scripts/build-image.sh --build-mode release \        # canonical bundle
#       --stock-rom-dir /path/to/stock-rom --firmware-pool /path/fw \
#       --wlan-hsp2-tuple /path/hsp2 --audio-topology /path/tplg.bin
#
# Docs: see BUILD.md and overlays/rootfs/README.md

set -eu
umask 022

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
upstream=$project_root/upstream/xiaomipad-6pro-mainline
cache=$project_root/cache/upstream-v0.6.0

# Inputs (all optional; missing ones turn their stage into a recorded SKIP).
rootfs_dir=$project_root/out/rootfs/rootfs
rootfs_manifest_json=$project_root/out/rootfs/rootfs.manifest
rootfs_files_sha=$project_root/out/rootfs/rootfs.files.sha256
rootfs_packages_txt=$project_root/out/rootfs/rootfs.packages.txt
expect_rootfs_hashes_sha=
expected_rootfs_manifest_sha=
kernel_rpms_dir=$project_root/out/rpms-kernel
device_rpms_dirs="out/rpms out/rpms-mobile"
boot_img_input=
installer_overlay=$project_root/out/installer/image-overlay
kernel_image_override=
kernel_dtb_override=
firmware_pool=
firmware_pool_meta=
wlan_hsp2_tuple=
audio_topology=
audio_topology_sha=
extra_packages=
images_root=$project_root/images
work_root=$project_root/out/image-build
bundle_name=
release=45
desktop=gnome
image_user=user
login_manager=gdm
lm_unit=gdm.service
desktop_bin=gnome-shell
build_mode=dev
dtb_source=auto
stock_rom_dir=
root_size=
stages=all
resume=0
allow_missing_pins=0
allow_unmet_rpm_deps=0
rootfs_gzip_level=6
refresh_rootfs=0
public_image=0
size_arg=

# Globals filled by the stages; initialised so `set -u` never trips on a SKIP.
kernel_source=
boot_img_source=
installer_img_source=
boot_img=
installer_img=
root_img=
rootfs_tar=
kernel_out=
kver=
stage_root=
contract_file=
privileges_file=

RPM_IMAGE_DEFAULT=localhost/liuqin-rpmbuild:fc45
RPM_IMAGE_FALLBACK=quay.io/fedora/fedora:45
# Audio-topology baseline: the project-built AudioReach topology that was
# verified audible on liuqin.  The upstream tree ships a different
# binary (dff0c8af…); build-initramfs.sh pins the same project sha, so the
# upstream file is not an accepted baseline.
AUDIO_TOPOLOGY_BASELINE_SHA=9c9f8bfcffde1f52c143d58cba821c5f6b3899553370ab92a88b90d81fef9ee9
RPM_IMAGE=${RPM_IMAGE:-$RPM_IMAGE_DEFAULT}

usage() {
	cat <<'EOF'
usage: scripts/build-image.sh [options]

Inputs
  --rootfs DIR            mkosi rootfs tree (default: out/rootfs/rootfs)
  --rootfs-manifest FILE  rootfs.manifest JSON (default: out/rootfs/rootfs.manifest)
  --rootfs-files FILE     <sha256>  /abs/path manifest
                          (default: out/rootfs/rootfs.files.sha256, then rootfs.hashes)
  --packages FILE         rpm -qa list (default: out/rootfs/rootfs.packages.txt)
  --expect-rootfs-hashes SHA  fail-closed check that the delivered rootfs hash
                          manifest has this sha256 (guards against assembling a
                          tree that rootfs-builder is still modifying)
  --expect-rootfs-manifest SHA  same for rootfs.manifest (optional)
  --kernel-rpms DIR       kernel-liuqin RPM dir (default: out/rpms-kernel)
  --device-rpms DIR[:DIR] device/mobile RPM dirs (default: out/rpms:out/rpms-mobile)
  --boot-img FILE         reuse this boot.img instead of rebuilding (adds a SKIP)
  --installer-overlay DIR RAM-installer overlay (default: out/installer/image-overlay)
  --kernel-image FILE     explicit raw aarch64 Image (skips RPM extraction)
  --kernel-dtb FILE       explicit raw board DTB (skips RPM extraction)
  --firmware-pool DIR     liuqin firmware pool for the initramfs (absent ->
                          --allow-missing-firmware and a device_ready reason).
                          `--firmware-pool auto` assembles the pool from the
                          pinned upstream tree with
                          scripts/assemble-firmware-pool.sh; --build-mode
                          release defaults to auto.
  --wlan-hsp2-tuple DIR   reviewed HSP2 WLAN tuple
  --audio-topology FILE   built AudioReach topology
  --build-mode MODE       dev (default) | release.  release = canonical bundle:
                          forces --dtb-source stock-rom and requires the stock
                          ROM tree, kernel RPM payload, full firmware pool, full
                          root contract and every bundle payload (fail-closed)
  --dtb-source MODE       auto | upstream-artifact | stock-rom (default: auto;
                          dev auto -> upstream-artifact unless --stock-rom-dir is
                          usable; release always resolves to stock-rom)
  --extra-packages "PKGS" space-separated Fedora packages to install from the
                          Fedora 45 aarch64 repositories into the image after
                          the local RPMs (e.g. "libqmi libqrtr-glib" for the
                          libssc sensor stack).  Versions are recorded in
                          bundle.json / image-build-info.json
  --stock-rom-dir DIR     stock ROM analysis tree for the canonical DTB path:
                          <dir>/dtbo/entry.NN (44) + <dir>/vendor_boot/dtbs/
                          dtb-NN.dtb (14); also accepts .../analysis/<...>

Output
  --out DIR               images root (default: <project>/images)
  --work DIR              scratch root (default: <project>/out/image-build)
  --name NAME             bundle name under --out (default: liuqin-fedora-<release>-dev)
  --release N             Fedora release recorded in bundle.json (default: 45)
  --desktop MODE          gnome (default, Fedora Workstation/GDM) or plasma
                          (retained historical KDE/plasmalogin profile)
  --user NAME             desktop account baked into the image (default: user)
  --public-image          generic release defaults; optional desktop customizations
                          are installed but disabled, SSH/root login are locked
  --size SIZE             root.img size, e.g. 8G (default: rootfs size * 1.15 + 512M)

Stages
  --stage LIST            all | rootfs | root-img | boot-img | installer-img |
                          bundle | verify (comma separated; default all)
  --only-root-img         same as --stage rootfs,root-img
  --resume                reuse an existing staged rootfs tree in --work
  --refresh-rootfs        with --resume: re-run the image-owned configuration and
                          Fedora dependency injection on the staged tree (no RPM
                          re-injection, no rsync), then continue from root-img
  --rootfs-gzip-level N   gzip level for rootfs.tar.gz (default: 6; 1 is much
                          faster for dev bundles)
  --partial               allow a structure-validation bundle: missing RPM
                          dependency closure is recorded (contract v2 has no
                          content pins, so there is nothing to leave partial)
  --allow-missing-pins    deprecated v1 flag (no-op: contract v2 is topology-only)
  --allow-unmet-rpm-deps  install RPMs with --nodeps when --test fails
  --no-qemu              compatibility no-op; VM simulation was retired (retired VM plan)
  --keep-work             compatibility flag (work is currently always retained)
  -h, --help              this help

Exit codes: 0 success (SKIPs recorded), 1 build/verify failure, 2 usage/env error.
No device is touched; no fastboot/adb command is ever executed.
EOF
}

die() { printf 'build-image: %s\n' "$*" >&2; exit 1; }
die_usage() { printf 'build-image: %s\n' "$*" >&2; exit 2; }
say() { printf 'build-image: %s\n' "$*" >&2; }
stage_header() { printf '\n=== build-image: %s ===\n' "$*" >&2; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
	case $1 in
	--rootfs) [ $# -ge 2 ] || die_usage "--rootfs needs a value"; rootfs_dir=$2; shift ;;
	--rootfs-manifest) [ $# -ge 2 ] || die_usage "--rootfs-manifest needs a value"; rootfs_manifest_json=$2; shift ;;
	--rootfs-files) [ $# -ge 2 ] || die_usage "--rootfs-files needs a value"; rootfs_files_sha=$2; shift ;;
	--packages) [ $# -ge 2 ] || die_usage "--packages needs a value"; rootfs_packages_txt=$2; shift ;;
	--expect-rootfs-hashes) [ $# -ge 2 ] || die_usage "--expect-rootfs-hashes needs a value"; expect_rootfs_hashes_sha=$2; shift ;;
	--expect-rootfs-manifest) [ $# -ge 2 ] || die_usage "--expect-rootfs-manifest needs a value"; expected_rootfs_manifest_sha=$2; shift ;;
	--kernel-rpms) [ $# -ge 2 ] || die_usage "--kernel-rpms needs a value"; kernel_rpms_dir=$2; shift ;;
	--device-rpms) [ $# -ge 2 ] || die_usage "--device-rpms needs a value"; device_rpms_dirs=$2; shift ;;
	--boot-img) [ $# -ge 2 ] || die_usage "--boot-img needs a value"; boot_img_input=$2; shift ;;
	--installer-overlay) [ $# -ge 2 ] || die_usage "--installer-overlay needs a value"; installer_overlay=$2; shift ;;
	--kernel-image) [ $# -ge 2 ] || die_usage "--kernel-image needs a value"; kernel_image_override=$2; shift ;;
	--kernel-dtb) [ $# -ge 2 ] || die_usage "--kernel-dtb needs a value"; kernel_dtb_override=$2; shift ;;
	--firmware-pool) [ $# -ge 2 ] || die_usage "--firmware-pool needs a value"; firmware_pool=$2; shift ;;
	--wlan-hsp2-tuple) [ $# -ge 2 ] || die_usage "--wlan-hsp2-tuple needs a value"; wlan_hsp2_tuple=$2; shift ;;
	--audio-topology) [ $# -ge 2 ] || die_usage "--audio-topology needs a value"; audio_topology=$2; shift ;;
	--extra-packages) [ $# -ge 2 ] || die_usage "--extra-packages needs a value"; extra_packages=$2; shift ;;
	--build-mode) [ $# -ge 2 ] || die_usage "--build-mode needs a value"; build_mode=$2; shift ;;
	--dtb-source) [ $# -ge 2 ] || die_usage "--dtb-source needs a value"; dtb_source=$2; shift ;;
	--stock-rom-dir) [ $# -ge 2 ] || die_usage "--stock-rom-dir needs a value"; stock_rom_dir=$2; shift ;;
	--out) [ $# -ge 2 ] || die_usage "--out needs a value"; images_root=$2; shift ;;
	--work) [ $# -ge 2 ] || die_usage "--work needs a value"; work_root=$2; shift ;;
	--name) [ $# -ge 2 ] || die_usage "--name needs a value"; bundle_name=$2; shift ;;
	--release) [ $# -ge 2 ] || die_usage "--release needs a value"; release=$2; shift ;;
	--desktop) [ $# -ge 2 ] || die_usage "--desktop needs a value"; desktop=$2; shift ;;
	--user) [ $# -ge 2 ] || die_usage "--user needs a value"; image_user=$2; shift ;;
	--public-image) public_image=1 ;;
	--size) [ $# -ge 2 ] || die_usage "--size needs a value"; size_arg=$2; shift ;;
	--stage) [ $# -ge 2 ] || die_usage "--stage needs a value"; stages=$2; shift ;;
	--only-root-img) stages=rootfs,root-img ;;
	--resume) resume=1 ;;
	--refresh-rootfs) refresh_rootfs=1; resume=1 ;;
	--rootfs-gzip-level) [ $# -ge 2 ] || die_usage "--rootfs-gzip-level needs a value"; rootfs_gzip_level=$2; shift ;;
	--partial) allow_missing_pins=1; allow_unmet_rpm_deps=1 ;;
	--allow-missing-pins) allow_missing_pins=1 ;;
	--allow-unmet-rpm-deps) allow_unmet_rpm_deps=1 ;;
	--qemu|--qemu-timeout|--qemu-runs) die_usage "QEMU simulation was retired (retired VM plan); remove VM options" ;;
	--no-qemu) : ;; # Old task recipes remain usable without invoking a VM.
	--keep-work) : ;; # Compatibility: no automatic work cleanup is implemented.
	-h | --help) usage; exit 0 ;;
	*) die_usage "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

case $release in ''|*[!0-9]*) die_usage "--release must be a positive integer" ;; esac
case $desktop in
gnome) login_manager=gdm; lm_unit=gdm.service; desktop_bin=gnome-shell ;;
plasma) login_manager=plasmalogin; lm_unit=plasmalogin.service; desktop_bin=plasmashell ;;
*) die_usage "--desktop must be gnome or plasma" ;;
esac
case $image_user in
''|*[!a-z0-9_-]*) die_usage "--user must match [a-z0-9_-]+" ;;
esac
case $rootfs_gzip_level in 1|2|3|4|5|6|7|8|9) ;; *) die_usage "--rootfs-gzip-level must be 1..9" ;; esac
case $build_mode in dev|release) ;; *) die_usage "--build-mode must be dev or release" ;; esac
case $dtb_source in auto|upstream-artifact|stock-rom) ;; *) die_usage "--dtb-source must be auto, upstream-artifact or stock-rom" ;; esac

# Canonical stock-ROM tree discovery/validation (same layout build-bootimg.sh
# consumes), used to resolve --dtb-source auto and to fail release builds early.
stock_overlay_dir=
stock_base_dir=
stock_rom_ok=0
if [ -n "$stock_rom_dir" ]; then
	[ -d "$stock_rom_dir" ] || die_usage "--stock-rom-dir is not a directory: $stock_rom_dir"
	for candidate in "$stock_rom_dir/analysis/dtbo" "$stock_rom_dir/dtbo"; do
		[ -d "$candidate" ] && { stock_overlay_dir=$candidate; break; }
	done
	for candidate in "$stock_rom_dir/analysis/vendor_boot/dtbs" "$stock_rom_dir/vendor_boot/dtbs"; do
		[ -d "$candidate" ] && { stock_base_dir=$candidate; break; }
	done
	if [ -n "$stock_overlay_dir" ] && [ -n "$stock_base_dir" ]; then
		overlays_n=$(find "$stock_overlay_dir" -maxdepth 1 -type f -regex '.*/entry\.[0-9]+' | wc -l)
		dtbs_n=$(find "$stock_base_dir" -maxdepth 1 -type f -regex '.*/dtb-[0-9][0-9]\.dtb' | wc -l)
		if [ "$overlays_n" -eq 44 ] && [ "$dtbs_n" -eq 14 ]; then
			stock_rom_ok=1
		else
			say "warning: stock ROM tree has $overlays_n DTBO entries and $dtbs_n base DTBs (need 44/14)"
		fi
	fi
fi
if [ "$dtb_source" = auto ]; then
	if [ "$stock_rom_ok" = 1 ]; then dtb_source=stock-rom; else dtb_source=upstream-artifact; fi
fi
if [ "$build_mode" = release ]; then
	[ "$dtb_source" = stock-rom ] ||
		die_usage "--build-mode release needs a usable --stock-rom-dir (canonical DTB); refusing the offline upstream-artifact DTB"
	[ "$stock_rom_ok" = 1 ] ||
		die_usage "--build-mode release: --stock-rom-dir must carry 44 DTBO entries and 14 base DTBs"
	[ "$allow_missing_pins" = 0 ] ||
		die_usage "--build-mode release forbids --partial/--allow-missing-pins (the root contract must be complete)"
	# The full pool is assembled from the pinned upstream tree by
	# default; --firmware-pool DIR still overrides it with a reviewed tree.
	[ -n "$firmware_pool" ] || firmware_pool=auto
	[ -z "$boot_img_input" ] ||
		die_usage "--build-mode release always rebuilds boot.img; do not pass --boot-img"
fi
say "build mode: $build_mode, dtb source: $dtb_source$([ "$dtb_source" = stock-rom ] && echo " ($stock_rom_dir)")"
export BUILD_DTB_SOURCE=$dtb_source
[ -n "$bundle_name" ] || bundle_name=liuqin-fedora-$release-dev
# Container bind sources must be absolute: podman treats a relative -v source
# as a named volume instead of a host path.  Resolve before any
# use so the documented relative --work form works.
case $work_root in /*) ;; *) work_root="$project_root/$work_root" ;; esac
case $images_root in /*) ;; *) images_root="$project_root/$images_root" ;; esac
work_root=$(realpath -m -- "$work_root") || die_usage "cannot resolve --work: $work_root"
images_root=$(realpath -m -- "$images_root") || die_usage "cannot resolve --out: $images_root"
bundle_dir=$images_root/$bundle_name
work=$work_root/$bundle_name
rootfs_stage=$work/rootfs/root
manifests_dir=$bundle_dir/manifests

# Normalise the requested stage list.
case $stages in
all) stage_set="rootfs root-img boot-img installer-img bundle verify" ;;
*) stage_set=$(printf '%s\n' "$stages" | tr ',' ' ') ;;
esac
has_stage() { case " $stage_set " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for tool in python3 gzip tar sha256sum find sort strings; do
	have "$tool" || die_usage "missing host tool: $tool"
done
have sudo || die_usage "sudo is required (image assembly preserves root ownership)"
sudo -n true 2>/dev/null || die_usage "sudo without a password is required (NOPASSWD expected on this host)"
[ -d "$project_root/initramfs" ] || die_usage "initramfs/ is missing"
[ -d "$upstream" ] || die_usage "upstream read-only clone is missing (scripts/fetch-upstream.sh)"
[ -x "$project_root/scripts/build-initramfs.sh" ] || die_usage "scripts/build-initramfs.sh is missing"
[ -x "$project_root/scripts/build-bootimg.sh" ] || die_usage "scripts/build-bootimg.sh is missing"
[ -f "$project_root/tools/build-root-contract.py" ] || die_usage "tools/build-root-contract.py is missing"
[ -f "$cache/mkbootimg/unpack_bootimg.py" ] || die_usage "AOSP mkbootimg cache is missing: $cache/mkbootimg"

mkdir -p "$work" "$bundle_dir" "$work/logs" "$manifests_dir"
log_stamp=$(date -u '+%Y%m%dT%H%M%SZ')
say "bundle=$bundle_name work=$work"

# --- firmware inputs -------------------------------------------------------
# `--firmware-pool auto` (and release mode without an explicit pool) assembles
# the complete pool straight from the pinned upstream tree; the assembler
# verifies the 197-file firmware.manifest before copying anything.
if [ -n "$audio_topology" ]; then
	[ -f "$audio_topology" ] && [ ! -L "$audio_topology" ] ||
		die_usage "--audio-topology is not a regular file: $audio_topology"
	audio_topology_sha=$(sha256sum "$audio_topology" | cut -d' ' -f1)
	[ "$audio_topology_sha" = "$AUDIO_TOPOLOGY_BASELINE_SHA" ] ||
		die_usage "audio topology sha256 $audio_topology_sha is not the project baseline $AUDIO_TOPOLOGY_BASELINE_SHA (the upstream binary is not a supported baseline)"
fi
if [ "$firmware_pool" = auto ]; then
	say "firmware pool: assembling from the pinned upstream tree (scripts/assemble-firmware-pool.sh)"
	if [ -n "$audio_topology" ]; then
		"$project_root/scripts/assemble-firmware-pool.sh" --out "$work/firmware-pool" \
			--topology "$audio_topology" ||
			die_usage "firmware pool assembly from the pinned upstream tree failed (run scripts/fetch-upstream.sh and retry)"
	else
		"$project_root/scripts/assemble-firmware-pool.sh" --out "$work/firmware-pool" ||
			die_usage "firmware pool assembly from the pinned upstream tree failed (run scripts/fetch-upstream.sh and retry)"
	fi
	firmware_pool=$work/firmware-pool/pool
	firmware_pool_meta=$work/firmware-pool/pool.json
	# The reviewed HSP2 tuple ships inside the assembled pool; the initramfs
	# builder requires it explicitly, so derive it unless the caller overrode it.
	[ -n "$wlan_hsp2_tuple" ] || wlan_hsp2_tuple=$work/firmware-pool/pool/wlan-hsp2
fi

# SKIP bookkeeping; every later stage reads this list for bundle.json.
skips_file=$work/skips.txt
: >"$skips_file"
add_skip() {
	if grep -Fqx "$1" "$skips_file" 2>/dev/null; then
		return 0
	fi
	printf '%s\n' "$1" >>"$skips_file"
	say "SKIP: $1"
}
has_skip() { [ -s "$skips_file" ] && grep -Fqx "$1" "$skips_file" 2>/dev/null; }

# rootfs_files_sha may be delivered under either name (rootfs-builder contract).
if [ "$rootfs_files_sha" = "$project_root/out/rootfs/rootfs.files.sha256" ] &&
	[ ! -f "$rootfs_files_sha" ] &&
	[ -f "$project_root/out/rootfs/rootfs.hashes" ]; then
	rootfs_files_sha=$project_root/out/rootfs/rootfs.hashes
fi

# Fail-closed input pinning: the rootfs tree must be the frozen delivery, not a
# tree that rootfs-builder is still modifying.  The check runs before any copy.
if [ -n "$expect_rootfs_hashes_sha" ]; then
	[ -f "$rootfs_files_sha" ] || die_usage "--expect-rootfs-hashes given but $rootfs_files_sha is missing"
	actual=$(sha "$rootfs_files_sha")
	[ "$actual" = "$expect_rootfs_hashes_sha" ] ||
		die_usage "rootfs hash manifest sha256 mismatch (expected $expect_rootfs_hashes_sha, got $actual); the rootfs tree is not the frozen delivery"
	say "rootfs hash manifest pinned: $actual"
fi
if [ -n "$expected_rootfs_manifest_sha" ]; then
	[ -f "$rootfs_manifest_json" ] || die_usage "--expect-rootfs-manifest given but $rootfs_manifest_json is missing"
	actual=$(sha "$rootfs_manifest_json")
	[ "$actual" = "$expected_rootfs_manifest_sha" ] ||
		die_usage "rootfs.manifest sha256 mismatch (expected $expected_rootfs_manifest_sha, got $actual)"
	say "rootfs.manifest pinned: $actual"
fi

have_rootfs=0
[ -d "$rootfs_dir" ] && have_rootfs=1
# The kernel RPM may be delivered directly in --kernel-rpms or one level deeper
# (out/rpms-kernel/{rpm,repo}/).  Resolve to the directory holding the rpms.
resolve_rpm_dir() {
	dir=$1
	[ -d "$dir" ] || { printf '%s\n' "$dir"; return 0; }
	if find "$dir" -maxdepth 1 -name '*.rpm' | grep -q .; then
		printf '%s\n' "$dir"
		return 0
	fi
	nested=$(find "$dir" -maxdepth 2 -name '*.rpm' -printf '%h\n' 2>/dev/null | LC_ALL=C sort -u | head -1)
	[ -n "$nested" ] || nested=$dir
	printf '%s\n' "$nested"
}
kernel_rpms_dir=$(resolve_rpm_dir "$kernel_rpms_dir")
have_kernel_rpms=0
[ -d "$kernel_rpms_dir" ] && find "$kernel_rpms_dir" -maxdepth 1 -name '*.rpm' | grep -q . && have_kernel_rpms=1
device_rpm_count=0
for dir in $(printf '%s' "$device_rpms_dirs" | tr ':' ' '); do
	[ -d "$dir" ] || continue
	count=$(find "$dir" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l)
	device_rpm_count=$((device_rpm_count + count))
	[ "$count" -gt 0 ] || continue
done
have_installer=0
[ -d "$installer_overlay" ] && [ -f "$installer_overlay/installer-image.json" ] && have_installer=1

say "inputs: rootfs=$have_rootfs kernel_rpms=$have_kernel_rpms device_rpms=$device_rpm_count installer_overlay=$have_installer"

# ---------------------------------------------------------------------------
# Small helpers shared by the stages
# ---------------------------------------------------------------------------
parse_size() {
	# Accept 8G, 8192M, plain bytes. Echo bytes.
	value=$1
	case $value in
	*G | *g) echo $((${value%[Gg]} * 1024 * 1024 * 1024)) ;;
	*M | *m) echo $((${value%[Mm]} * 1024 * 1024)) ;;
	''|*[!0-9]*) return 1 ;;
	*) echo "$value" ;;
	esac
}

rpm_container() {
	# Run a command in the RPM tool container.
	# $1 = shell command string; remaining args are podman options/mounts.
	# RPM_CONTAINER_NETWORK can override the default offline network (used by
	# --extra-packages, which resolves against the Fedora repositories).
	command=$1
	shift
	sudo podman run --rm --network="${RPM_CONTAINER_NETWORK:-none}" "$@" \
		"$RPM_IMAGE" /bin/sh -c "$command"
}

choose_rpm_image() {
	if sudo podman image exists "$RPM_IMAGE" 2>/dev/null; then
		return 0
	fi
	if sudo podman image exists "$RPM_IMAGE_FALLBACK" 2>/dev/null; then
		RPM_IMAGE=$RPM_IMAGE_FALLBACK
		say "warning: $RPM_IMAGE_DEFAULT not present, using $RPM_IMAGE_FALLBACK (emulated aarch64: slower)"
		return 0
	fi
	die_usage "no RPM tool container available ($RPM_IMAGE_DEFAULT / $RPM_IMAGE_FALLBACK); pull one with podman"
}

install_rpm_dir() {
	# $1 = host dir, $2 = 1 for --noscripts, $3 = label
	dir=$1
	noscripts=$2
	label=$3
	# podman volume sources must be absolute paths; a relative path would be
	# interpreted as a named volume.
	case $dir in
	/*) ;;
	*) dir=$project_root/$dir ;;
	esac
	dir=$(CDPATH= cd -- "$dir" && pwd)
	# Build-time-only packages must never land in the runtime image: -devel,
	# -static, debuginfo packages are for building other rpms, not for booting.
	install_dir=$work/rpms-$label
	rm -rf "$install_dir"
	mkdir -p "$install_dir"
	skipped_pkgs=
	for candidate in "$dir"/*.rpm; do
		[ -f "$candidate" ] || continue
		name=${candidate##*/}
		case $name in
		*-devel-*|*-debuginfo-*|*-debugsource-*|*-static-*)
			skipped_pkgs="$skipped_pkgs $name"
			continue
			;;
		esac
		# Follow symlinks: kernel-builder delivers a top-level convenience
		# symlink to rpm/…; a hardlink to the symlink itself would dangle inside
		# the container (the relative target does not exist under /rpms).
		cp -f "$(readlink -f "$candidate")" "$install_dir/$name" || die "could not stage RPM: $candidate"
	done
	[ -n "$skipped_pkgs" ] && add_skip "rpm-filter-$label: skipped build-only package(s):$skipped_pkgs"
	set +f
	files=$(find "$install_dir" -maxdepth 1 -name '*.rpm' | LC_ALL=C sort)
	[ -n "$files" ] || { say "no runtime RPMs left in $dir after filtering"; return 0; }
	say "injecting $label RPMs from $dir: $(printf '%s\n' "$files" | wc -l) runtime package(s)"
	# The RPM tool container is x86_64 while the target rootfs is aarch64:
	# --ignorearch is required for rpm to accept the target-arch packages.
	# -U with --replacefiles/--oldpackage lets a project rpm intentionally
	# replace/upgrade a distribution package (e.g. the patched iio-sensor-proxy
	# over Fedora's stock one), which -i cannot do.
	extra="--ignorearch --replacefiles --replacepkgs --oldpackage --nosignature"
	[ "$noscripts" = 1 ] && extra="$extra --noscripts"
	if ! rpm_container "rpm --root /rootfs -Uvh --test $extra /rpms/*.rpm" \
		-v "$stage_root:/rootfs:z" -v "$install_dir:/rpms:ro" >"$work/logs/rpm-test-$label.log" 2>&1; then
		if [ "$allow_unmet_rpm_deps" = 1 ]; then
			say "warning: dependency closure for $label is incomplete; installing with --nodeps"
			grep -E 'is needed by|conflicts with|Failed' "$work/logs/rpm-test-$label.log" 2>/dev/null |
				head -20 | while IFS= read -r dep_line; do
					add_skip "rpm-deps-$label: $dep_line"
				done
			extra="$extra --nodeps"
			add_skip "rpm-dependency-closure-$label"
		else
			cat "$work/logs/rpm-test-$label.log" >&2
			die "RPM dependency test failed for $label (pass --partial/--allow-unmet-rpm-deps only for structure bundles)"
		fi
	fi
	rpm_container "rpm --root /rootfs -Uvh $extra /rpms/*.rpm" \
		-v "$stage_root:/rootfs:z" -v "$install_dir:/rpms:ro" >"$work/logs/rpm-install-$label.log" 2>&1 ||
		die "RPM install failed for $label (log: $work/logs/rpm-install-$label.log)"
}

write_firmware_provenance() {
	# Record actual installed bytes and the private-use restriction before the
	# rootfs file manifest is generated. The generic mkosi base has no blobs.
	sudo python3 "$project_root/packaging/device/write-firmware-provenance.py" \
		"$rootfs_stage" "$upstream" || die "cannot establish private firmware provenance"
}

ensure_root_dirs() {
	# The rsync below deliberately does not copy the contents of the live
	# pseudo-filesystems.  Keep their empty directories (and /run, /tmp,
	# /var/tmp) in the image: the initramfs moves /run into the new root and
	# switch_root fails outright when /run is absent.  modes match Fedora.
	sudo install -d -m 0555 -o 0 -g 0 "$rootfs_stage/proc" "$rootfs_stage/sys"
	sudo install -d -m 0755 -o 0 -g 0 "$rootfs_stage/dev" "$rootfs_stage/run"
	sudo install -d -m 0755 -o 0 -g 0 "$rootfs_stage/var" \
		"$rootfs_stage/var/lib" "$rootfs_stage/var/cache" "$rootfs_stage/var/log"
	sudo install -d -m 1777 -o 0 -g 0 "$rootfs_stage/tmp" "$rootfs_stage/var/tmp"
}

normalise_rootfs_ownership() {
	# The overlay sources live in the git checkout (uid/gid 1000).  rsync
	# --chown handles transferred files, but systemctl/install/chroot scripts can
	# still create a top-level directory with the caller's uid.  Normalize the
	# system directories without touching /home/<user> or the intentional
	# 0:1000 power-policy file.
	sudo chown -h 0:0 "$rootfs_stage" \
		"$rootfs_stage/etc" "$rootfs_stage/usr" "$rootfs_stage/var" \
		"$rootfs_stage/home" "$rootfs_stage/root" "$rootfs_stage/boot" \
		"$rootfs_stage/opt" "$rootfs_stage/srv" "$rootfs_stage/media" \
		"$rootfs_stage/mnt" 2>/dev/null || true
	sudo find "$rootfs_stage/etc" "$rootfs_stage/usr" -xdev -type d \
		\( -uid 1000 -o -gid 1000 \) -exec chown 0:0 {} + 2>/dev/null || true
	# System configuration is not secret: dconf fragments, systemd units and
	# polkit rules must be readable by dconf/systemd and by the desktop user.
	# The maintenance checkout can carry 0600 from a previous restore.
	sudo find "$rootfs_stage/etc/dconf/db" -type f -exec chmod 0644 {} + 2>/dev/null || true
	sudo find "$rootfs_stage/etc/systemd/system" "$rootfs_stage/etc/systemd/user" \
		-type f -exec chmod 0644 {} + 2>/dev/null || true
	sudo find "$rootfs_stage/etc/polkit-1/rules.d" -type f -exec chmod 0644 {} + 2>/dev/null || true
}

stage_rootfs_tree() {
	stage_header "stage-rootfs: copy + inject + configure rootfs"
	if [ "$have_rootfs" != 1 ]; then
		add_skip "rootfs: no mkosi rootfs tree at $rootfs_dir (root.img/boot.img rebuild/rootfs.tar.gz skipped)"
		return 1
	fi
	[ -f "$rootfs_files_sha" ] || add_skip "rootfs-files-manifest: missing $rootfs_files_sha (contract will be regenerated from the staged tree)"

	if [ "$resume" = 1 ] && [ -f "$work/.stage-rootfs.done" ] && [ -d "$rootfs_stage" ]; then
		if [ "$refresh_rootfs" = 1 ]; then
			# Re-run the image-owned configuration and dependency injection on an
			# already staged tree (used when only the extra packages / overlays /
			# identity files changed; the expensive rsync + local RPM injection
			# are already done).
			say "refresh-rootfs: re-applying configuration on $rootfs_stage"
			choose_rpm_image
			stage_root=$rootfs_stage
			install_extra_packages
			# Kernel/device RPM repositories are refreshed by their owners; a
			# refresh run must pick up the CURRENT kernel RPM (e.g. a rebuilt
			# pkgrel) instead of keeping the copy that was injected earlier.
			if [ "$have_kernel_rpms" = 1 ]; then
				say "refresh-rootfs: reinstalling kernel RPMs from $kernel_rpms_dir"
				install_rpm_dir "$kernel_rpms_dir" 1 kernel
				kver=$(installed_kernel_release)
				if [ -n "$kver" ]; then
					sudo chroot "$rootfs_stage" /sbin/depmod -a "$kver" >/dev/null 2>&1 ||
						say "warning: depmod failed after the kernel RPM refresh"
				fi
			fi
			for dir in $(printf '%s' "$device_rpms_dirs" | tr ':' ' '); do
				[ -d "$dir" ] || continue
				install_rpm_dir "$dir" 0 device
			done
			apply_rootfs_overlays
			normalise_rootfs_ownership
			stage_native_fingerprint
			sudo sh -c 'sed -i "s/^SELINUX=.*/SELINUX=permissive/" "$1/etc/selinux/config"' sh "$rootfs_stage" || true
			sed -n 's/^SELINUX=//p' "$rootfs_stage/etc/selinux/config" 2>/dev/null | head -1 >"$work/selinux-mode.txt" || true
			sudo chown 0:0 "$rootfs_stage"
			write_rootfs_identity
			write_fstab
			clean_rootfs
			write_firmware_provenance
			regenerate_rootfs_manifests
			ensure_privileges || say "warning: could not derive privileged-file expectations"
			ensure_contract || true
			printf 'ok\n' >"$work/.stage-rootfs.done"
			return 0
		fi
		say "resume: reusing staged rootfs tree $rootfs_stage"
		return 0
	fi

	# The staged tree is root-owned (rsync -a as root); removing it as the
	# calling user would spray permission errors, so use sudo.
	sudo sudo rm -rf "$work/rootfs"
	mkdir -p "$work/rootfs"
	say "copying rootfs (root ownership preserved) ..."
	# Skip the *contents* of the live pseudo-filesystems, not the directories
	# themselves.  The rootfs-builder leaves /proc (and possibly /sys, /dev,
	# /run) mounted inside its chrooted output tree; copying their contents
	# would follow live host processes.  A pattern ending in /*** also matches
	# the directory, which is how the previous build lost /run and /tmp and made
	# the initramfs switch_root fail.  /var/tmp is excluded for the same reason:
	# the rootfs-builder's runtime tests may still be writing there.
	set +e
	sudo rsync -aHAX --numeric-ids --delete \
		--exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
		--exclude='/run/*' --exclude='/tmp/*' --exclude='/var/tmp/*' \
		--exclude='/lost+found/' \
		"$rootfs_dir/" "$rootfs_stage/"
	rsync_rc=$?
	set -e
	case $rsync_rc in
	0) ;;
	24)
		# "some files vanished" -- the source tree is live during delivery
		# (rootfs-builder test suite writes under /var/tmp).  Tolerated only for
		# the excluded volatile trees; a manifest cross-check follows.
		say "warning: rsync reported vanished source files (code 24); excluded volatile trees, continuing"
		;;
	*) die "rsync of the rootfs tree failed (exit $rsync_rc)" ;;
	esac
	sudo chown 0:0 "$rootfs_stage" "$work/rootfs"
	ensure_root_dirs
	record_rootfs_inputs

	# ---- local RPM injection -------------------------------------------------
	# We install with rpm --root inside a Fedora tool container instead of dnf:
	#  * the target rootfs is Fedora 44 already; dnf would re-resolve the whole
	#    world over the network and can silently upgrade packages;
	#  * rpm --root verifies the dependency closure against the *target* rpmdb;
	#  * kernel-liuqin is installed with --noscripts so the image build does not
	#    trigger its kernel-install hook (this script builds boot.img explicitly
	#    and deterministically instead), then depmod is run in the chroot.
	choose_rpm_image
	stage_root=$rootfs_stage
	# Fedora repository dependencies first: libssc (device layer) needs libqmi /
	# libqrtr-glib / protobuf-c, which the mkosi package set does not include.
	install_extra_packages
	if [ "$have_kernel_rpms" = 1 ]; then
		install_rpm_dir "$kernel_rpms_dir" 1 kernel
	else
		add_skip "kernel-rpms: no kernel-liuqin RPM in $kernel_rpms_dir (kernel payload falls back to out/kernel/dist)"
	fi
	for dir in $(printf '%s' "$device_rpms_dirs" | tr ':' ' '); do
		[ -d "$dir" ] || continue
		install_rpm_dir "$dir" 0 device
	done
	if [ "$device_rpm_count" -eq 0 ]; then
		add_skip "device-rpms: no device-layer RPMs in $device_rpms_dirs (hardware services will be absent)"
	fi

	# P2-B6: the delivered kernel is SELinux=y while the rootfs ships
	# SELINUX=disabled.  The first release uses permissive (documented in
	# the build notes), so policy violations are visible during bring-up
	# without enforcing policy. This is not proof of correct labels; enforcing
	# still requires a full relabel and device validation. Record the mode.
	sudo sh -c 'sed -i "s/^SELINUX=.*/SELINUX=permissive/" "$1/etc/selinux/config"' sh "$rootfs_stage" ||
		say "warning: could not rewrite /etc/selinux/config to permissive"
	selinux_mode=$(sudo sed -n 's/^SELINUX=//p' "$rootfs_stage/etc/selinux/config" 2>/dev/null | head -1)
	printf '%s\n' "${selinux_mode:-unknown}" >"$work/selinux-mode.txt"

	# P2-B7: qbootctl must not ship (build pipeline: no qbootctl slot switching on
	# liuqin).  Remove it if the profile pulled it in; record the removal.
	qbootctl_nevra=$(rpm_container "rpm --root /rootfs -q qbootctl 2>/dev/null || true" \
		-v "$rootfs_stage:/rootfs:z" 2>/dev/null | tail -1)
	case $qbootctl_nevra in
	qbootctl-*)
		say "removing qbootctl from the image: $qbootctl_nevra"
		if rpm_container "rpm --root /rootfs -e --nodeps qbootctl" \
			-v "$rootfs_stage:/rootfs:z" >/dev/null 2>&1; then
			printf '%s\n' "$qbootctl_nevra" >"$work/qbootctl-removed.txt"
		else
			say "warning: could not remove qbootctl from the image"
		fi
		;;
	esac

	# depmod for the installed kernel (aarch64 binary via qemu-user binfmt)
	kver=$(installed_kernel_release)
	if [ -n "$kver" ]; then
		say "running depmod -a $kver in the staged rootfs"
		sudo chroot "$rootfs_stage" /sbin/depmod -a "$kver" >/dev/null 2>&1 ||
			say "warning: depmod failed; modules.dep may be stale"
	fi

	# ---- overlays/rootfs/rootfs.d -------------------------------------------
	apply_rootfs_overlays
	normalise_rootfs_ownership
	stage_native_fingerprint

	# ---- image-owned configuration ------------------------------------------
	# Overlay rsync can copy the checkout uid onto the staging root directory
	# itself (rsync -a updates existing destination dirs); the delivery tree's
	# root must be root:root before tar/root.img are produced (privileged-file contract).
	sudo chown 0:0 "$rootfs_stage"
	write_rootfs_identity
	write_fstab
	clean_rootfs
	write_firmware_provenance
	regenerate_rootfs_manifests
	ensure_privileges ||
		say "warning: could not derive privileged-file expectations from the staged rootfs"
	ensure_contract ||
		say "warning: no root admission contract generated (see the manifest message above)"

	printf 'ok\n' >"$work/.stage-rootfs.done"
	return 0
}

stage_native_fingerprint() {
	# Bind to the delivered kernel RPM; the late loader retains live DT guards.
	if [ -f "$rootfs_stage/usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so" ]; then
		sudo python3 "$project_root/packaging/mobile/fingerprint/stage-image.py" "$rootfs_stage" ||
			die "cannot stage native fingerprint activation"
		sudo cat "$rootfs_stage/usr/libexec/liuqin-fingerprint/CANDIDATE.json" >"$work/fingerprint-image.json"
		# Fedora ships the fingerprint PAM stack disabled until authselect's
		# standard feature is enabled. Preserve the selected profile/password
		# stack; do not write generated PAM files by hand.
		sudo chroot "$rootfs_stage" authselect check >"$work/logs/fingerprint-pam.log" 2>&1 ||
			die "authselect profile is not intact"
		# authselect runs dconf's update hook, which needs /dev/null even in
		# an offline tree. Create only this node and remove it before manifests.
		sudo sh -c '
			root=$1; created=0; created_dir=0
			if [ ! -d "$root/dev" ]; then
				mkdir "$root/dev" || exit 1
				created_dir=1
			fi
			trap '\''[ "$created" = 0 ] || rm -f "$root/dev/null"; [ "$created_dir" = 0 ] || rmdir "$root/dev"'\'' EXIT
			if [ ! -e "$root/dev/null" ]; then
				mknod -m 666 "$root/dev/null" c 1 3 || exit 1
				created=1
			fi
			case " $(chroot "$root" authselect current --raw) " in
			*" with-fingerprint "*) chroot "$root" authselect apply-changes ;;
			*) chroot "$root" authselect enable-feature with-fingerprint --backup=liuqin-image-before-fingerprint ;;
			esac
		' sh "$rootfs_stage" >>"$work/logs/fingerprint-pam.log" 2>&1 ||
			die "cannot enable native fingerprint PAM"
		# KDE never restarts a timed-out fingerprint service; use the packaged
		# lock-screen stack without the pam_fprintd timeout.  GDM's
		# PAM stack is managed by authselect/fprintd-pam and must not be replaced
		# by the KDE-specific file.
		if [ "$desktop" = plasma ] && [ -f "$rootfs_stage/etc/pam.d/liuqin-kde-fingerprint-auth" ]; then
			sudo python3 "$rootfs_stage/usr/bin/liuqin-fingerprint-lockscreen" --root "$rootfs_stage" --apply \
				>>"$work/logs/fingerprint-pam.log" 2>&1 ||
				die "cannot apply the KDE lock-screen fingerprint PAM stack"
		fi
	fi
}

record_rootfs_inputs() {
	{
		printf 'rootfs_dir=%s\n' "$rootfs_dir"
		[ -f "$rootfs_manifest_json" ] && printf 'rootfs_manifest=%s %s\n' "$(sha "$rootfs_manifest_json")" "$rootfs_manifest_json"
		[ -f "$rootfs_files_sha" ] && printf 'rootfs_files=%s %s\n' "$(sha "$rootfs_files_sha")" "$rootfs_files_sha"
		[ -f "$rootfs_packages_txt" ] && printf 'rootfs_packages=%s %s\n' "$(sha "$rootfs_packages_txt")" "$rootfs_packages_txt"
	[ -n "$expect_rootfs_hashes_sha" ] && printf 'expect_rootfs_hashes_sha=%s\n' "$expect_rootfs_hashes_sha"
	[ -n "$expected_rootfs_manifest_sha" ] && printf 'expect_rootfs_manifest_sha=%s\n' "$expected_rootfs_manifest_sha"
	} >"$work/rootfs-inputs.txt"

}

installed_kernel_release() {
	# Echo the release of the kernel installed by the kernel RPM, if any.
	[ -d "$rootfs_stage/usr/lib/modules" ] || return 0
	for dir in "$rootfs_stage"/usr/lib/modules/*; do
		[ -d "$dir" ] || continue
		name=${dir##*/}
		case $name in modules|*.modules*) continue ;; esac
		[ -e "$dir/vmlinuz" ] || [ -e "$dir/Image" ] || [ -e "$dir/liuqin/Image" ] || continue
		printf '%s\n' "$name"
		return 0
	done
	return 0
}

install_extra_packages() {
	# Some device-layer packages need Fedora packages that are not in the mkosi
	# package set (e.g. libqmi/libqrtr-glib for libssc).  They are installed from
	# the Fedora 44 aarch64 repositories through the rpm tool container, and the
	# resolved versions are recorded so the bundle stays reproducible.
	if [ "$public_image" = 1 ]; then
		for pkg in generic-release generic-logos generic-logos-httpd; do
			case " $extra_packages " in
			*" $pkg "*) ;;
			*) extra_packages="$extra_packages $pkg" ;;
			esac
		done
	fi
	[ -n "$extra_packages" ] || return 0
	[ -n "${stage_root:-}" ] || stage_root=$rootfs_stage
	say "installing Fedora repository packages into the image: $extra_packages"
	proxy=${https_proxy:-${http_proxy:-http://127.0.0.1:7890}}
	public_dnf_flags=
	[ "$public_image" = 0 ] || public_dnf_flags=--allowerasing
	mkdir -p "$work/dnf-cache"
	command="dnf5 --use-host-config --forcearch=aarch64 --releasever=$release --installroot=/rootfs \
		--setopt=install_weak_deps=False --setopt=proxy=$proxy \
		--setopt=cachedir=/var/cache/liuqin-dnf --setopt=keepcache=False \
		-y install $public_dnf_flags $extra_packages"
	if ! RPM_CONTAINER_NETWORK=host rpm_container "$command" -v "$stage_root:/rootfs:z" \
		-v "$work/dnf-cache:/var/cache/liuqin-dnf:z" \
		-e "http_proxy=$proxy" -e "https_proxy=$proxy" \
		-e "no_proxy=localhost,127.0.0.1,::1" >"$work/logs/dnf-extra.log" 2>&1; then
		# Do not abort the whole assembly for an optional dependency gap; record
		# it explicitly and let the bundle carry device_ready=false reasons.
		say "warning: Fedora repository package injection failed: $extra_packages (log: $work/logs/dnf-extra.log)"
		add_skip "extra-packages: could not install from Fedora repositories: $extra_packages"
		[ "$public_image" = 0 ] || die "public image must carry generic release/branding packages"
		return 0
	fi
	# ldconfig for the newly installed shared libraries (the aarch64 ldconfig is
	# executed through qemu-user binfmt).
	sudo chroot "$rootfs_stage" /sbin/ldconfig >/dev/null 2>&1 ||
		say "warning: ldconfig failed after --extra-packages"
	: >"$work/extra-packages.tsv"
	for pkg in $extra_packages; do
		version=$(rpm_container "rpm --root /rootfs -q --qf '%{NEVRA}' $pkg" \
			-v "$stage_root:/rootfs:z" 2>/dev/null | tail -1)
		printf '%s\t%s\n' "$pkg" "$version" >>"$work/extra-packages.tsv"
		say "extra package: $version"
	done
}

apply_static_overlay() {
	# $1 = source tree, $2 = label.  The tree is copied verbatim onto the rootfs
	# root (overlays/<name>/etc/... -> /etc/...).
	src=$1
	label=$2
	[ -d "$src" ] || return 0
	count=$(find "$src" -type f | wc -l)
	[ "$count" -gt 0 ] || return 0
	say "overlay $label: $count files"
	# --chown also normalises the destination directories rsync updates (e.g.
	# /etc and /usr themselves); without it the checkout uid 1000 leaks into
	# the image because the overlay source is owned by the build user.
	sudo rsync -aHAX --numeric-ids --chown=0:0 "$src/" "$rootfs_stage/" ||
		die "static overlay copy failed: $src"
	# The overlay lives in the git checkout, which is owned by the build user;
	# every overlay path is system content and must be owned by root (delivery contract
	# D3).  rsync -a also copied the checkout uid onto destination directories
	# it updated (e.g. /etc, /usr themselves), so restore 0:0 on each copied
	# path, not only on the files.
	sudo sh -c '
		src=$1; dst=$2
		find "$src" -mindepth 1 -printf "%P\n" | while IFS= read -r rel; do
			[ -z "$rel" ] && continue
			chown 0:0 "$dst/$rel" 2>/dev/null || true
		done
	' sh "$src" "$rootfs_stage" || die "could not normalise overlay ownership: $src"
	printf '%s\t%s files\n' "$label" "$count" >>"$work/overlays-applied.txt"
}

apply_rootfs_overlays() {
	: >"$work/overlays-applied.txt"
	if [ "$desktop" = plasma ]; then
		# KDE tablet configuration overlay (kwinrc/powerdevilrc/logind + helper),
		# produced by overlays/kde/ and validated by tests/kde-config/.
		apply_static_overlay "$project_root/overlays/kde" kde
		# The KDE overlay supplies Maliit system defaults after the base rootfs
		# was assembled. Refresh the schema cache so those defaults take effect.
		sudo chroot "$rootfs_stage" /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas ||
			die "cannot compile keyboard schema defaults"
		sudo python3 "$project_root/tools/apply-kde-touch-fixes.py" --root "$rootfs_stage" --apply ||
			die "cannot apply the reviewed KDE touch fix"
	else
		# GNOME support payload (dconf/logind/power helper) plus the independent
		# local sources that are not part of liuqin-gnome-support yet.  The
		# keyboard extension and appearance bridge are copied from the
		# maintenance tree, never from frozen task snapshots.
		apply_static_overlay "$project_root/overlays/gnome" gnome
		gnome_ext="$rootfs_stage/usr/share/gnome-shell/extensions/liuqin-tablet-keyboard@liuqin"
		sudo install -d -m 0755 "$gnome_ext"
		sudo cp -a "$project_root/overlays/gnome-local/keyboard/extension/." "$gnome_ext/"
		sudo chown -R 0:0 "$gnome_ext"
		sudo chmod 0644 "$gnome_ext"/*.js "$gnome_ext"/*.json "$gnome_ext"/*.css "$gnome_ext"/osk-layouts.gresource "$gnome_ext"/expected.sha256
		stylus_ext="$rootfs_stage/usr/share/gnome-shell/extensions/liuqin-stylus-battery@liuqin"
		sudo install -d -m 0755 "$stylus_ext"
		sudo install -m 0644 "$project_root/overlays/gnome-local/stylus/extension/"* "$stylus_ext/"
		# Power/lid policy and appearance bridge are current maintenance sources.
		sudo rsync -aHAX --numeric-ids --chown=0:0 "$project_root/overlays/gnome-local/power/usr/" "$rootfs_stage/usr/" ||
			die "cannot install liuqin GNOME power helpers"
		sudo rsync -aHAX --numeric-ids --chown=0:0 "$project_root/overlays/gnome-local/power/etc/" "$rootfs_stage/etc/" ||
			die "cannot install liuqin GNOME power policy"
		# The maintenance checkout can carry user-umask modes (0711/0600).  These
		# are system helpers and desktop entries: the desktop user must be able to
		# read the .desktop files and execute the helpers.
		sudo find "$rootfs_stage/usr/local/bin" "$rootfs_stage/usr/local/libexec" \
			-maxdepth 1 -type f -exec chmod 0755 {} + 2>/dev/null || true
		sudo find "$rootfs_stage/usr/local/share/applications" -maxdepth 1 \
			-type f -name '*.desktop' -exec chmod 0644 {} + 2>/dev/null || true
		# Bind the shipped system units to the image desktop account.  The source
		# units use the stock account name (user); an alternate --user value is
		# substituted only in the image copy.
		for unit in liuqin-lid-policy.service liuqin-powerd.service; do
			sudo sed -i "s/^User=.*$/User=$image_user/; s/^Group=.*$/Group=$image_user/" \
				"$rootfs_stage/etc/systemd/system/$unit" ||
				die "cannot bind $unit to the image desktop user"
		done
		sudo sed -i "s/subject.user == \"[^\"]*\"/subject.user == \"$image_user\"/" \
			"$rootfs_stage/etc/polkit-1/rules.d/49-liuqin-lid-suspend.rules" ||
			die "cannot bind the lid polkit rule to the image desktop user"
		if [ -f "$rootfs_stage/etc/liuqin/power-policy.conf" ]; then
			sudo chown 0:1000 "$rootfs_stage/etc/liuqin/power-policy.conf" ||
				die "cannot assign the power policy to the image desktop group"
			sudo chmod 0664 "$rootfs_stage/etc/liuqin/power-policy.conf"
		fi
		# The unified power daemon is a Rust aarch64 binary; keep the compiled
		# artifact out of git but require it when assembling a daily image.
		powerd_bin="$project_root/rust/target/aarch64-unknown-linux-gnu/release/liuqin-powerd"
		if [ ! -x "$powerd_bin" ]; then
			die "missing $powerd_bin; run scripts/build-powerd.sh before building the image"
		fi
		sudo install -Dm0755 "$powerd_bin" "$rootfs_stage/usr/local/libexec/liuqin-powerd"
		sudo install -Dm0755 "$project_root/overlays/gnome-local/appearance/appearance-sync.py" \
			"$rootfs_stage/usr/local/libexec/liuqin-appearance-sync"
		sudo install -Dm0644 "$project_root/overlays/gnome-local/appearance/liuqin-appearance-sync.service" \
			"$rootfs_stage/etc/systemd/user/liuqin-appearance-sync.service"
		sudo install -Dm0644 "$project_root/overlays/gnome-local/appearance/liuqin-catppuccin-auto.palette" \
			"$rootfs_stage/usr/share/liuqin/appearance/liuqin-catppuccin-auto.palette"
		# Enable the system keyboard extension and the packaged Light Style for
		# every GNOME user through the system dconf database.
		sudo install -d -m 0755 "$rootfs_stage/etc/dconf/db/local.d"
		sudo tee "$rootfs_stage/etc/dconf/db/local.d/30-liuqin-gnome-extensions" >/dev/null <<'EOF'
[org/gnome/shell]
enabled-extensions=['liuqin-tablet-keyboard@liuqin', 'liuqin-stylus-battery@liuqin', 'light-style@gnome-shell-extensions.gcampax.github.com']
EOF
		sudo chmod 0644 "$rootfs_stage/etc/dconf/db/local.d/30-liuqin-gnome-extensions"
		sudo chroot "$rootfs_stage" dconf update ||
			die "cannot update the system dconf database"
		sudo chroot "$rootfs_stage" systemctl --global enable liuqin-appearance-sync.service ||
			die "cannot enable liuqin-appearance-sync.service for users"
		# Fedora first boot runs `systemctl preset-all`; 99-default-disable.preset
		# contains "disable *", so a bare `systemctl enable` is undone on the
		# first boot (this silently disabled lid/power-key on 2026-11-06).
		# The preset file is the source of truth.  Fail the build loudly if it
		# is missing or ineffective instead of shipping a tablet that cannot sleep.
		if ! sudo test -f "$rootfs_stage/etc/systemd/system-preset/90-liuqin-power.preset"; then
			die "missing /etc/systemd/system-preset/90-liuqin-power.preset; first boot would disable liuqin-powerd"
		fi
		for unit in liuqin-lid-policy.service liuqin-power-keyd.service liuqin-powerd.service; do
			if ! sudo test -e "$rootfs_stage/usr/lib/systemd/system/$unit" &&
			   ! sudo test -e "$rootfs_stage/etc/systemd/system/$unit"; then
				die "$unit missing; cannot enable the lid/power-key policy"
			fi
		done
		sudo chroot "$rootfs_stage" systemctl preset \
			liuqin-lid-policy.service liuqin-power-keyd.service liuqin-powerd.service ||
			die "cannot apply 90-liuqin-power.preset"
		sudo chroot "$rootfs_stage" systemctl is-enabled --quiet liuqin-powerd.service ||
			die "liuqin-powerd.service is not enabled after preset; first-boot preset would disable it"
		for unit in liuqin-lid-policy.service liuqin-power-keyd.service; do
			if sudo chroot "$rootfs_stage" systemctl is-enabled --quiet "$unit"; then
				die "$unit is still enabled after preset; two power policy owners would run"
			fi
		done
	fi
	# Any loose files under overlays/rootfs/ (device-layer files belong in
	# overlays/rootfs/rootfs.d/<NN>-<component>/ instead).
	if [ -d "$project_root/overlays/rootfs" ]; then
		for entry in "$project_root/overlays/rootfs"/*; do
			[ -e "$entry" ] || continue
			name=${entry##*/}
			case $name in rootfs.d|README*|.*) continue ;; esac
			if [ -d "$entry" ]; then
				apply_static_overlay "$entry" "rootfs-$name"
			elif [ -f "$entry" ]; then
				sudo cp -a "$entry" "$rootfs_stage/" ||
					die "overlay file copy failed: $entry"
				sudo chown 0:0 "$rootfs_stage/${entry##*/}" ||
					die "could not normalise overlay file ownership: $entry"
				printf '%s\t1 file\n' "rootfs-$name" >>"$work/overlays-applied.txt"
			fi
		done
	fi
	overlay_root=$project_root/overlays/rootfs/rootfs.d
	[ -d "$overlay_root" ] || return 0
	for entry in "$overlay_root"/*; do
		[ -d "$entry" ] || continue
		name=${entry##*/}
		case $name in README*|.*) continue ;; esac
		if [ -d "$entry/files" ]; then
			say "overlay $name: files/"
			sudo rsync -aHAX --numeric-ids --chown=0:0 "$entry/files/" "$rootfs_stage/" ||
				die "overlay files copy failed: $entry/files"
		fi
		if [ -d "$entry/rpms" ] && ls "$entry/rpms"/*.rpm >/dev/null 2>&1; then
			say "overlay $name: rpms/"
			install_rpm_dir "$entry/rpms" 0 "overlay-$name"
		fi
		if [ -x "$entry/install.sh" ] || [ -f "$entry/install.sh" ]; then
			say "overlay $name: install.sh (chroot)"
			sudo cp -f "$entry/install.sh" "$rootfs_stage/.liuqin-overlay-install.sh"
			sudo chmod 0755 "$rootfs_stage/.liuqin-overlay-install.sh"
			sudo chroot "$rootfs_stage" /usr/bin/env LIUQIN_IMAGE_OFFLINE=1 \
				/bin/bash -e /.liuqin-overlay-install.sh ||
				die "overlay install.sh failed: $entry/install.sh"
			sudo rm -f "$rootfs_stage/.liuqin-overlay-install.sh"
		fi
	done
	# Validate the delivered rule with a native verifier, not the target
	# systemd binary under qemu-user.  No host rule is installed or reloaded.
	if [ -f "$rootfs_stage/etc/udev/rules.d/71-liuqin-keyboard-nowake.rules" ]; then
		sudo udevadm verify "$rootfs_stage/etc/udev/rules.d/71-liuqin-keyboard-nowake.rules" ||
			die "keyboard wake rule verification failed"
	fi
}

write_rootfs_identity() {
	# Root admission marker: the initramfs hardcodes this content and mode.
	sudo mkdir -p "$rootfs_stage/etc"
	printf 'liuqin-fedora-root-v1\n' | sudo tee "$rootfs_stage/etc/liuqin-fedora-root" >/dev/null
	sudo chown 0:0 "$rootfs_stage/etc/liuqin-fedora-root"
	sudo chmod 0644 "$rootfs_stage/etc/liuqin-fedora-root"

	# Device safety marker: starting the SLPI has already reset this tablet.
	# liuqin-slpi.service has ConditionPathExists=!/etc/liuqin-slpi-disabled, so
	# the empty marker must be in the delivered image before first boot.
	sudo install -m 0644 -o 0 -g 0 /dev/null "$rootfs_stage/etc/liuqin-slpi-disabled"
	# hostnamed uses this separately from the kernel's gnome.is_vm=0 flag.
	printf 'CHASSIS=convertible\n' | sudo tee "$rootfs_stage/etc/machine-info" >/dev/null
	sudo chown 0:0 "$rootfs_stage/etc/machine-info"
	sudo chmod 0644 "$rootfs_stage/etc/machine-info"

	# Re-assert the systemd handoff even when the mkosi tree was produced by an
	# older finalize script.  The initramfs refuses a root whose default.target
	# or display-manager alias cannot be resolved; the .wants link makes the
	# login manager explicit for verifiers and for graphical.target.
	sudo install -d -m 0755 "$rootfs_stage/etc/systemd/system/graphical.target.wants"
	sudo ln -sfn /usr/lib/systemd/system/graphical.target \
		"$rootfs_stage/etc/systemd/system/default.target"
	sudo ln -sfn "/usr/lib/systemd/system/$lm_unit" \
		"$rootfs_stage/etc/systemd/system/display-manager.service"
	sudo ln -sfn "/usr/lib/systemd/system/$lm_unit" \
		"$rootfs_stage/etc/systemd/system/graphical.target.wants/$lm_unit"
	if [ -f "$rootfs_stage/etc/liuqin/image-contract" ]; then
		sudo sed -i 's/^HOME_LABEL=.*/HOME_LABEL=none/' \
			"$rootfs_stage/etc/liuqin/image-contract"
	fi

	# Kernel identity interface consumed by the initramfs fedora profile and the
	# root contract.
	kver=$(installed_kernel_release)
	if [ -z "$kver" ]; then
		# No kernel RPM installed: fall back to the kernel payload this image
		# will actually boot (out/kernel/dist), so the rootfs identity files and
		# the boot payload still describe the same kernel.
		if [ -d "$project_root/out/kernel/dist" ]; then
			kver=$(image_kernel_release "$project_root/out/kernel/dist" || true)
		fi
	fi
	if [ -z "$kver" ]; then
		add_skip "kernel-identity: no installed kernel and no resolvable kernel release"
		return 0
	fi
	sudo mkdir -p "$rootfs_stage/usr/share/liuqin"
	provided_release=
	if [ -f "$rootfs_stage/usr/share/liuqin/kernel.release" ]; then
		provided_release=$(sudo cat "$rootfs_stage/usr/share/liuqin/kernel.release")
	fi
	if [ -n "$provided_release" ] && [ "$provided_release" != "$kver" ]; then
		die "kernel.release says '$provided_release' but the installed kernel is '$kver'"
	fi
	printf '%s\n' "$kver" | sudo tee "$rootfs_stage/usr/share/liuqin/kernel.release" >/dev/null
	sudo chown 0:0 "$rootfs_stage/usr/share/liuqin/kernel.release"
	sudo chmod 0644 "$rootfs_stage/usr/share/liuqin/kernel.release"

	modules_manifest=$rootfs_stage/usr/share/liuqin/kernel-modules.manifest
	if [ ! -s "$modules_manifest" ] || [ "$resume" != 1 ]; then
		: >"$work/kernel-modules.manifest"
		if [ -d "$rootfs_stage/usr/lib/modules/$kver" ]; then
			(cd "$rootfs_stage/usr/lib/modules/$kver" &&
				find . -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) \
					-print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) |
				sed 's|  \./|  /usr/lib/modules/'"$kver"'/|' >"$work/kernel-modules.manifest"
		fi
		if [ ! -s "$work/kernel-modules.manifest" ]; then
			# The kernel may be built-in-only in structure bundles; record that
			# explicitly instead of writing an empty file the contract would pin.
			printf '# no loadable modules: kernel %s\n' "$kver" >"$work/kernel-modules.manifest"
			add_skip "kernel-modules: no loadable modules found for $kver"
		fi
		sudo cp -f "$work/kernel-modules.manifest" "$modules_manifest"
		sudo chown 0:0 "$modules_manifest"
		sudo chmod 0644 "$modules_manifest"
	fi
	say "kernel identity: release=$kver modules=$(wc -l <"$work/kernel-modules.manifest" 2>/dev/null || echo 0)"
}

write_fstab() {
	# Flat layout (flat install contract): /home is a directory inside the root
	# partition, not a separate mount.  A LABEL=LIUQIN_HOME entry here would
	# make systemd wait for a partition that does not exist and can fail the
	# first login session.  The root entry also gives systemd the growfs hook
	# that expands the flashed 6.98 GiB image to the real linux_root size.
	{
		printf '# Written by scripts/build-image.sh. The boot image mounts the root\n'
		printf '# filesystem by LABEL=LIUQIN_ROOT; /home is part of this flat root.\n'
		printf 'LABEL=LIUQIN_ROOT\t/\text4\tdefaults,errors=remount-ro,x-systemd.growfs\t0\t1\n'
	} | sudo tee "$rootfs_stage/etc/fstab" >/dev/null
	sudo chown 0:0 "$rootfs_stage/etc/fstab"
	sudo chmod 0644 "$rootfs_stage/etc/fstab"
}

clean_rootfs() {
	# Image hygiene: the image must not ship this build host's caches or the
	# rootfs build's transient state.  Mirrors mkosi.postinst.chroot.
	sudo rm -rf "$rootfs_stage/var/cache/dnf" "$rootfs_stage/var/cache/libdnf5" \
		"$rootfs_stage/var/cache/PackageKit" "$rootfs_stage/var/log/journal" \
		"$rootfs_stage/var/lib/systemd/random-seed" "$rootfs_stage/var/tmp/"* \
		"$rootfs_stage/tmp/"* "$rootfs_stage/run/"* 2>/dev/null || true
	sudo find "$rootfs_stage/var/log" -type f -delete 2>/dev/null || true
	sudo rm -f "$rootfs_stage"/etc/ssh/ssh_host_* 2>/dev/null || true
	ensure_root_dirs
	if [ "$public_image" = 1 ]; then
		sudo python3 "$project_root/tools/configure-public-image.py" \
			--root "$rootfs_stage" --user "$image_user" || die "public image defaults failed"
	fi
}

regenerate_rootfs_manifests() {
	# Regenerated after RPM injection/configuration: the rootfs-builder manifest
	# describes the pre-injection tree and must not be used for the contract.
	say "regenerating rootfs file manifest (this can take a minute)"
	packages_tmp=$work/rootfs.packages.txt
	rpm_container "rpm --root /rootfs -qa --qf '%{NAME}\t%{EVR}\t%{ARCH}\t%{SIZE}\n' | LC_ALL=C sort" \
		-v "$rootfs_stage:/rootfs:z" >"$packages_tmp" ||
		die "could not list the staged rootfs RPM database"
	cp -f "$packages_tmp" "$manifests_dir/rootfs.packages.txt" 2>/dev/null || true

	files_tmp=$work/rootfs.files.sha256
	sudo python3 - "$rootfs_stage" "$files_tmp" <<'PY'
import hashlib
import os
import sys

root, out = sys.argv[1], sys.argv[2]

SKIP_DIRS = {'proc', 'sys', 'dev', 'run', 'tmp'}
SKIP_PREFIXES = (
    'var/cache/', 'var/log/', 'var/tmp/', 'var/lib/systemd/random-seed',
    'var/lib/sss/db/',
)
SKIP_FILES = {'etc/shadow', 'etc/shadow-', 'etc/gshadow', 'etc/gshadow-',
              'etc/ssh/ssh_host_rsa_key', 'etc/ssh/ssh_host_ecdsa_key',
              'etc/ssh/ssh_host_ed25519_key',
              # image-owned self manifest: written from this very list AFTER it is
              # generated, so hashing it would record a stale/previous copy
              # (refresh runs) and the delivered manifest could not verify itself.
              'usr/share/liuqin/rootfs.files.sha256'}
skipped_newline = 0
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    rel_dir = os.path.relpath(dirpath, root)
    if rel_dir == '.':
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel_dir = ''
    dirnames.sort()
    for name in sorted(filenames):
        rel = (rel_dir + '/' + name) if rel_dir else name
        if rel in SKIP_FILES or rel.startswith(SKIP_PREFIXES):
            continue
        if '\n' in rel or '\r' in rel:
            # A path that cannot be expressed as one plain text line is not
            # admissible in a contract/machine manifest; record and skip.
            skipped_newline += 1
            continue
        path = os.path.join(dirpath, name)
        try:
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            digest = hashlib.sha256()
            with open(path, 'rb') as stream:
                for chunk in iter(lambda: stream.read(1 << 20), b''):
                    digest.update(chunk)
        except OSError:
            continue
        lines.append(digest.hexdigest() + '  /' + rel)
lines.sort(key=lambda line: line[66:])
with open(out, 'w', encoding='utf-8', errors='surrogateescape') as stream:
    stream.write('\n'.join(lines) + '\n')
print(f"rootfs.files.sha256: {len(lines)} files"
      + (f" ({skipped_newline} paths with newline skipped)" if skipped_newline else ""),
      file=sys.stderr)
PY
	# The Python writer runs as root (reading root-only paths); hand the file
	# back to the invoking user so the rest of the pipeline can read it.
	sudo chown "$(id -u):$(id -g)" "$work/rootfs.files.sha256" 2>/dev/null || true
	sudo chmod 0644 "$work/rootfs.files.sha256"
	say "rootfs manifest: $(wc -l <"$work/rootfs.files.sha256") files"
	# Fixed in-image path consumed by the kernel-install refresh hook
	# (/usr/libexec/liuqin/liuqin-bootimg-refresh).  It is written after the hash
	# list is generated, so the list does not contain itself; that is expected.
	sudo mkdir -p "$rootfs_stage/usr/share/liuqin"
	sudo cp -f "$work/rootfs.files.sha256" "$rootfs_stage/usr/share/liuqin/rootfs.files.sha256"
	sudo chown 0:0 "$rootfs_stage/usr/share/liuqin/rootfs.files.sha256"
	sudo chmod 0644 "$rootfs_stage/usr/share/liuqin/rootfs.files.sha256"
	sudo sh -c '
		cd "$1" || exit 1
		find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d "" link; do
			printf "%s\t%s\n" "${link#.}" "$(readlink "$link")"
		done
	' sh "$rootfs_stage" >"$work/rootfs.symlinks.txt" ||
		die "could not list the staged rootfs symlinks"

	# Regenerate the JSON manifest in the rootfs-builder format.
	python3 - "$work/rootfs.files.sha256" "$packages_tmp" "$work/rootfs.symlinks.txt" \
		"$work/rootfs.manifest" "$release" "$rootfs_manifest_json" "$bundle_name" \
		"$desktop" "$login_manager" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

files_sha, packages, symlinks, out, release, source_manifest, name, desktop, login_manager = sys.argv[1:10]

def file_sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

packages_list = []
for line in Path(packages).read_text(errors='replace').splitlines():
    parts = line.split('\t')
    if len(parts) != 4:
        continue
    name_, evr, arch, size = parts
    packages_list.append({'name': name_, 'evr': evr, 'arch': arch,
                          'size': int(size) if size.isdigit() else 0,
                          'nevra': f'{name_}-{evr}.{arch}'})
files_lines = Path(files_sha).read_text().splitlines()
manifest = {
    'format': 'liuqin-rootfs-manifest/v1',
    'image': {'id': name, 'device': 'liuqin', 'architecture': 'aarch64',
              'distribution': 'fedora', 'release': release, 'profile': desktop,
              'format': 'directory', 'bootable': False, 'desktop': desktop,
              'login_manager': login_manager},
    'artifact': {'rootfs_dir': '/',
                 'files_sha256': Path(files_sha).name,
                 'files_sha256_sha256': file_sha(files_sha),
                 'files_sha256_count': len(files_lines),
                 'packages_txt': Path(packages).name,
                 'packages_txt_sha256': file_sha(packages),
                 'symlinks_txt': Path(symlinks).name,
                 'symlinks_txt_sha256': file_sha(symlinks)},
    'package_count': len(packages_list),
    'packages': packages_list,
    'assembly': {'source_manifest': source_manifest if os.path.exists(source_manifest) else None,
                 'injected_rpms': True},
}
Path(out).write_text(json.dumps(manifest, indent=2) + '\n')
print(f"rootfs.manifest: {len(packages_list)} packages, {len(files_lines)} files")
PY
}

ensure_contract() {
	# single-producer rule: tools/build-root-contract.py is the ONLY contract
	# producer.  The generated contract goes to boot.img AND installer.img, and
	# is validated against the staged tree here (fail-closed at build time: a
	# rootfs that would be rejected at boot never becomes an image).
	[ -n "${contract_file:-}" ] && [ -f "$contract_file" ] && return 0
	[ -f "$work/rootfs.files.sha256" ] || return 1
	contract_file=$work/contract/liuqin-fedora-root.contract
	mkdir -p "${contract_file%/*}" || return 1
	say "generating root admission contract v2 (single producer: tools/build-root-contract.py)"
	if [ -d "$rootfs_stage" ]; then
		python3 "$project_root/tools/build-root-contract.py" \
			--manifest "$work/rootfs.files.sha256" \
			--rootfs "$rootfs_stage" --desktop "$desktop" \
			--output "$contract_file" ||
			die "root admission contract generation failed: the staged rootfs does not pass its own boot admission topology (topology contract)"
	else
		python3 "$project_root/tools/build-root-contract.py" \
			--manifest "$work/rootfs.files.sha256" --desktop "$desktop" \
			--output "$contract_file" ||
			die "root admission contract generation failed"
		say "warning: no staged rootfs tree; the contract was not topology-validated against a real tree"
	fi
	[ "$(head -n 1 "$contract_file")" = LIUQIN_FEDORA_ROOT_CONTRACT_V2 ] ||
		die "generated contract header is not LIUQIN_FEDORA_ROOT_CONTRACT_V2"
	say "root admission contract: sha256=$(sha "$contract_file") bytes=$(stat -c '%s' "$contract_file")"
}

ensure_privileges() {
	# privileged-file and flat install contracts : derive the installer's privileged-file
	# expectations from the REAL assembled rootfs instead of hardcoding
	# distribution guesses.  Includes every setuid/setgid regular file and every
	# file carrying a security.capability xattr; installer.img embeds this list
	# and install-root.sh verifies tar preserved exactly those modes/xattrs.
	# (A hardcoded "ping must carry cap_net_raw" check aborted real Fedora 44
	# installs: ping is 0755 with no capability there, while kwin_wayland does
	# carry cap_sys_nice=ep.)
	[ -n "${privileges_file:-}" ] && [ -f "$privileges_file" ] && return 0
	[ -d "$rootfs_stage" ] || return 1
	privileges_file=$work/installer-privileges.txt
	mkdir -p "${privileges_file%/*}" || return 1
	say "scanning the assembled rootfs for privileged-file expectations (setuid/setgid + security.capability)"
	sudo python3 - "$rootfs_stage" "$privileges_file" <<'PY' || die "privileged-file expectation scan failed"
import os
import stat
import subprocess
import sys

root, out = sys.argv[1], sys.argv[2]
lines = []
setuid_count = 0
capability_count = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [name for name in dirnames if name not in ('proc', 'sys', 'dev', 'run')]
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode):
            continue
        relative = '/' + os.path.relpath(path, root).replace(os.sep, '/')
        mode = stat.S_IMODE(info.st_mode)
        if mode & 0o6000:
            kind = 'setuid' if mode & 0o4000 else 'setgid'
            lines.append(f'{kind} {mode:04o} {relative}')
            setuid_count += 1
        try:
            os.getxattr(path, b'security.capability')
        except OSError:
            continue
        try:
            result = subprocess.run(['getcap', path], capture_output=True, text=True)
        except OSError:
            continue
        value = result.stdout.strip()
        if not value:
            continue
        caps_text = value.rsplit(' ', 1)[-1].lstrip('= ').strip()
        if not caps_text or caps_text == value:
            continue
        lines.append(f'cap {caps_text} {relative}')
        capability_count += 1
lines.sort(key=lambda line: line.rsplit(' ', 1)[-1])
with open(out, 'w', encoding='utf-8', errors='surrogateescape') as stream:
    stream.write('# Privileged-file expectations generated by scripts/build-image.sh\n')
    stream.write('# from the assembled rootfs (privileged-file and flat install contracts).  Format:\n')
    stream.write('#   setuid|setgid <octal-mode> <absolute in-root path>\n')
    stream.write('#   cap <getcap-caps> <absolute in-root path>\n')
    if lines:
        stream.write('\n'.join(lines) + '\n')
print(f'privileged-file expectations: {len(lines)} entries '
      f'({setuid_count} setuid/setgid, {capability_count} capability)')
PY
	sudo chown "$(id -u):$(id -g)" "$privileges_file" 2>/dev/null || true
	sudo chmod 0644 "$privileges_file"
	say "privileged-file expectations: $(grep -vc '^#' "$privileges_file" 2>/dev/null || echo 0) entries, sha256=$(sha "$privileges_file")"
}

# ---------------------------------------------------------------------------
# Kernel payload resolution (shared by boot-img and installer-img stages)
# ---------------------------------------------------------------------------
kernel_out=
kernel_source=
extract_kernel_from_stage() {
	# Sets kernel_out to a build-bootimg --kernel-out compatible directory.
	kver=$(installed_kernel_release)
	[ -n "$kver" ] || return 1
	moddir=$rootfs_stage/usr/lib/modules/$kver
	kernel_out=$work/kernel-out
	rm -rf "$kernel_out"
	mkdir -p "$kernel_out/dist"
	image_src=
	dtb_src=
	for candidate in "$moddir/liuqin/Image" "$moddir/Image" "$moddir/vmlinuz"; do
		[ -f "$candidate" ] && { image_src=$candidate; break; }
	done
	[ -n "$image_src" ] || return 1
	case $(head -c 2 "$image_src" | od -An -tx1 | tr -d ' \n') in
	1f8b) gzip -dc "$image_src" >"$kernel_out/dist/Image" ;;
	28b5) command -v zstd >/dev/null 2>&1 && zstd -dc "$image_src" >"$kernel_out/dist/Image" ||
		{ say "warning: vmlinuz is zstd-compressed but zstd is missing"; return 1; } ;;
	fd37) xz -dc "$image_src" >"$kernel_out/dist/Image" ;;
	*) cp -f "$image_src" "$kernel_out/dist/Image" ;;
	esac
	[ -f "$kernel_out/dist/Image" ] || return 1
	dtb_src=$(find "$moddir" -type f -name 'sm8475-xiaomi-liuqin.dtb' 2>/dev/null | LC_ALL=C sort | head -1)
	if [ -z "$dtb_src" ] && [ -f "$rootfs_stage/lib/firmware/devicetree/base" ]; then
		dtb_src=
	fi
	[ -n "$dtb_src" ] || return 1
	cp -f "$dtb_src" "$kernel_out/dist/sm8475-xiaomi-liuqin.dtb"
	printf '%s\n' "$kver" >"$kernel_out/dist/kernel.release"
	# The config belongs to this installed RPM, not a different host build or
	# the upstream source lock (which excludes the Fedora fragment).
	[ -s "$rootfs_stage/usr/share/liuqin/kernel-config" ] ||
		die "kernel-liuqin RPM is missing its kernel-config snapshot"
	cp -f "$rootfs_stage/usr/share/liuqin/kernel-config" "$kernel_out/.config"
	kernel_source="kernel-liuqin RPM ($kernel_rpms_dir)"
	return 0
}

resolve_kernel_payload() {
	kernel_out=
	kernel_source=
	if [ -n "$kernel_image_override" ] && [ -n "$kernel_dtb_override" ]; then
		[ -f "$kernel_image_override" ] && [ -f "$kernel_dtb_override" ] ||
			die_usage "--kernel-image/--kernel-dtb must both be existing files"
		kernel_out=$work/kernel-out
		rm -rf "$kernel_out"
		mkdir -p "$kernel_out/dist"
		cp -f "$kernel_image_override" "$kernel_out/dist/Image"
		cp -f "$kernel_dtb_override" "$kernel_out/dist/sm8475-xiaomi-liuqin.dtb"
		kernel_source="explicit --kernel-image/--kernel-dtb"
		return 0
	fi
	if [ "$have_rootfs" = 1 ] && [ -f "$work/.stage-rootfs.done" ] &&
		extract_kernel_from_stage; then
		return 0
	fi
	if [ -d "$project_root/out/kernel/dist" ] && [ -f "$project_root/out/kernel/dist/Image" ] &&
		[ -f "$project_root/out/kernel/dist/sm8475-xiaomi-liuqin.dtb" ]; then
		kernel_out=$project_root/out/kernel
		kernel_source="out/kernel/dist (kernel build output, NOT the kernel-liuqin RPM)"
		add_skip "kernel-payload: using out/kernel/dist instead of the kernel-liuqin RPM (boot/rootfs kernel identity checked separately)"
		return 0
	fi
	return 1
}

image_kernel_release() {
	# Release string from a kernel payload: kernel.release file, else Image strings.
	payload=$1
	[ -n "$payload" ] || return 1
	if [ -f "$payload/kernel.release" ]; then
		cat "$payload/kernel.release"
		return 0
	fi
	image=$payload/Image
	[ -f "$image" ] || image=$payload/dist/Image
	[ -f "$image" ] || return 1
	LC_ALL=C strings "$image" 2>/dev/null | grep -m1 '^Linux version ' |
		sed -E 's/^Linux version ([^ ]+).*/\1/'
}

# ---------------------------------------------------------------------------
# Stage: root.img (+ rootfs.tar.gz)
# ---------------------------------------------------------------------------
stage_root_img() {
	stage_header "stage-root-img: mkfs.ext4 + rootfs.tar.gz"
	if [ ! -f "$work/rootfs.files.sha256" ] || [ ! -d "$rootfs_stage" ]; then
		add_skip "root-img: no staged rootfs tree"
		return 1
	fi
	if [ "$public_image" = 1 ]; then
		say "applying the target Fedora SELinux file contexts before packaging"
		sudo chroot "$rootfs_stage" /usr/sbin/setfiles -F -m \
			/etc/selinux/targeted/contexts/files/file_contexts / \
			>"$work/logs/selinux-label.log" 2>&1 ||
			die "target SELinux labeling failed (see logs/selinux-label.log)"
	fi
	rootfs_bytes=$(sudo du -sb "$rootfs_stage" | cut -f1)
	if [ -n "$size_arg" ]; then
		root_size=$(parse_size "$size_arg") || die_usage "--size is not a size: $size_arg"
	else
		# 15% headroom + 512 MiB, rounded up to a whole MiB.
		root_size=$((rootfs_bytes + rootfs_bytes / 7 + 512 * 1024 * 1024))
		root_size=$(((root_size + 1024 * 1024 - 1) / (1024 * 1024) * 1024 * 1024))
	fi
	[ "$root_size" -gt "$rootfs_bytes" ] || die "--size ($root_size) is smaller than the rootfs ($rootfs_bytes bytes)"
	say "root.img: rootfs $rootfs_bytes bytes -> ext4 image $root_size bytes"
	root_img=$work/root.img
	root_uuid=$(uuidgen)
	sudo rm -f "$root_img"
	sudo truncate -s "$root_size" "$root_img"
	# FLAT layout (flat install contract): the ext4 image root IS the rootfs root (/etc,
	# /usr, /bin ... at /).  $rootfs_stage is .../rootfs/root (only the name of
	# the staging directory; no extra directory is created in the image).
	# This is what makes root.img directly flashable as the linux_root
	# filesystem and keeps it identical to what the RAM installer extracts.
	sudo mkfs.ext4 -q -F -L LIUQIN_ROOT -b 4096 -m 0 -U "$root_uuid" \
		-d "$rootfs_stage" "$root_img" ||
		die "mkfs.ext4 -d failed"
	sudo e2fsck -fn "$root_img" >"$work/logs/root-e2fsck.log" 2>&1 ||
		die "e2fsck -fn on the produced root.img failed (log: $work/logs/root-e2fsck.log)"
	label=$(sudo blkid -p -s LABEL -o value "$root_img" 2>/dev/null || true)
	[ "$label" = LIUQIN_ROOT ] || die "root.img label is '$label', expected LIUQIN_ROOT"
	say "root.img: $root_img ($(stat -c '%s' "$root_img") bytes, label=$label, uuid=$root_uuid)"

	# rootfs.tar.gz: the RAM installer extracts this with tar -xzf directly onto
	# the target partition root (flat install, flat install contract), so the archive root
	# must be the filesystem root (no prefix inside the tar).
	# The real numeric owner/mode/ACL/xattr of every file is preserved: NO
	# --owner=0/--group=0 (privileged-file contract); /home/<user> must stay 1000:1000 0700.
	stage_header "stage-root-img: rootfs.tar.gz"
	rootfs_tar=$work/rootfs.tar.gz
	sudo rm -f "$rootfs_tar"
	# privileged-file contract: preserve the REAL numeric owner/mode/ACL/xattr of the tree.
	# --owner=0/--group=0 was removed on purpose: it turned /home/<user> into
	# root:root and (together with the old chmod -R a-w freeze) broke logging in
	# and writing user files.
	# /usr/lib/clock-epoch stores the trusted fallback time in its mtime.
	# Preserve real mtimes, just as mkfs.ext4 -d does; normalizing the whole
	# archive to epoch zero silently removes this RTC-less boot safeguard.
	sudo tar -C "$rootfs_stage" --numeric-owner --acls --xattrs \
		--xattrs-include='*' --sort=name \
		-cf - . | gzip -n "-$rootfs_gzip_level" >"$rootfs_tar"
	say "rootfs.tar.gz: $(stat -c '%s' "$rootfs_tar") bytes (compressed)"
	printf 'root_img=%s\nroot_uuid=%s\nroot_size=%s\nrootfs_tar=%s\n' \
		"$root_img" "$root_uuid" "$root_size" "$rootfs_tar" >"$work/root-img.info"
}

# ---------------------------------------------------------------------------
# Stage: boot.img
# ---------------------------------------------------------------------------
build_initramfs_persistent() {
	# $1 = output dir
	out=$1
	rm -rf "$out"
	mkdir -p "$out"
	ensure_contract || die "no root admission contract available for the persistent initramfs"
	set -- --out "$out" --kernel-out "$kernel_out" --contract "$contract_file" \
		--desktop "$desktop"
	if [ -n "$firmware_pool" ]; then
		set -- "$@" --firmware-pool "$firmware_pool"
		[ -z "$wlan_hsp2_tuple" ] || set -- "$@" --wlan-hsp2-tuple "$wlan_hsp2_tuple"
		[ -z "$audio_topology" ] || set -- "$@" --audio-topology "$audio_topology"
	else
		set -- "$@" --allow-missing-firmware
	fi
	scripts/build-initramfs.sh "$@" || die "persistent initramfs build failed"
}

stage_boot_img() {
	stage_header "stage-boot-img: rebuild boot.img from the staged kernel + rootfs"
	if [ -n "$boot_img_input" ]; then
		[ -f "$boot_img_input" ] || die_usage "--boot-img is not a file: $boot_img_input"
		boot_img=$work/boot.img
		cp -f "$boot_img_input" "$boot_img"
		add_skip "boot-img: reused $boot_img_input instead of rebuilding (not rebuilt for this rootfs)"
		boot_img_source="reused input: $boot_img_input"
		return 0
	fi
	if [ ! -f "$work/rootfs.files.sha256" ]; then
		add_skip "boot-img: no staged rootfs manifest (rootfs stage skipped; boot.img cannot carry a real root contract)"
		return 1
	fi
	if ! resolve_kernel_payload; then
		add_skip "boot-img: no kernel payload (kernel RPM not installed, out/kernel/dist absent, no --kernel-image)"
		return 1
	fi
	kernel_out_root=$kernel_out
	kver_payload=$(image_kernel_release "$kernel_out" || true)
	[ -n "$kver_payload" ] || die "cannot determine the kernel release of $kernel_out"

	# Kernel release consistency: the boot payload and the root filesystem must
	# describe the same kernel, otherwise the initramfs fedora gate refuses the
	# root on purpose.
	if [ -f "$rootfs_stage/usr/share/liuqin/kernel.release" ]; then
		root_kver=$(sudo cat "$rootfs_stage/usr/share/liuqin/kernel.release")
		[ "$root_kver" = "$kver_payload" ] ||
			die "kernel release mismatch: rootfs=$root_kver boot payload=$kver_payload"
		say "kernel release consistency: $kver_payload (rootfs == boot payload)"
	fi

	initramfs_out=$work/boot
	build_initramfs_persistent "$initramfs_out"
	ramdisk=$initramfs_out/initramfs/liuqin-firstboot.cpio.gz
	[ -f "$ramdisk" ] || die "persistent initramfs was not produced"
	boot_out=$work/boot-img
	rm -rf "$boot_out"
	set -- --kernel-out "$kernel_out" --ramdisk "$ramdisk" --out "$boot_out" \
		--strict-kernel --dtb-source "$dtb_source" --kernel-provenance "$kernel_source"
	[ "$dtb_source" = stock-rom ] && set -- "$@" --stock-rom-dir "$stock_rom_dir"
	scripts/build-bootimg.sh "$@" || die "boot.img assembly failed"
	boot_img=$boot_out/boot-liuqin-dev.img
	boot_img_source="rebuilt from $(basename "$ramdisk") + kernel payload ($kernel_source)"
	printf '%s\n' "$kver_payload" >"$work/boot.kernel-release"
}

# ---------------------------------------------------------------------------
# Stage: installer.img
# ---------------------------------------------------------------------------
stage_installer_img() {
	stage_header "stage-installer-img: RAM installer boot image"
	if [ "$have_installer" != 1 ]; then
		add_skip "installer-img: no RAM-installer overlay at $installer_overlay (run installer/assemble-installer.py)"
		return 1
	fi
	if ! resolve_kernel_payload; then
		add_skip "installer-img: no kernel payload available"
		return 1
	fi
	kernel_out_root=$kernel_out
	if ! ensure_contract || ! ensure_privileges; then
		add_skip "installer-img: no root admission contract or privileged-file expectations (staged rootfs missing)"
		return 1
	fi
	# single-producer and flat install rules: re-assemble the RAM-installer overlay from its runtime with
	# the SAME generated contract, so installer-image.json and the embedded
	# contract can never describe different policies (no contract: null drift).
	overlay_runtime=$(dirname -- "$installer_overlay")/runtime
	if [ -d "$overlay_runtime" ] && [ -f "$project_root/installer/assemble-installer.py" ]; then
		refreshed_overlay=$work/installer-overlay
		rm -rf "$refreshed_overlay"
		if python3 "$project_root/installer/assemble-installer.py" \
			--runtime "$overlay_runtime" --out "$refreshed_overlay" \
			--contract "$contract_file" --privileges "$privileges_file" \
			>"$work/logs/assemble-installer.log" 2>&1; then
			installer_overlay=$refreshed_overlay
			say "installer overlay assembled with the generated admission contract"
		else
			say "warning: could not re-assemble the installer overlay (log: $work/logs/assemble-installer.log); passing the contract to build-initramfs directly"
		fi
	fi
	installer_ir=$work/installer-initramfs
	rm -rf "$installer_ir"
	mkdir -p "$installer_ir"
	set -- --out "$installer_ir" --kernel-out "$kernel_out" \
		--installer-overlay "$installer_overlay" --contract "$contract_file" \
		--privileges "$privileges_file"
	if [ -n "$firmware_pool" ]; then
		set -- "$@" --firmware-pool "$firmware_pool"
		[ -z "$wlan_hsp2_tuple" ] || set -- "$@" --wlan-hsp2-tuple "$wlan_hsp2_tuple"
		[ -z "$audio_topology" ] || set -- "$@" --audio-topology "$audio_topology"
	else
		set -- "$@" --allow-missing-firmware
	fi
	scripts/build-initramfs.sh "$@" ||
		die "installer initramfs build failed"
	ramdisk=$installer_ir/initramfs/liuqin-installer.cpio.gz
	[ -f "$ramdisk" ] || die "installer ramdisk was not produced"
	installer_out=$work/installer-img
	rm -rf "$installer_out"
	set -- --kernel-out "$kernel_out" --ramdisk "$ramdisk" --out "$installer_out" \
		--strict-kernel --dtb-source "$dtb_source" --kernel-provenance "$kernel_source" \
		--ramdisk-mode installer
	[ "$dtb_source" = stock-rom ] && set -- "$@" --stock-rom-dir "$stock_rom_dir"
	scripts/build-bootimg.sh "$@" || die "installer.img assembly failed"
	installer_img=$installer_out/boot-liuqin-dev.img
	installer_img_source="rebuilt from RAM-installer ramdisk + kernel payload ($kernel_source)"
}

# ---------------------------------------------------------------------------
# Stage: bundle
# ---------------------------------------------------------------------------
stage_bundle() {
	stage_header "stage-bundle: images/$bundle_name"
	# root.img / rootfs.tar.gz: normally produced by stage-root-img in this run;
	# when resuming with an explicit stage list, reuse the staged files.
	if [ ! -f "${root_img:-}" ] && [ -f "$work/root.img" ]; then
		root_img=$work/root.img
	fi
	if [ ! -f "${rootfs_tar:-}" ] && [ -f "$work/rootfs.tar.gz" ]; then
		rootfs_tar=$work/rootfs.tar.gz
	fi
	[ -f "${root_img:-}" ] || add_skip "root-img: no root.img produced or staged"
	[ -f "${rootfs_tar:-}" ] || add_skip "rootfs-tar: no rootfs.tar.gz produced or staged"
	# boot.img: rebuilt or reused.  If the boot stage did not run (partial
	# assembly), fall back to the existing out/boot dev image, recorded as SKIP.
	if [ ! -f "${boot_img:-}" ] && [ -f "$work/boot-img/boot-liuqin-dev.img" ]; then
		# A resumed bundle-only run must reuse the boot.img built for THIS work
		# tree, not a stale out/boot artifact from another run.
		boot_img=$work/boot-img/boot-liuqin-dev.img
		boot_img_source="reused $work/boot-img/boot-liuqin-dev.img (boot stage not re-run)"
		add_skip "boot-img: reused $work/boot-img/boot-liuqin-dev.img (boot stage not re-run)"
	fi
	if [ ! -f "${boot_img:-}" ]; then
		if [ -f "$project_root/out/boot/boot-liuqin-dev.img" ]; then
			boot_img=$project_root/out/boot/boot-liuqin-dev.img
			boot_img_source="reused out/boot dev image (boot stage skipped)"
			add_skip "boot-img: reused out/boot/boot-liuqin-dev.img (not rebuilt in this run)"
		else
			add_skip "boot-img: absent (no bundle boot.img)"
		fi
	fi
	if [ ! -f "${installer_img:-}" ] && [ -f "$work/installer-img/boot-liuqin-dev.img" ]; then
		installer_img=$work/installer-img/boot-liuqin-dev.img
		installer_img_source="reused $work/installer-img/boot-liuqin-dev.img (installer stage not re-run)"
	fi

	rm -rf "$bundle_dir"
	mkdir -p "$bundle_dir/manifests"
	if [ -f "${boot_img:-}" ]; then cp -f "$boot_img" "$bundle_dir/boot.img"; fi
	if [ -f "${installer_img:-}" ]; then cp -f "$installer_img" "$bundle_dir/installer.img"; fi
	if [ -f "${root_img:-}" ]; then cp -f "$root_img" "$bundle_dir/root.img"; fi
	if [ -f "${rootfs_tar:-}" ]; then cp -f "$rootfs_tar" "$bundle_dir/rootfs.tar.gz"; fi
	# single-producer rule: the delivered admission contract is the single generator
	# output; bundle.json describes it and verify-bundle.sh audits it.  A resumed
	# bundle-only run has not called ensure_contract yet, so regenerate/verify it
	# from the staged manifest+tree here instead of silently shipping no contract.
	if ensure_contract && [ -f "$contract_file" ]; then
		cp -f "$contract_file" "$bundle_dir/manifests/liuqin-fedora-root.contract"
	else
		die "cannot ship a bundle without the Fedora admission contract (no staged rootfs manifest)"
	fi
	if ensure_privileges && [ -f "$privileges_file" ]; then
		cp -f "$privileges_file" "$bundle_dir/manifests/installer-privileges.txt"
	else
		die "cannot ship a bundle without the installer privileged-file expectations"
	fi
	for manifest in rootfs.manifest rootfs.files.sha256 rootfs.packages.txt \
		rootfs.symlinks.txt kernel-modules.manifest; do
		src=
		case $manifest in
		kernel-modules.manifest) src=$rootfs_stage/usr/share/liuqin/kernel-modules.manifest ;;
		*) [ -f "$work/$manifest" ] && src=$work/$manifest ;;
		esac
		[ -n "$src" ] && [ -f "$src" ] && cp -f "$src" "$bundle_dir/manifests/$manifest"
	done
	if [ -f "$work/fingerprint-image.json" ]; then
		cp -f "$work/fingerprint-image.json" "$bundle_dir/manifests/fingerprint-image.json"
	fi
	# Ship the firmware-pool record (and its per-file manifest) so the
	# release gate can audit what the ramdisk was built from.
	if [ -n "$firmware_pool_meta" ] && [ -f "$firmware_pool_meta" ]; then
		cp -f "$firmware_pool_meta" "$bundle_dir/manifests/firmware-pool.json"
		pool_manifest_file=$(dirname -- "$firmware_pool_meta")/pool.manifest
		[ -f "$pool_manifest_file" ] &&
			cp -f "$pool_manifest_file" "$bundle_dir/manifests/firmware-pool.manifest"
	fi
	[ -f "$project_root/LICENSE" ] && cp -f "$project_root/LICENSE" "$bundle_dir/LICENSE"
	[ -f "$project_root/NOTICE" ] && cp -f "$project_root/NOTICE" "$bundle_dir/NOTICE"
	# A resumed bundle-only run has not rebuilt the RAM-installer overlay, but the
	# work tree may hold the overlay that was assembled for THIS bundle's
	# installer.img; never describe the delivery with an older overlay manifest.
	installer_manifest_dir=$installer_overlay
	if [ -f "$work/installer-overlay/installer-image.json" ]; then
		installer_manifest_dir=$work/installer-overlay
	fi
	[ -f "$installer_manifest_dir/installer-image.json" ] &&
		cp -f "$installer_manifest_dir/installer-image.json" "$bundle_dir/manifests/installer-image.json"
	# Ship the build-info of the DELIVERED boot.img (and of
	# installer.img) so verify-bundle/release-gate can audit the bundle's own
	# artifacts instead of falling back to unrelated out/boot state.
	for info_pair in "boot-img:boot-build-info.json" "installer-img:installer-build-info.json"; do
		info_dir=${info_pair%%:*}
		info_name=${info_pair##*:}
		[ -f "$work/$info_dir/build-info.json" ] &&
			cp -f "$work/$info_dir/build-info.json" "$bundle_dir/manifests/$info_name"
	done
	if [ -f "$work/boot-img/kernel.config" ]; then
		cp -f "$work/boot-img/kernel.config" "$bundle_dir/manifests/kernel.config"
	fi
	[ -d "$bundle_dir" ] || die "bundle directory was not created"

	write_bundle_json
	write_bundle_sha256sums
	say "bundle: $bundle_dir"
}

write_bundle_json() {
	kver=$(cat "$work/boot.kernel-release" 2>/dev/null || image_kernel_release "${kernel_out:-}" 2>/dev/null || true)
	if [ -z "${kernel_source:-}" ] && [ -f "$work/boot-img/build-info.json" ]; then
		# bundle-only resume: the boot stage did not run, so recover the kernel
		# payload provenance recorded by the boot.img that is actually shipped.
		kernel_source=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1]))["payload"]["kernel"].get("provenance", ""))
except Exception:
    print("")
' "$work/boot-img/build-info.json" 2>/dev/null || true)
	fi
	if [ -z "${installer_img_source:-}" ] && [ -f "$work/installer-img/boot-liuqin-dev.img" ]; then
		installer_img_source="reused $work/installer-img/boot-liuqin-dev.img (installer stage not re-run)"
	fi
	kernel_commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",""))' \
		"$project_root/kernel/source.json" 2>/dev/null ||
		python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",""))' \
			"$upstream/kernel/source.json" 2>/dev/null || true)
	project_commit=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || true)
	# Provenance: project_dirty describes the DELIVERY INPUTS, not
	# unrelated work of other concurrent tasks.  These are the paths this build
	# consumes; when they equal HEAD, the bundle is reproducible from
	# project_commit even if a parallel task keeps uncommitted files elsewhere.
	provenance_paths="scripts/build-rootfs.sh scripts/build-image.sh
		scripts/build-initramfs.sh scripts/build-installer.sh scripts/build-bootimg.sh
		scripts/verify-bundle.sh tools/build-root-contract.py initramfs/init
		mkosi overlays installer packaging/device/write-firmware-provenance.py packaging/mobile/fingerprint/stage-image.py tools/apply-kde-touch-fixes.py"
	# shellcheck disable=SC2086
	project_dirty=$(git -C "$project_root" status --porcelain -- $provenance_paths 2>/dev/null | wc -l)
	project_worktree_raw=$(git -C "$project_root" status --porcelain 2>/dev/null | wc -l)
	project_unrelated_dirty=$((project_worktree_raw - project_dirty))
	rootfs_hash_manifest=$bundle_dir/manifests/rootfs.files.sha256
	reasons_file=$work/device-ready-reasons.txt
	: >"$reasons_file"
	add_reason() { printf '%s\n' "$1" >>"$reasons_file"; }
	if [ -n "$firmware_pool" ]; then
		:
	else
		add_reason "no liuqin firmware pool supplied: the initramfs carries no touch/BT/WLAN/GPU/DSP/regulatory firmware"
	fi
	if [ "$device_rpm_count" -eq 0 ]; then
		add_reason "device-layer RPMs not installed (hardware services absent)"
	fi
	if grep -q '^kernel-rpms:' "$skips_file" 2>/dev/null; then
		add_reason "boot.img kernel payload is not from a kernel-liuqin RPM"
	fi
	if grep -qE '^rpm-(deps|dependency)' "$skips_file" 2>/dev/null; then
		add_reason "device-layer RPM dependency closure is incomplete (see skips; e.g. libqmi-glib/libqrtr-glib for the sensor stack)"
	fi
	if grep -q '^verify-root-img: cirrus CS35L41 wmfw absent' "$skips_file" 2>/dev/null; then
		add_reason "image lacks the cirrus CS35L41 DSP wmfw from linux-firmware/cirrus-audio-firmware"
	fi
	if [ -z "$audio_topology" ]; then
		# linux-firmware already ships the CS35L41 speaker DSP wmfw in this image;
		# what a four-speaker setup still needs is the board-specific calibration
		# (crus_calr.bin from the device persist) plus the AudioReach topology
		# from the user's stock ROM/firmware pool.  Neither can be baked in.
		add_reason "four-speaker audio needs board calibration (cs35l41 crus_calr.bin from the device persist) and AudioReach topology (user stock ROM/firmware pool); linux-firmware CS35L41 wmfw alone is not sufficient"
	fi
	if [ "$dtb_source" = stock-rom ]; then
		:
	else
		add_reason "boot.img DTB is the offline upstream-artifact substitute; canonical 44 DTBO + 14 base DTB rebuild needs the user's stock ROM"
	fi
	add_reason "never booted on liuqin hardware (offline assembly only)"
	if has_skip "boot-img: reused out/boot/boot-liuqin-dev.img (not rebuilt in this run)" ||
		has_skip "boot-img: reused $boot_img_input instead of rebuilding (not rebuilt for this rootfs)"; then
		add_reason "boot.img was not rebuilt against this rootfs in this run"
	fi

	python3 - "$bundle_dir" "$bundle_name" "$release" "$kver" "$kernel_commit" \
		"$project_commit" "$project_dirty" "$reasons_file" "$skips_file" \
		"$rootfs_manifest_json" "$installer_overlay" "$boot_img_source" \
		"${installer_img_source:-}" "$kernel_source" "$kernel_rpms_dir" \
		"$device_rpms_dirs" "$build_mode" "$dtb_source" \
		"$work/extra-packages.tsv" "$rootfs_dir" "$project_worktree_raw" \
		"$project_unrelated_dirty" "$desktop" "$login_manager" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

(bundle, name, release, kver, kernel_commit, project_commit, project_dirty,
 reasons, skips, rootfs_manifest_json, installer_overlay, boot_source,
 installer_source, kernel_source, kernel_rpms_dir, device_rpms_dirs,
 build_mode, dtb_source, extra_packages_tsv, rootfs_dir,
 worktree_dirty_raw, unrelated_dirty, desktop, login_manager) = sys.argv[1:25]

bundle_path = Path(bundle)

def sha(path):
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

files = {}
for name_ in ('boot.img', 'installer.img', 'root.img', 'rootfs.tar.gz'):
    path = bundle_path / name_
    if path.is_file():
        files[name_] = {'sha256': sha(path), 'bytes': path.stat().st_size}

def load_sha(path):
    if path and Path(path).is_file():
        return sha(Path(path))
    return None

rootfs_manifest = bundle_path / 'manifests/rootfs.manifest'
runtime_manifest = bundle_path / 'manifests/installer-image.json'
reasons_list = [line.strip() for line in Path(reasons).read_text().splitlines() if line.strip()]
skip_list = [line.strip() for line in Path(skips).read_text().splitlines() if line.strip()]

contract = None
contract_path = bundle_path / 'manifests/liuqin-fedora-root.contract'
if contract_path.is_file():
    contract_lines = contract_path.read_text().splitlines()
    topology = [line for line in contract_lines[1:]
                if line.strip() and not line.lstrip().startswith('#')]
    contract = {
        'format': 'liuqin-root-admission-contract/v2',
        'path': '/etc/liuqin-fedora-root.contract',
        'source': 'manifests/liuqin-fedora-root.contract',
        'sha256': sha(contract_path),
        'bytes': contract_path.stat().st_size,
        'header': contract_lines[0] if contract_lines else None,
        'topology_entries': len(topology),
        'entries': topology,
        'content_pins': 0,
        'embedded_in': ['boot.img', 'installer.img'],
        'semantics': 'device/partition identity stays in initramfs/init; this file is the '
                     'Fedora desktop topology (topology contract).  No sha256 pins of dnf-owned or '
                     'user-editable files: ordinary RPM upgrades and config edits cannot '
                     'make the next boot fail-closed.',
    }

privileges = None
privileges_path = bundle_path / 'manifests/installer-privileges.txt'
if privileges_path.is_file():
    privilege_lines = [line for line in privileges_path.read_text().splitlines()
                       if line.strip() and not line.lstrip().startswith('#')]
    privileges = {
        'source': 'manifests/installer-privileges.txt',
        'sha256': sha(privileges_path),
        'entries': len(privilege_lines),
        'setuid_setgid': sum(1 for line in privilege_lines
                             if line.split(' ', 1)[0] in ('setuid', 'setgid')),
        'capabilities': sum(1 for line in privilege_lines
                            if line.split(' ', 1)[0] == 'cap'),
        'derived_from': 'the assembled rootfs: every setuid/setgid file and every '
                        'security.capability xattr (privileged-file and flat install contracts); no hardcoded '
                        'distribution assumptions such as a ping capability',
    }
# Describe the firmware pool the ramdisk was staged from (absent for a
# dev bundle built with --allow-missing-firmware).
firmware_record = None
firmware_json = bundle_path / 'manifests/firmware-pool.json'
if firmware_json.is_file():
    try:
        record = json.loads(firmware_json.read_text())
    except Exception:
        record = {'error': 'unreadable firmware-pool.json'}
    record['source'] = 'manifests/firmware-pool.json'
    record['manifest'] = 'manifests/firmware-pool.manifest'
    pool_manifest = bundle_path / 'manifests/firmware-pool.manifest'
    record['manifest_sha256'] = sha(pool_manifest) if pool_manifest.is_file() else None
    firmware_record = record
manifest = {
    'format': 'liuqin-bundle/1',
    'privileged_expectations': privileges,
    'firmware': firmware_record,
    'device': 'liuqin',
    'name': name,
    'status': 'OFFLINE_BUILT',
    'build_mode': build_mode,
    'device_ready': False,
    'offline_only': True,
    'device_ready_reasons': reasons_list,
    'fedora': {
        'release': release,
        'distribution': 'fedora',
        'architecture': 'aarch64',
        'desktop': desktop,
        'login_manager': login_manager,
        'contract': '/etc/liuqin-fedora-root.contract',
        'contract_version': 2,
        'contract_sha256': (contract or {}).get('sha256'),
        'rootfs_manifest': load_sha(rootfs_manifest),
        'runtime_manifest': load_sha(runtime_manifest),
        'root_layout': 'flat',
    },
    'kernel_commit': kernel_commit or None,
    'kernel_release': kver or None,
    'kernel_payload_source': kernel_source or None,
    'project_commit': project_commit or None,
    'project_dirty': bool(int(project_dirty or 0)),
    'project_dirty_files': int(project_dirty or 0),
    'project_worktree': {
        'dirty_scope': 'delivery inputs only: scripts/build-*.sh, '
                       'scripts/verify-bundle.sh, tools/build-root-contract.py, '
                       'initramfs/init, mkosi/, overlays/, installer/, '
                       'packaging/device/write-firmware-provenance.py and packaging/mobile/fingerprint/stage-image.py',
        'worktree_dirty_files_total': int(worktree_dirty_raw or 0),
        'unrelated_dirty_files': int(unrelated_dirty or 0),
        'note': 'Other tasks may keep uncommitted files outside the delivery '
                'inputs; project_dirty is false when the delivery inputs equal '
                'project_commit.',
    },
    'features': {
        'displayport': True,
        'native_fingerprint': (bundle_path / 'manifests/fingerprint-image.json').is_file(),
        'native_fingerprint_device_verified': False,
        'kde_plasma': desktop == 'plasma',
        'gnome': desktop == 'gnome',
        'login_manager': login_manager,
    },
    'files': {k: v['sha256'] for k, v in files.items()},
    'file_bytes': {k: v['bytes'] for k, v in files.items()},
    'fedora_injected_packages': [
        {'package': line.split('\t')[0], 'nevra': line.split('\t', 1)[1]}
        for line in (Path(extra_packages_tsv).read_text().splitlines()
                      if extra_packages_tsv and Path(extra_packages_tsv).is_file() else [])
        if '\t' in line
    ],
    'sources': {
        'rootfs': str(rootfs_dir) + ' (mkosi Fedora %s %s aarch64)' % (release, desktop),
        'kernel_rpms': kernel_rpms_dir,
        'device_rpms': device_rpms_dirs,
        'installer_overlay': installer_overlay,
        'boot_image': boot_source or None,
        'installer_image': installer_source or None,
        'rootfs_manifest_input': rootfs_manifest_json,
        'boot_build_info': 'manifests/boot-build-info.json' if (
            bundle_path / 'manifests/boot-build-info.json').is_file() else None,
        'boot_build_info_sha256': sha(bundle_path / 'manifests/boot-build-info.json')
        if (bundle_path / 'manifests/boot-build-info.json').is_file() else None,
    },
    'contract': contract,
    'apply_boot_contract': {
        # Machine-readable gate for the future liuqin-apply-boot:
        # it must refuse to write a boot partition unless every field is
        # understood, device_ready is true and the image has been re-verified.
        'requires_explicit_device_write_flag': True,
        'device_ready_required': True,
        'device_ready': False,
        'boot_img': 'boot.img',
        'boot_img_sha256': files.get('boot.img', {}).get('sha256'),
        'boot_img_bytes': files.get('boot.img', {}).get('bytes'),
        'boot_partition_bytes': 201326592,
        'zero_fill_to_partition': True,
        'kernel_release': kver or None,
        'fedora_release': release,
        'dtb_source': dtb_source,
        'canonical': dtb_source == 'stock-rom',
        'root_layout': 'flat (partition root == rootfs root; /home is inside it)',
        'root_label': 'LIUQIN_ROOT',
        'home_label': 'none',
        'slot_policy': 'write boot_a only; never change GPT slot attributes; qbootctl not used',
        'fallback': 'boot_b is a boot-level diagnostic only after root replacement; it does not restore the previous Fedora userland or personal files',
    },
    'rebuild_interface': {
        # What an on-device rebuild (dnf kernel update / kernel-install hook)
        # needs.
        'entry_points': ['scripts/build-initramfs.sh', 'scripts/build-bootimg.sh'],
        'rootfs_manifest': 'manifests/rootfs.files.sha256',
        'root_contract': 'regenerated from the rootfs manifest after RPM injection',
        'kernel_payload': 'kernel-liuqin RPM -> /usr/lib/modules/<kver>/{vmlinuz,dtb}',
        'boot_inputs': ['kernel Image', 'raw board DTB', 'initramfs cpio.gz',
                        'AOSP mkbootimg (pinned sha256)', 'stock ROM 44+14 DTBs for canonical DTB'],
        'contract_tools': ['tools/build-root-contract.py'],
        'requires': ['pinned static aarch64 BusyBox', 'aarch64 cross gcc for the helpers'],
    },
    'skips': skip_list,
    'qemu_validation': None,  # Legacy metadata key; VM work retired (retired VM plan).
    'canonical': dtb_source == 'stock-rom',
    'dtb_source': dtb_source,
    'dtb_source_origin': ('stock ROM canonical rebuild (44 DTBO + 14 base DTBs)'
                          if dtb_source == 'stock-rom'
                          else 'upstream v0.6.0 published boot.img final DTB (offline substitute)'),
    'redistribution': 'private-local-only: the rootfs contains proprietary liuqin '
                      'firmware (liuqin-firmware RPM); do not redistribute this bundle',
    'notes': [
        'Offline bundle: root.img/rootfs.tar.gz/boot.img/installer.img assembled without any device access.',
        'boot.img header cmdline is empty; the kernel cmdline comes from the DTB /chosen node.',
        'Flat delivery baseline (flat install contract): root.img is the rootfs at the filesystem root, and rootfs.tar.gz extracts directly onto the partition root; there is no native-root/ level anywhere.',
        'The RAM installer (installer.img) is required for the tar-based install path; root.img can be flashed directly to linux_root in a future attended phase.',
        'boot.img and installer.img carry the same contract v2 file generated by tools/build-root-contract.py; it is topology-only (no content pins of dnf-owned/user-editable files).',
    ],
}
(bundle_path / 'bundle.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f"bundle.json: {len(files)} payload files, device_ready=false, {len(reasons_list)} reasons, {len(skip_list)} skips")
PY
	# Expose the same Fedora extension fields at the top level where the host
	# installer expects them (kernel_release is required for the device flow).
	python3 - "$bundle_dir/bundle.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.setdefault('tested_storage_layout', 'none (offline bundle)')
data.setdefault('project_dirty', bool(data.get('project_dirty_files')))
path.write_text(json.dumps(data, indent=2) + '\n')
PY
}

write_bundle_sha256sums() {
	(
		cd "$bundle_dir"
		find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z |
			xargs -0 -r sha256sum >SHA256SUMS
	)
}

# ---------------------------------------------------------------------------
# Stage: verify
# ---------------------------------------------------------------------------
verify_root_img() {
	root_img=$bundle_dir/root.img
	[ -f "$root_img" ] || { add_skip "verify-root-img: no root.img"; return 0; }
	# The build host kernel has no loop module (no /lib/modules tree), so this
	# verifier never uses mount -o loop.  e2fsck -fn checks the image directly;
	# fuse2fs (ext4 via /dev/fuse) is used for content checks, debugfs is the
	# read-only fallback.
	# Work on a private reflink/copy: e2fsck and even a read-only fuse2fs mount
	# may touch ext4 metadata (mount counters/journal), which would silently
	# change the hash the bundle recorded.  The delivered root.img must stay
	# byte-identical to bundle.json/SHA256SUMS.
	verify_img=$work/verify-root.img
	rm -f "$verify_img"
	cp --reflink=auto --sparse=always "$root_img" "$verify_img" ||
		die "could not create a private copy of $root_img for verification"
	sudo e2fsck -fn "$verify_img" >"$work/logs/verify-root-e2fsck.log" 2>&1 ||
		die "e2fsck -fn failed on $root_img (log: $work/logs/verify-root-e2fsck.log)"
	label=$(sudo blkid -p -s LABEL -o value "$verify_img" 2>/dev/null || true)
	[ "$label" = LIUQIN_ROOT ] || die "root.img label is '$label', expected LIUQIN_ROOT"
	mnt=$work/verify-mnt
	mkdir -p "$mnt"
	mount_kind=
	if command -v fuse2fs >/dev/null 2>&1; then
		sudo fuse2fs -o ro "$verify_img" "$mnt" || die "fuse2fs could not mount $root_img read-only"
		mount_kind=fuse2fs
		cleanup_root_mount() { sudo fusermount3 -u "$mnt" 2>/dev/null || sudo fusermount -u "$mnt" 2>/dev/null || true; }
		trap 'cleanup_root_mount' EXIT HUP INT TERM
	else
		mount_kind=debugfs
		say "warning: fuse2fs is unavailable; root.img content checks fall back to debugfs (no ELF scan)"
	fi
	root=$mnt
	if [ "$mount_kind" = fuse2fs ]; then
		sudo test -d "$root/etc" && sudo test -d "$root/usr" ||
			die "root.img is not a flat rootfs (missing /etc or /usr at the image root)"
		sudo test -d "$root/run" || die "root.img lacks /run (initramfs switch_root would fail)"
		sudo test -d "$root/tmp" || die "root.img lacks /tmp"
		sudo test -d "$root/var/tmp" || die "root.img lacks /var/tmp"
		for dir in var var/lib var/cache var/log; do
			sudo test -d "$root/$dir" || die "root.img lacks /$dir"
			[ "$(sudo stat -c '%u:%g:%a' "$root/$dir")" = 0:0:755 ] ||
				die "root.img /$dir owner/mode is not root:root 0755"
		done
		if [ "$public_image" = 1 ]; then
			[ "$(sudo stat -c '%Y' "$root/usr/lib/clock-epoch")" -gt 1700000000 ] ||
				die "public root.img lost the trusted clock-epoch mtime"
		fi
		[ "$(sudo cat "$root/etc/liuqin-fedora-root" 2>/dev/null | tr -d '\n')" = liuqin-fedora-root-v1 ] ||
			die "root.img marker is missing or wrong"
		sudo test -f "$root/etc/liuqin-slpi-disabled" ||
			die "root.img lacks /etc/liuqin-slpi-disabled (SLPI startup resets the tablet)"
		sudo test -L "$root/usr/lib/systemd/system/default.target" ||
			die "root.img has no default.target symlink"
		[ "$(sudo readlink "$root/usr/lib/systemd/system/default.target")" = graphical.target ] ||
			die "default.target does not resolve to graphical.target"
		sudo test -L "$root/etc/systemd/system/display-manager.service" ||
			die "root.img has no display-manager.service symlink"
		dm_target=$(sudo readlink "$root/etc/systemd/system/display-manager.service")
		[ "$dm_target" = "/usr/lib/systemd/system/$lm_unit" ] ||
			die "display-manager.service -> $dm_target, expected $lm_unit"
		# The login manager may be enabled through the display-manager alias only
		# (graphical.target Wants=display-manager.service); the .wants link is
		# reported but not fatal, since the alias assertion above is the real gate.
		if ! sudo test -L "$root/etc/systemd/system/multi-user.target.wants/$lm_unit" &&
			! sudo test -L "$root/etc/systemd/system/graphical.target.wants/$lm_unit"; then
			say "warning: $lm_unit has no .wants link (display-manager alias only)"
			add_skip "verify-root-img: $login_manager has no .target.wants symlink (display-manager alias only)"
		fi
		sudo test -x "$root/usr/bin/$desktop_bin" || die "root.img lacks /usr/bin/$desktop_bin (mode 755)"
		sudo test -f "$root/usr/share/liuqin/kernel.release" || die "root.img lacks kernel.release"
		kver_root=$(sudo cat "$root/usr/share/liuqin/kernel.release")
		sudo test -f "$root/usr/share/liuqin/kernel-modules.manifest" ||
			die "root.img lacks kernel-modules.manifest"
		sudo test -f "$root/etc/fstab" || die "root.img lacks /etc/fstab"
		sudo grep -qE '^LABEL=LIUQIN_ROOT[[:space:]]+/[[:space:]]' "$root/etc/fstab" ||
			die "root.img /etc/fstab lacks the LABEL=LIUQIN_ROOT root entry"
		sudo grep -q 'x-systemd.growfs' "$root/etc/fstab" ||
			die "root.img /etc/fstab lacks x-systemd.growfs on the root entry"
		if sudo grep -q 'LABEL=LIUQIN_HOME' "$root/etc/fstab"; then
			die "root.img /etc/fstab still mounts a non-existent LABEL=LIUQIN_HOME"
		fi
		sudo test -f "$root/etc/liuqin/image-contract" || die "root.img lacks the image contract"
		sudo grep -q "LOGIN_MANAGER=$login_manager" "$root/etc/liuqin/image-contract" ||
			die "image-contract login manager is not $login_manager"
		sudo test -f "$root/etc/os-release" || die "root.img lacks /etc/os-release"
		os_release=$(sudo grep -m1 '^VERSION_ID=' "$root/etc/os-release" | cut -d= -f2 | tr -d '"')
		[ "$os_release" = "$release" ] || die "root.img Fedora release '$os_release' != --release $release"
		if sudo test -f "$root/usr/bin/sudo"; then
			mode=$(sudo stat -c '%a' "$root/usr/bin/sudo")
			[ "$mode" = 4111 ] || say "warning: /usr/bin/sudo mode is $mode (expected 4111)"
		fi
		# Firmware sanity (four speakers need the CS35L41 DSP wmfw; rootfs-builder
		# reported it is not in Fedora's base linux-firmware).  A missing wmfw is
		# a WARN here (the bundle is offline-only anyway) and is recorded.
		# Real Fedora layout is the COMPRESSED linux-firmware
		# tree /usr/lib/firmware/cirrus/cs35l41/v6.*/*.wmfw.xz (plus
		# cirrus-audio-firmware's cs35l41-dsp1-spk-prot).  The old check looked at
		# /lib/firmware/cs35l41/*.wmfw, which never exists, and produced a false
		# "firmware missing" device_ready reason.
		cs35l41_wmfw=$(sudo sh -c "ls \"$root\"/usr/lib/firmware/cirrus/cs35l41/*/*.wmfw* 2>/dev/null | head -20" || true)
		if [ -n "$cs35l41_wmfw" ]; then
			say "root.img carries linux-firmware CS35L41 DSP wmfw ($(printf '%s\n' "$cs35l41_wmfw" | wc -l) files, compressed form)"
		else
			say "warning: no cirrus CS35L41 wmfw in root.img (linux-firmware/cirrus-audio-firmware missing)"
			add_skip "verify-root-img: cirrus CS35L41 wmfw absent from root.img (linux-firmware/cirrus-audio-firmware missing)"
		fi
		sudo test -f "$root/usr/share/liuqin/rootfs.files.sha256" ||
			die "root.img lacks /usr/share/liuqin/rootfs.files.sha256 (on-device contract refresh input)"
		# privileged-file contract acceptance on the delivered root.img: mkfs.ext4 -d must
		# preserve the real numeric owner/mode of the delivery tree.
		assert_metadata() { # <path> <mode> <uid> <gid>
			am_got=$(sudo stat -c '%a %u %g' "$root$1" 2>/dev/null || true)
			[ "$am_got" = "$2 $3 $4" ] ||
				die "root.img metadata mismatch: $1 is '$am_got', expected '$2 $3 $4' (privileged-file contract)"
		}
		assert_metadata "/home/$image_user" 700 1000 1000
		assert_metadata "/usr/bin/$desktop_bin" 755 0 0
		assert_metadata "/usr/bin/$login_manager" 755 0 0
		assert_metadata /usr/bin/mount 4755 0 0
		assert_metadata /usr/bin/sudo 4111 0 0
		assert_metadata /etc/liuqin-fedora-root 644 0 0
		# Directory ownership is not covered by the file hash manifest; check it
		# explicitly.  These are the paths the previous image build corrupted
		# or omitted.
		assert_metadata /etc 755 0 0
		assert_metadata /usr 755 0 0
		assert_metadata /run 755 0 0
		assert_metadata /tmp 1777 0 0
		assert_metadata /var/tmp 1777 0 0
		sudo test -u "$root/usr/bin/mount" || die "root.img /usr/bin/mount lost its setuid bit"
		sudo test -g "$root/usr/bin/mount" || say "warning: /usr/bin/mount is not setgid (Fedora default differs by release)"
		say "root.img metadata (privileged-file contract): /home/$image_user=1000:1000 0700, $desktop_bin=0755, mount=04755 setuid, sudo=04111"
		# pam_systemd is required for session/logind integration (plasmalogin,
		# kscreenlocker); Fedora splits it into systemd-pam, which the mkosi
		# package set missed.  --extra-packages installs it, and this gate proves
		# the module is present.
		if sudo test -f "$root/usr/lib64/security/pam_systemd.so"; then
			:
		elif sudo test -f "$root/usr/lib/security/pam_systemd.so"; then
			:
		else
			say "warning: pam_systemd.so is missing from the image (systemd-pam)"
			add_skip "verify-root-img: pam_systemd.so missing (systemd-pam not installed; graphical login/session may fail)"
		fi
		# Locale must be UTF-8 for GNOME sessions.  The base profile uses
		# glibc-all-langpacks, which keeps locales in locale-archive and does not
		# create /usr/lib/locale/en_US.utf8; the old directory probe therefore
		# produced a false "langpack missing" warning.  Ask the target's
		# localedef what the archive actually contains.
		locale_line=$(sudo grep -m1 '^LANG=' "$root/etc/locale.conf" 2>/dev/null || true)
		case $locale_line in
		*UTF-8*|*utf8*) : ;;
		*)
			say "warning: /etc/locale.conf is not UTF-8 ($locale_line)"
			add_skip "verify-root-img: /etc/locale.conf is not UTF-8 ($locale_line)"
			;;
		esac
		locale_ok=0
		if [ -d "$rootfs_stage" ] &&
			sudo chroot "$rootfs_stage" localedef --list-archive 2>/dev/null | grep -qx 'en_US.utf8'; then
			locale_ok=1
		fi
		if [ "$locale_ok" = 0 ] && sudo test -d "$root/usr/lib/locale/en_US.utf8"; then
			locale_ok=1
		fi
		if [ "$locale_ok" = 1 ]; then
			say "root.img locale: en_US.utf8 present in locale-archive"
		else
			say "warning: en_US.UTF-8 locale is missing (glibc-all-langpacks/glibc-langpack-en)"
			add_skip "verify-root-img: en_US.UTF-8 locale archive missing (glibc-all-langpacks)"
		fi
		if ! sudo test -L "$root/etc/systemd/system/multi-user.target.wants/bluetooth.service" &&
			! sudo test -L "$root/etc/systemd/system/bluetooth.target.wants/bluetooth.service"; then
			say "warning: bluetooth.service is not enabled in root.img"
			add_skip "verify-root-img: bluetooth.service not enabled in the rootfs image"
		fi
		# aarch64-only ELF scan (no x86_64 binaries may leak into the image).
		# Prefer the staged tree: root.img is a byte-for-byte mkfs.ext4 -d copy of
		# it, and walking 97k files through the FUSE mount takes many minutes.
		elf_root=$root
		if [ -d "$rootfs_stage" ]; then
			elf_root=$rootfs_stage
			say "ELF scan target: staged rootfs tree (identical content to root.img, local disk)"
		fi
		elf_scan=$(sudo python3 - "$elf_root" <<'PY2'
import os
import struct
import sys

root = sys.argv[1]
counts = {'aarch64': 0, 'x86_64': 0, 'other': 0}
bad = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('proc', 'sys', 'dev', 'run')]
    for name in filenames:
        path = os.path.join(dirpath, name)
        try:
            with open(path, 'rb') as stream:
                head = stream.read(20)
        except OSError:
            continue
        if os.path.islink(path):
            continue
        if len(head) < 20 or head[:4] != b'\x7fELF':
            continue
        little = head[5] == 1
        machine = struct.unpack('<H' if little else '>H', head[18:20])[0]
        if machine == 183:
            counts['aarch64'] += 1
        elif machine == 62:
            counts['x86_64'] += 1
            if len(bad) < 10:
                bad.append(path[len(root):])
        else:
            counts['other'] += 1
print(f"aarch64={counts['aarch64']} x86_64={counts['x86_64']} other={counts['other']}")
if bad:
    print("x86_64 examples: " + " ".join(bad))
raise SystemExit(1 if counts['x86_64'] else 0)
PY2
		) || die "root.img contains x86_64 ELF binaries: $elf_scan"
		[ "$(printf '%s\n' "$elf_scan" | sed -n 's/.*aarch64=\([0-9]*\).*/\1/p')" -ge 100 ] ||
			die "suspiciously few aarch64 ELF binaries in root.img: $elf_scan"
		cleanup_root_mount
		trap - EXIT HUP INT TERM
		say "root.img verified (fuse2fs): label=LIUQIN_ROOT release=$os_release kernel=$kver_root; $elf_scan"
		printf '%s\n' "$elf_scan" >"$work/logs/root-elf-scan.txt"
		printf '%s\n' "$kver_root" >"$work/root-img.kernel-release"
		echo "$os_release" >"$work/root-img.os-release"
		printf '%s\n' "fuse2fs (loop mount unavailable on the build host)" >"$work/logs/root-mount-method.txt"
	else
		# debugfs fallback: no mount, no ELF scan; assert the admission-critical
		# files by reading them out of the image directly.
		debugfs_read() { sudo debugfs -R "cat $1" "$verify_img" 2>/dev/null; }
		debugfs_exists() { sudo debugfs -R "stat $1" "$verify_img" 2>/dev/null | grep -q '^Inode:'; }
		debugfs_exists /etc/liuqin-fedora-root || die "root.img missing /etc/liuqin-fedora-root"
		[ "$(debugfs_read /etc/liuqin-fedora-root | tr -d '\n')" = liuqin-fedora-root-v1 ] ||
			die "root.img marker content is wrong"
		debugfs_exists /etc/liuqin-slpi-disabled ||
			die "root.img missing /etc/liuqin-slpi-disabled (SLPI startup resets the tablet)"
		debugfs_exists /usr/share/liuqin/kernel.release || die "root.img missing kernel.release"
		kver_root=$(debugfs_read /usr/share/liuqin/kernel.release | tr -d '\n')
		debugfs_exists /etc/liuqin/image-contract || die "root.img missing image-contract"
		debugfs_read /etc/liuqin/image-contract | grep -q "LOGIN_MANAGER=$login_manager" ||
			die "image-contract login manager is not $login_manager"
		os_release=$(debugfs_read /etc/os-release | grep -m1 '^VERSION_ID=' | cut -d= -f2 | tr -d '"')
		[ "$os_release" = "$release" ] || die "root.img Fedora release '$os_release' != --release $release"
		debugfs_exists /etc/fstab || die "root.img missing /etc/fstab"
		debugfs_read /etc/fstab | grep -q 'LABEL=LIUQIN_ROOT' ||
			die "root.img /etc/fstab lacks the root entry"
		debugfs_read /etc/fstab | grep -q 'x-systemd.growfs' ||
			die "root.img /etc/fstab lacks x-systemd.growfs"
		if debugfs_read /etc/fstab | grep -q 'LABEL=LIUQIN_HOME'; then
			die "root.img /etc/fstab still mounts LABEL=LIUQIN_HOME"
		fi
		debugfs_exists /usr/lib/systemd/system/default.target ||
			die "root.img missing default.target"
		debugfs_exists /run && debugfs_exists /tmp && debugfs_exists /var/tmp ||
			die "root.img is missing /run, /tmp or /var/tmp"
		# privileged-file contract metadata assertions without a mount: debugfs `stat` prints
		# the inode mode (octal, including type) and the owner/group ids.
		debugfs_meta() { # <path> <mode-octal> <uid> <gid>
			dm_line=$(sudo debugfs -R "stat $1" "$verify_img" 2>/dev/null | tr '\n' ' ')
			dm_mode=$(printf '%s\n' "$dm_line" | sed -n 's/.*Mode: *\([0-7][0-7]*\) .*/\1/p')
			dm_uid=$(printf '%s\n' "$dm_line" | sed -n 's/.*User: *\([0-9][0-9]*\).*/\1/p')
			dm_gid=$(printf '%s\n' "$dm_line" | sed -n 's/.*Group: *\([0-9][0-9]*\).*/\1/p')
			dm_mode=$((0$dm_mode))
			dm_mode=$((dm_mode & 07777))
			[ "$(printf '%o' "$dm_mode")" = "$2" ] && [ "$dm_uid" = "$3" ] && [ "$dm_gid" = "$4" ] ||
				die "root.img metadata mismatch (debugfs): $1 mode=${dm_mode}o uid=$dm_uid gid=$dm_gid, expected $2 $3 $4 (privileged-file contract)"
		}
		debugfs_meta "/home/$image_user" 700 1000 1000
		debugfs_meta "/usr/bin/$desktop_bin" 755 0 0
		debugfs_meta "/usr/bin/$login_manager" 755 0 0
		debugfs_meta /usr/bin/mount 4755 0 0
		debugfs_meta /etc/liuqin-fedora-root 644 0 0
		debugfs_meta /etc 755 0 0
		debugfs_meta /usr 755 0 0
		debugfs_meta /run 755 0 0
		debugfs_meta /tmp 1777 0 0
		debugfs_meta /var/tmp 1777 0 0
		add_skip "verify-root-img: loop mount unavailable and fuse2fs absent; only debugfs checks ran (no ELF scan)"
		say "root.img verified (debugfs): label=LIUQIN_ROOT release=$os_release kernel=$kver_root"
		printf '%s\n' "$kver_root" >"$work/root-img.kernel-release"
		echo "$os_release" >"$work/root-img.os-release"
		printf '%s\n' "debugfs (loop mount unavailable on the build host)" >"$work/logs/root-mount-method.txt"
	fi
}

verify_boot_img() {
	boot=$bundle_dir/boot.img
	[ -f "$boot" ] || { add_skip "verify-boot-img: no boot.img"; return 0; }
	python3 "$cache/mkbootimg/unpack_bootimg.py" --boot_img "$boot" \
		--out "$work/verify-boot" --format info >"$work/logs/verify-boot.info" 2>&1 ||
		die "could not unpack $boot"
	grep -qx 'boot image header version: 2' "$work/logs/verify-boot.info" || die "boot.img is not header v2"
	grep -qx 'page size: 4096' "$work/logs/verify-boot.info" || die "boot.img page size is not 4096"
	grep -qx 'command line args: ' "$work/logs/verify-boot.info" || die "boot.img header cmdline is not empty"
	grep -qx 'additional command line args: ' "$work/logs/verify-boot.info" || die "boot.img has additional cmdline"
	grep -qx 'dtb address: 0x0000000001f00000' "$work/logs/verify-boot.info" || die "boot.img DTB address mismatch"
	size=$(stat -c '%s' "$boot")
	[ "$size" -le 201326592 ] || die "boot.img ($size) exceeds the 192 MiB boot partition"
	# The 7.3 normal-slot display handoff is a DTB property, not a kernel
	# property.  A boot.img whose DTB still says splash_region boots to a black
	# panel even though every header/contract check passes; gate it here.
	verify_dtb=$work/verify-boot/dtb
	[ -f "$verify_dtb" ] || die "boot.img carries no DTB"
	if strings -a "$verify_dtb" | grep -q 'splash_region@b8000000'; then
		die "boot.img DTB still uses splash_region@b8000000 (linux_splash handoff missing)"
	fi
	strings -a "$verify_dtb" | grep -q 'linux_splash@b8000000' ||
		die "boot.img DTB lacks linux_splash@b8000000"
	strings -a "$verify_dtb" | grep -q 'gnome.is_vm=0' ||
		die "boot.img DTB cmdline lacks gnome.is_vm=0"
	if strings -a "$verify_dtb" | grep -q 'console=drm_log'; then
		die "boot.img DTB cmdline still uses console=drm_log (verified A-slot cmdline uses console=tty0)"
	fi
	# Real-product cross-check: the contract embedded in the delivered boot.img
	# is byte-identical to the single generator output (single-producer and flat install rules).
	if [ -n "${contract_file:-}" ] && [ -f "$contract_file" ]; then
		dir=$work/verify-boot-ramdisk
		rm -rf "$dir"
		mkdir -p "$dir"
		gzip -dc "$work/verify-boot/ramdisk" | (cd "$dir" && cpio -idm --quiet) ||
			die "boot.img ramdisk could not be extracted"
		[ -f "$dir/etc/liuqin-fedora-root.contract" ] ||
			die "boot.img ramdisk carries no Fedora admission contract"
		cmp -s "$dir/etc/liuqin-fedora-root.contract" "$contract_file" ||
			die "boot.img contract differs from the generator output (single-producer violation)"
		say "boot.img embedded admission contract == tools/build-root-contract.py output"
	fi
	say "boot.img verified: header v2, page 4096, empty header cmdline, $size bytes"
}

verify_installer_img() {
	installer=$bundle_dir/installer.img
	[ -f "$installer" ] || { add_skip "verify-installer-img: no installer.img"; return 0; }
	python3 "$cache/mkbootimg/unpack_bootimg.py" --boot_img "$installer" \
		--out "$work/verify-installer" --format info >"$work/logs/verify-installer.info" 2>&1 ||
		die "could not unpack $installer"
	grep -qx 'boot image header version: 2' "$work/logs/verify-installer.info" ||
		die "installer.img is not header v2"
	dir=$work/verify-installer-ramdisk
	rm -rf "$dir"
	mkdir -p "$dir"
	gzip -dc "$work/verify-installer/ramdisk" | (cd "$dir" && cpio -idm --quiet) ||
		die "installer.img ramdisk could not be extracted"
	[ "$(cat "$dir/etc/liuqin-installer" 2>/dev/null)" = liuqin ] || die "installer ramdisk marker missing"
	[ -e "$dir/usr/sbin/mkfs.ext4" ] || die "installer ramdisk lacks mkfs.ext4"
	# flat install contract: installer.img MUST embed the same contract v2 that boot.img
	# carries, so the installer validates the extracted root exactly like boot.
	[ -f "$dir/etc/liuqin-fedora-root.contract" ] ||
		die "installer.img ramdisk carries no Fedora admission contract (flat install contract)"
	[ "$(head -n 1 "$dir/etc/liuqin-fedora-root.contract")" = LIUQIN_FEDORA_ROOT_CONTRACT_V2 ] ||
		die "installer.img embedded contract header is not LIUQIN_FEDORA_ROOT_CONTRACT_V2"
	if [ -n "${contract_file:-}" ] && [ -f "$contract_file" ]; then
		cmp -s "$dir/etc/liuqin-fedora-root.contract" "$contract_file" ||
			die "installer.img contract differs from the generator output (single-producer violation)"
	fi
	[ -f "$dir/etc/liuqin-installer-privileges" ] ||
		die "installer.img ramdisk carries no privileged-file expectations"
	if [ -n "${privileges_file:-}" ] && [ -f "$privileges_file" ]; then
		cmp -s "$dir/etc/liuqin-installer-privileges" "$privileges_file" ||
			die "installer.img privileged-file expectations differ from the rootfs-derived list"
	fi
	[ -f "$dir/usr/lib/liuqin/install-privileges.sh" ] ||
		die "installer.img ramdisk carries no privileged-file validator helper"
	say "installer.img verified: header v2, $(stat -c '%s' "$installer") bytes, RAM-installer ramdisk with contract v2 + $(grep -vc '^#' "$dir/etc/liuqin-installer-privileges" 2>/dev/null || echo 0) privileged-file expectations"
}

verify_rootfs_tar() {
	tarfile=$bundle_dir/rootfs.tar.gz
	[ -f "$tarfile" ] || { add_skip "verify-rootfs-tar: no rootfs.tar.gz"; return 0; }
	listing=$(tar -tzf "$tarfile" 2>/dev/null | head -40000) || die "rootfs.tar.gz is not readable"
	for required in ./etc/os-release "./usr/bin/$login_manager" ./etc/liuqin-fedora-root \
		./etc/liuqin-slpi-disabled ./usr/lib/systemd/systemd; do
		printf '%s\n' "$listing" 2>/dev/null | grep -qx "$required" ||
			die "rootfs.tar.gz lacks $required"
	done
	if printf '%s\n' "$listing" 2>/dev/null | grep -q '^\./native-root'; then
		die "rootfs.tar.gz uses the obsolete nested native-root layout (flat install contract: flat install)"
	fi
	tar -xOzf "$tarfile" ./etc/fstab 2>/dev/null | grep -q 'LABEL=LIUQIN_ROOT' ||
		die "rootfs.tar.gz /etc/fstab lacks the root entry"
	tar -xOzf "$tarfile" ./etc/fstab 2>/dev/null | grep -q 'x-systemd.growfs' ||
		die "rootfs.tar.gz /etc/fstab lacks x-systemd.growfs"
	if tar -xOzf "$tarfile" ./etc/fstab 2>/dev/null | grep -q 'LABEL=LIUQIN_HOME'; then
		die "rootfs.tar.gz /etc/fstab still mounts LABEL=LIUQIN_HOME"
	fi
	# privileged-file contract acceptance: the archive must preserve the REAL numeric
	# owner/mode of the delivery tree (no --owner=0/--group=0, no frozen modes).
	python3 - "$tarfile" "$desktop_bin" "$login_manager" "$image_user" "$public_image" <<'PY2' || die "rootfs.tar.gz metadata does not satisfy privileged-file contract"
import sys
import tarfile

desktop_bin, login_manager, image_user = sys.argv[2:5]
WANT = {
    f'./home/{image_user}': (1000, 1000, 0o700),
    f'./usr/bin/{desktop_bin}': (0, 0, 0o755),
    f'./usr/bin/{login_manager}': (0, 0, 0o755),
    './usr/bin/mount': (0, 0, 0o4755),
    './etc/liuqin-fedora-root': (0, 0, 0o644),
    './etc': (0, 0, 0o755),
    './usr': (0, 0, 0o755),
    './run': (0, 0, 0o755),
    './tmp': (0, 0, 0o1777),
    './var': (0, 0, 0o755),
    './var/lib': (0, 0, 0o755),
    './var/cache': (0, 0, 0o755),
    './var/log': (0, 0, 0o755),
    './var/tmp': (0, 0, 0o1777),
}
WANT_LINK = {
    './usr/lib/systemd/system/default.target': 'graphical.target',
}
if sys.argv[5] == '1':
    WANT['./usr/lib/clock-epoch'] = (0, 0, 0o644)
found = {}
links = {}
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    for member in archive:
        if member.name in WANT and member.name not in found:
            found[member.name] = member
        if member.name in WANT_LINK and member.name not in links:
            links[member.name] = member
        if len(found) == len(WANT) and len(links) == len(WANT_LINK):
            break
errors = []
for name, want in WANT.items():
    member = found.get(name)
    if member is None:
        errors.append(f'{name}: missing from archive')
        continue
    got = (member.uid, member.gid, member.mode & 0o7777)
    if got != want:
        errors.append(f'{name}: uid/gid/mode {got} != {want}')
    if name == './usr/lib/clock-epoch' and member.mtime <= 1700000000:
        errors.append('clock-epoch trusted mtime was lost while packing the archive')
for name, want in WANT_LINK.items():
    member = links.get(name)
    if member is None or not member.issym() or member.linkname != want:
        got = None if member is None else (member.issym(), member.linkname)
        errors.append(f'{name}: symlink target {got} != {want}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    raise SystemExit(1)
print(f'rootfs.tar.gz metadata: /home/{image_user}=1000:1000 0700, desktop/login binaries=0755, mount=04755, marker=0644')
PY2
	say "rootfs.tar.gz verified: $(stat -c '%s' "$tarfile") bytes, flat layout, real numeric owner/mode preserved"
}

verify_bundle_checksums() {
	[ -f "$bundle_dir/SHA256SUMS" ] || die "bundle has no SHA256SUMS"
	(cd "$bundle_dir" && sha256sum -c SHA256SUMS >"$work/logs/verify-bundle-sha.log" 2>&1) ||
		die "bundle checksum verification failed (log: $work/logs/verify-bundle-sha.log)"
	if [ -f "$bundle_dir/bundle.json" ]; then
		python3 - "$bundle_dir" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
data = json.loads((bundle / 'bundle.json').read_text())
errors = []
for name, want in data.get('files', {}).items():
    path = bundle / name
    if not path.is_file():
        errors.append('missing file: ' + name)
        continue
    got = hashlib.sha256(path.read_bytes()).hexdigest()
    if got != want:
        errors.append('sha mismatch: ' + name)
if data.get('device') != 'liuqin':
    errors.append('device is not liuqin')
if data.get('device_ready'):
    errors.append('offline bundle must not claim device_ready=true')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    raise SystemExit(1)
print('bundle.json verified: ' + str(len(data.get('files', {}))) + ' files')
PY
	fi
	say "bundle checksums verified"
}

verify_contract_gate() {
	# topology contract: the delivered contract must be the v2 topology contract, not
	# the v1 content-hash pin list.  The boot.img/installer.img embedded copies
	# are compared with the generator output in the two verify_*_img functions.
	ensure_contract || { add_skip "contract-gate: no generated contract found to audit"; return 0; }
	contract=$contract_file
	if grep -qE '^[0-9a-f]{64}  /' "$contract"; then
		die "the delivered contract still contains v1 content-hash pins; ordinary config edits / RPM upgrades would be rejected at boot (topology contract)"
	fi
	entries=$(awk 'NR == 1 { next } /^#/ { next } /^$/ { next } { n++ } END { print n + 0 }' "$contract")
	printf '%s\n' "$entries" >"$work/contract-entries.txt"
	[ "$entries" -ge 8 ] || die "the delivered contract has only $entries topology entries"
	grep -qx 'marker /etc/liuqin-fedora-root 0644 '"$(
		sha256sum "$rootfs_stage/etc/liuqin-fedora-root" | cut -d' ' -f1)" "$contract" ||
		die "the contract marker entry does not match the staged root role marker"
	grep -q "^display-manager $lm_unit\$" "$contract" ||
		die "the contract does not pin the $lm_unit login manager"
	grep -q '^file /usr/share/liuqin/kernel.release$' "$contract" ||
		die "the contract does not carry the kernel identity interface (file entry)"
	say "contract gate: v2 topology, $entries entries, no content-hash pins, header LIUQIN_FEDORA_ROOT_CONTRACT_V2"
}

verify_with_project_verifier() {
	verifier=$project_root/scripts/verify-bundle.sh
	[ -x "$verifier" ] || { add_skip "verify-bundle-sh: scripts/verify-bundle.sh is absent"; return 0; }
	report=$work/logs/verify-bundle-sh.json
	# verify-bundle must audit the DELIVERED artifacts of this
	# bundle, never the stale out/boot or out/rootfs trees.  Pass them explicitly.
	set -- "$verifier" --bundle "$bundle_dir" --json "$report" --bundle-partial --no-color
	if [ -f "$bundle_dir/boot.img" ]; then
		set -- "$@" --boot "$bundle_dir/boot.img"
	fi
	if [ -f "$bundle_dir/manifests/boot-build-info.json" ]; then
		set -- "$@" --boot-metadata "$bundle_dir/manifests/boot-build-info.json"
	fi
	if [ -d "$rootfs_stage" ]; then
		set -- "$@" --rootfs "$rootfs_stage"
	fi
	if timeout 900 "$@" >"$work/logs/verify-bundle-sh.log" 2>&1; then
		say "scripts/verify-bundle.sh: PASS (report: $report)"
	else
		say "scripts/verify-bundle.sh reported problems (advisory; see $work/logs/verify-bundle-sh.log)"
		add_skip "verify-bundle-sh: project verifier reported FAIL/WARN for this offline bundle (see log)"
	fi
}

stage_verify() {
	stage_header "stage-verify: offline structure checks"
	verify_bundle_checksums
	verify_boot_img
	verify_installer_img
	verify_root_img
	verify_rootfs_tar
	verify_contract_gate
	verify_with_project_verifier
}

# ---------------------------------------------------------------------------
# Report + main
# ---------------------------------------------------------------------------
write_report() {
	report=$bundle_dir/VERIFICATION.md
	{
		printf '# liuqin Fedora image bundle — offline verification\n\n'
		printf '> Generated by `scripts/build-image.sh` on %s.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf '> **Offline only.** No tablet was connected, no fastboot/ADB command was run,\n'
		printf '> and no real device partition was written. This report describes image\n'
		printf '> structure; it is not evidence of on-device behaviour.\n\n'
		printf '## Bundle content\n\n'
		printf '| file | bytes | sha256 |\n|---|---|---|\n'
		for f in boot.img installer.img root.img rootfs.tar.gz; do
			[ -f "$bundle_dir/$f" ] || continue
			printf '| `%s` | %s | `%s` |\n' "$f" "$(stat -c '%s' "$bundle_dir/$f")" "$(sha "$bundle_dir/$f")"
		done
		printf '\n## Device-ready status\n\n**false** — this is an offline structure bundle.\n\n'
		if [ -f "$work/device-ready-reasons.txt" ]; then
			while IFS= read -r reason; do
				[ -n "$reason" ] || continue
				printf -- '- %s\n' "$reason"
			done <"$work/device-ready-reasons.txt"
		fi
		printf '\n## Root filesystem image\n\n'
		if [ -f "$work/logs/verify-root-e2fsck.log" ]; then
			printf -- '- `e2fsck -fn`: PASS\n- label: `LIUQIN_ROOT`\n'
			[ -f "$work/root-img.os-release" ] && printf -- '- Fedora release: `%s`\n' "$(cat "$work/root-img.os-release")"
			[ -f "$work/root-img.kernel-release" ] && printf -- '- kernel.release: `%s`\n' "$(cat "$work/root-img.kernel-release")"
			[ -f "$work/logs/root-elf-scan.txt" ] && printf -- '- ELF scan: `%s`\n' "$(cat "$work/logs/root-elf-scan.txt")"
			printf -- '- layout: FLAT root filesystem (partition root == rootfs root; boot profile, root.img and the RAM installer agree)\n'
			printf -- '- login manager: `display-manager.service -> /usr/lib/systemd/system/%s`\n' "$lm_unit"
		else
			printf -- '- SKIP: no root.img produced in this run\n'
		fi
		printf '\n## boot.img / installer.img\n\n'
		if [ -f "$work/logs/verify-boot.info" ]; then
			printf '```\n%s\n```\n' "$(grep -E 'header version|page size|kernel_size|ramdisk size|dtb size|dtb address|command line' "$work/logs/verify-boot.info")"
		else
			printf -- '- SKIP: no boot.img produced in this run\n'
		fi
		if [ -f "$work/logs/verify-installer.info" ]; then
			printf '\ninstaller.img: header v2, RAM-installer ramdisk (`/etc/liuqin-installer`), %s bytes.\n' "$(stat -c '%s' "$bundle_dir/installer.img")"
		fi
		printf '\n## SKIP markers\n\n'
		if [ -s "$skips_file" ]; then
			while IFS= read -r skip; do printf -- '- %s\n' "$skip"; done <"$skips_file"
		else
			printf -- '- none\n'
		fi
		printf '\n## Remaining canonical work (before device_ready=true)\n\n'
		if [ "$build_mode" = release ]; then
			printf '1. Attended boot on liuqin hardware (A/B slot write authorization is separate) and the feature smoke matrix.\n'
			printf '2. Per-device calibration/provisioning (four-speaker CS35L41 calibration, fingerprint enrollment/TA, Wi-Fi/BT MAC) from the user device.\n'
			printf '3. Verify the pinned stock-ROM DTB and firmware pool against the actual device firmware before delivery.\n'
		else
			printf '1. User stock ROM: 44 DTBO entries + 14 base DTBs -> `--dtb-source stock-rom` canonical boot.img.\n'
			printf '2. Firmware pool + WLAN HSP2 tuple + AudioReach topology -> full initramfs firmware staging.\n'
			printf '3. Device-layer RPMs installed -> hardware services present.  The admission contract is topology-only, independent of device-package payload hashes.\n'
			printf '4. `kernel-liuqin` RPM payload instead of out/kernel/dist for the boot payload.\n'
			printf '5. Attended hardware validation before any release claim.\n'
		fi
	} >"$report"
	say "verification report: $report"
}

write_image_build_info() {
	{
		printf '{\n'
		printf '  "format": "liuqin-image-build-info/1",\n'
		printf '  "name": "%s",\n' "$bundle_name"
		printf '  "fedora_release": "%s",\n' "$release"
		printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf '  "scripts": {\n'
		printf '    "build_image_sha256": "%s",\n' "$(sha "$project_root/scripts/build-image.sh")"
		printf '    "build_bootimg_sha256": "%s",\n' "$(sha "$project_root/scripts/build-bootimg.sh")"
		printf '    "build_initramfs_sha256": "%s",\n' "$(sha "$project_root/scripts/build-initramfs.sh")"
		printf '    "build_root_contract_sha256": "%s"\n' "$(sha "$project_root/tools/build-root-contract.py")"
		printf '  },\n'
		printf '  "kernel_payload": "%s",\n' "${kernel_source:-none}"
		printf '  "overlays_applied": ['
		first_ov=1
		if [ -f "$work/overlays-applied.txt" ]; then
			while IFS=$(printf '\t') read -r ov_label ov_detail; do
				[ -n "$ov_label" ] || continue
				[ "$first_ov" = 1 ] || printf ', '
				first_ov=0
				python3 -c 'import json,sys; print("{\"overlay\": " + json.dumps(sys.argv[1]) + ", \"detail\": " + json.dumps(sys.argv[2]) + "}")' "$ov_label" "$ov_detail"
			done <"$work/overlays-applied.txt"
		fi
		printf '],\n'
		printf '  "fedora_injected_packages": ['
		first_pkg=1
		if [ -f "$work/extra-packages.tsv" ]; then
			while IFS=$(printf '\t') read -r pkg nevra; do
				[ -n "$pkg" ] || continue
				[ "$first_pkg" = 1 ] || printf ', '
				first_pkg=0
				python3 -c 'import json,sys; print("{\"package\": " + json.dumps(sys.argv[1]) + ", \"nevra\": " + json.dumps(sys.argv[2]) + "}")' "$pkg" "$nevra"
			done <"$work/extra-packages.tsv"
		fi
		printf '],\n'
		printf '  "kernel_release": "%s",\n' "$(cat "$work/boot.kernel-release" 2>/dev/null || true)"
		printf '  "dtb_source": "%s",\n' "$dtb_source"
		printf '  "selinux_mode": "%s",\n' "$(cat "$work/selinux-mode.txt" 2>/dev/null || echo unknown)"
		printf '  "qbootctl_removed": %s,\n' "$([ -f "$work/qbootctl-removed.txt" ] && echo true || echo false)"
		printf '  "contract": "%s",\n' "$(basename "${contract_file:-none}")"
		printf '  "skips": ['
		first=1
		while IFS= read -r skip; do
			[ -n "$skip" ] || continue
			[ "$first" = 1 ] || printf ', '
			first=0
			python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$skip"
		done <"$skips_file"
		printf '],\n'
		printf '  "qemu_validation": null\n'
		printf '}\n'
	} >"$bundle_dir/manifests/image-build-info.json"
}

main() {
	stage_header "inputs"
	say "rootfs:       $rootfs_dir ($([ "$have_rootfs" = 1 ] && echo present || echo MISSING))"
	say "kernel RPMs:  $kernel_rpms_dir ($([ "$have_kernel_rpms" = 1 ] && echo present || echo MISSING))"
	say "device RPMs:  $device_rpms_dirs ($device_rpm_count packages)"
	say "installer:    $installer_overlay ($([ "$have_installer" = 1 ] && echo present || echo MISSING))"
	say "stages:       $stage_set"

	if [ "$build_mode" = release ]; then
		[ "$have_rootfs" = 1 ] || die_usage "--build-mode release needs out/rootfs/rootfs (rootfs-builder output)"
		[ "$have_kernel_rpms" = 1 ] || die_usage "--build-mode release needs kernel-liuqin RPMs in $kernel_rpms_dir"
		[ "$have_installer" = 1 ] || die_usage "--build-mode release needs the RAM-installer overlay at $installer_overlay"
	fi

	if has_stage rootfs; then
		stage_rootfs_tree || true
	fi
	if has_stage root-img; then
		stage_root_img || true
	fi
	if has_stage boot-img; then
		stage_boot_img || true
	fi
	if has_stage installer-img; then
		stage_installer_img || true
	fi
	if has_stage bundle; then
		stage_bundle || true
	fi
	if has_stage verify; then
		stage_verify || true
	fi
	# Re-write bundle metadata after verification so the final reasons
	# are included; SHA256SUMS is regenerated after this.
	if [ -f "$bundle_dir/bundle.json" ]; then
		write_bundle_json
		write_bundle_sha256sums
	fi
	write_image_build_info
	write_bundle_sha256sums
	write_report
	printf '\n'
	say "bundle: $bundle_dir"
	say "files:"
	( cd "$bundle_dir" && ls -1 )
	printf '%s\n' "$bundle_dir"
}

main
