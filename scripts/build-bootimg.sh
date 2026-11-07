#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Assemble the Fedora liuqin boot.img (Android boot image v2) offline.
#
# This wraps the same assembly the upstream project performs, with the
# distribution/artifact substitutions this project needs:
#
#   kernel  : aarch64 Image from --kernel-out (real kernel build).  Until the
#             kernel build exists, the published v0.6.0 boot.img's kernel may be
#             used as a clearly-recorded structure-validation fallback.
#   ramdisk : Fedora-fied stage-1 initramfs from scripts/build-initramfs.sh.
#   dtb     : two paths (see --dtb-source):
#               stock-rom        canonical: raw board DTB + /chosen cmdline
#                                overlay + upstream ABL overlay-sink injection,
#                                delegated to the *upstream* build-bootimg.sh.
#                                Requires the user's stock ROM analysis tree
#                                (44 DTBO entries + 14 vendor_boot base DTBs) and
#                                the kernel build's dtc/fdtoverlay.
#               upstream-artifact offline substitute: reuse the final DTB from the
#                                published v0.6.0 boot.img (boot.img sha256
#                                7a368e58…, dtb sha256 885faaab…), after
#                                re-verifying its board identity, /chosen
#                                bootargs, __symbols__ sink and framebuffer
#                                properties.  Structurally valid; see the risk
#                                note in docs/maintenance/boot-initramfs.md §5.
#               auto             stock-rom when --stock-rom-dir is usable,
#                                otherwise upstream-artifact.
#
# Header cmdline stays EMPTY on purpose (ABL reads the cmdline from the DTB
# /chosen node and appends its own ~800 characters), matching upstream.
#
# This script never writes a device, never calls fastboot and never needs the
# tablet.  Output: out/boot/boot-liuqin-dev.img + SHA256SUMS + build-info.json
# + VERIFICATION.md.
#
# Usage:
#   scripts/build-bootimg.sh \
#       --kernel-out out/kernel \
#       --ramdisk out/boot/initramfs/liuqin-firstboot.cpio.gz \
#       --out out/boot
#
# Exit codes: 0 success; 1 build/verify failure; 2 usage or environment error.

set -eu
umask 022

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
upstream=$project_root/upstream/xiaomipad-6pro-mainline
initramfs_dir=$project_root/out/boot/initramfs

MKBOOTIMG_SHA256=37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c
UNPACK_BOOTIMG_SHA256=06b54dd9a07c5281778e29e234e76f6e3faee8bf0c904a5ef88fdee30eeed12e

# Published v0.6.0 artifacts (cache/upstream-v0.6.0/).  The offline DTB
# substitute is only accepted from these exact bytes.
RELEASE_BOOTIMG_SHA256=7a368e58291f974f1cebd1e91e81ce8edc7256a19f75c4baea3fffd883157900
RELEASE_DTB_SHA256=885faaab7dad9de85a2f4fd89307ed57459e4893d8d83477cfdc918950aa8619
RELEASE_KERNEL_GZ_SHA256=2eac03a8d9bc607db8e761f62c0fcc11a2a9ef9de8b171ad12f4bad2fbd90d55
RELEASE_KERNEL_IMAGE_SHA256=d5a22bc04cff813012b5618a4c7c888b561ab8c530bc39f036006c7d73d18b44
RELEASE_KERNEL_IMAGE_BYTES=56826368

# liuqin boot partition: 96 * 4096 * 128 = 49152 sectors = 201326592 bytes.
PARTITION_BYTES=201326592
# Upstream mkbootimg parameters for this device.
PAGESIZE=4096
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0x01000000
TAGS_OFFSET=0x00000100
DTB_OFFSET=0x01f00000

kernel_out=$project_root/out/kernel
ramdisk=$initramfs_dir/liuqin-firstboot.cpio.gz
out_root=$project_root/out/boot
dtb_source=auto
# free-form provenance label recorded in build-info (set by --kernel-provenance)
kernel_provenance=
stock_rom_dir=
release_bootimg=$project_root/cache/upstream-v0.6.0/boot.img
mkbootimg_dir=$project_root/cache/upstream-v0.6.0/mkbootimg
project_cmdline=$project_root/overlays/boot/liuqin-bootargs.txt
if [ -f "$project_cmdline" ]; then
	cmdline_file=$project_cmdline
else
	cmdline_file=$upstream/device/native-bootargs.txt
fi
header_cmdline=
ramdisk_mode=auto
allow_release_kernel_fallback=1
# The 7.3 normal-slot display handoff requires ABL to see linux_splash, not
# splash_region.  The stock-ROM DTB input still names it splash_region, so the
# final DTB is patched in place (same-size string-table edit) unless explicitly
# disabled for a diagnostic build.
linux_splash=1

usage() {
	cat <<'EOF'
usage: scripts/build-bootimg.sh [options]

  --kernel-out DIR       kernel build output (default: <project>/out/kernel);
                         expects arch/arm64/boot/Image and, for the canonical
                         DTB path, scripts/dtc/{dtc,fdtoverlay} and
                         arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb
  --ramdisk FILE         stage-1 initramfs cpio.gz
                         (default: out/boot/initramfs/liuqin-firstboot.cpio.gz)
  --ramdisk-mode MODE    persistent | installer | auto (default: auto; the
                         installer ramdisk carries /etc/liuqin-installer and is
                         verified against the RAM-installer contract instead of
                         the persistent root contract)
  --out DIR              output directory (default: <project>/out/boot)
  --dtb-source MODE      auto | stock-rom | upstream-artifact (default: auto)
  --stock-rom-dir DIR    stock ROM analysis tree: dir/dtbo/entry.NN (44 files)
                         and dir/vendor_boot/dtbs/dtb-NN.dtb (14 files);
                         also accepts the upstream .../analysis/{dtbo,vendor_boot}
                         layout
  --release-bootimg FILE published v0.6.0 boot.img used by the
                         upstream-artifact DTB path
                         (default: cache/upstream-v0.6.0/boot.img)
  --mkbootimg-dir DIR    AOSP mkbootimg checkout
                         (default: cache/upstream-v0.6.0/mkbootimg)
  --cmdline-file FILE    DT /chosen bootargs source
                         (default: overlays/boot/liuqin-bootargs.txt, the
                         verified A-slot cmdline with console=tty0 and
                         gnome.is_vm=0)
  --header-cmdline STR   boot image header cmdline (default: empty, as upstream)
  --no-linux-splash      keep the stock reserved-memory name splash_region
                         (diagnostic only; normal liuqin 7.3 boots need
                         linux_splash so ABL disables the live display)
  --strict-kernel        fail instead of falling back to the published kernel
  -h, --help             show this help

No device is touched. Outputs: boot-liuqin-dev.img, SHA256SUMS,
build-info.json, VERIFICATION.md under --out.

MACHINE INTERFACE (for the future Fedora kernel-install hook / liuqin-bootimg):
  inputs      --kernel-out DIR (must contain arch/arm64/boot/Image and the board
              DTB + scripts/dtc for the canonical DTB path), --ramdisk FILE,
              --out DIR, --dtb-source, --stock-rom-dir, --release-bootimg,
              --mkbootimg-dir, --cmdline-file, --header-cmdline
  success     exit 0, and <--out>/boot-liuqin-dev.img + build-info.json exist;
              stdout's last line is the absolute image path; build-info.json
              records kernel/ramdisk/DTB hashes, header fields and device_ready
  failure     1 = build/verify failure (do not stage the image);
              2 = usage, missing-input or environment error
  determinism same inputs (kernel Image, ramdisk, DTB, header cmdline) produce
              byte-identical images; no timestamps enter the boot image itself
  side effect only files below <--out> are written; upstream/ stays untouched
  strictness --strict-kernel forbids the published-kernel fallback; a production
              hook must pass it so a missing kernel build never ships
EOF
}

die() { printf 'build-bootimg: %s\n' "$*" >&2; exit 1; }
die_usage() { printf 'build-bootimg: %s\n' "$*" >&2; exit 2; }
say() { printf 'build-bootimg: %s\n' "$*" >&2; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

while [ $# -gt 0 ]; do
	case $1 in
	--kernel-out)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--kernel-out needs a value"
		kernel_out=$2
		shift
		;;
	--ramdisk)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--ramdisk needs a value"
		ramdisk=$2
		shift
		;;
	--out)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--out needs a value"
		out_root=$2
		shift
		;;
	--dtb-source)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--dtb-source needs a value"
		dtb_source=$2
		shift
		;;
	--kernel-provenance)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--kernel-provenance needs a value"
		kernel_provenance=$2
		shift
		;;
	--stock-rom-dir)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--stock-rom-dir needs a value"
		stock_rom_dir=$2
		shift
		;;
	--release-bootimg)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--release-bootimg needs a value"
		release_bootimg=$2
		shift
		;;
	--mkbootimg-dir)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--mkbootimg-dir needs a value"
		mkbootimg_dir=$2
		shift
		;;
	--cmdline-file)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--cmdline-file needs a value"
		cmdline_file=$2
		shift
		;;
	--header-cmdline)
		[ $# -ge 2 ] || die_usage "--header-cmdline needs a value (use '' for empty)"
		header_cmdline=$2
		shift
		;;
	--ramdisk-mode)
		[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--ramdisk-mode needs a value"
		ramdisk_mode=$2
		shift
		;;
	--no-linux-splash) linux_splash=0 ;;
	--strict-kernel) allow_release_kernel_fallback=0 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die_usage "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

case $dtb_source in auto|stock-rom|upstream-artifact) ;; *) die_usage "--dtb-source must be auto, stock-rom or upstream-artifact" ;; esac
case $ramdisk_mode in auto|persistent|installer) ;; *) die_usage "--ramdisk-mode must be auto, persistent or installer" ;; esac
[ -d "$upstream" ] || die_usage "upstream read-only clone is missing: $upstream (run scripts/fetch-upstream.sh)"
[ -f "$ramdisk" ] || die_usage "ramdisk is missing: $ramdisk (run scripts/build-initramfs.sh first)"
[ -f "$cmdline_file" ] || die_usage "cmdline file is missing: $cmdline_file"
[ -d "$mkbootimg_dir" ] || die_usage "AOSP mkbootimg checkout is missing: $mkbootimg_dir"
for tool in python3 gzip sha256sum cmp dtc fdtget; do
	command -v "$tool" >/dev/null 2>&1 || die_usage "missing host tool: $tool"
done
command -v cpio >/dev/null 2>&1 || die_usage "host cpio is required"
[ -f "$mkbootimg_dir/mkbootimg.py" ] && [ -f "$mkbootimg_dir/unpack_bootimg.py" ] ||
	die_usage "mkbootimg checkout is incomplete: $mkbootimg_dir"
[ "$(sha "$mkbootimg_dir/mkbootimg.py")" = "$MKBOOTIMG_SHA256" ] ||
	die "mkbootimg.py identity mismatch (expected commit 954bc3ead5e6…, sha256 $MKBOOTIMG_SHA256)"
[ "$(sha "$mkbootimg_dir/unpack_bootimg.py")" = "$UNPACK_BOOTIMG_SHA256" ] ||
	die "unpack_bootimg.py identity mismatch (sha256 $UNPACK_BOOTIMG_SHA256)"

cmdline=$(cat "$cmdline_file")
[ -n "$cmdline" ] || die_usage "cmdline file is empty: $cmdline_file"
# TN0085: gsd-power treats this board as a VM unless gnome.is_vm=0 is present
# (Gunyah DT node, no DMI), so automatic suspend is ignored.  The verified
# A-slot cmdline also uses console=tty0; drm_log is not part of the daily boot
# profile and was removed after the display handoff review.
case " $cmdline " in
*" gnome.is_vm=0 "*) ;;
*) die_usage "cmdline must carry gnome.is_vm=0 (TN0085); got: $cmdline" ;;
esac
case " $cmdline " in
*" console=drm_log "*) say "warning: console=drm_log is present; the verified A-slot boot uses console=tty0" ;;
esac
case $header_cmdline in
"$cmdline") say "note: header cmdline equals DT cmdline; upstream product images keep the header empty" ;;
esac

mkdir -p "$out_root"
out_root=$(CDPATH= cd -- "$out_root" && pwd)
# All scratch work stays below out/, never in upstream/.
work=$(mktemp -d "$out_root/.bootimg.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# 1. Kernel: real build output, or the published Image as a recorded fallback
# ---------------------------------------------------------------------------
# Accept the two layouts this project produces:
#   <kernel-out>/arch/arm64/boot/{Image,dts/qcom/sm8475-xiaomi-liuqin.dtb}  (raw build dir)
#   <kernel-out>/dist/{Image,sm8475-xiaomi-liuqin.dtb}                      (kernel-builder delivery)
# and, for the canonical DTB path, dtc/fdtoverlay either from the kernel build
# or from the host's dtc package.
first_existing() { for candidate in "$@"; do [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }; done; return 1; }
image=$(first_existing \
	"$kernel_out/arch/arm64/boot/Image" \
	"$kernel_out/dist/Image" \
	"$kernel_out/build/arch/arm64/boot/Image") || image=$kernel_out/arch/arm64/boot/Image
raw_dtb=$(first_existing \
	"$kernel_out/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb" \
	"$kernel_out/dist/sm8475-xiaomi-liuqin.dtb" \
	"$kernel_out/build/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb") ||
	raw_dtb=$kernel_out/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb
kernel_dtc=$(first_existing \
	"$kernel_out/scripts/dtc/dtc" \
	"$kernel_out/build/scripts/dtc/dtc" \
	"$(command -v dtc 2>/dev/null || true)") || kernel_dtc=$kernel_out/scripts/dtc/dtc
kernel_fdtoverlay=$(first_existing \
	"$kernel_out/scripts/dtc/fdtoverlay" \
	"$kernel_out/build/scripts/dtc/fdtoverlay" \
	"$(command -v fdtoverlay 2>/dev/null || true)") || kernel_fdtoverlay=$kernel_out/scripts/dtc/fdtoverlay
kernel_source=kernel-build
# Free-form provenance label for build-info (e.g. "kernel-liuqin RPM (...)");
kernel_release_expected=
for release_file in "$kernel_out/include/config/kernel.release" \
	"$kernel_out/build/include/config/kernel.release" "$kernel_out/dist/kernel.release"; do
	if [ -r "$release_file" ]; then
		kernel_release_expected=$(cat "$release_file")
		break
	fi
done

kernel_config=
if [ -f "$image" ]; then
	kernel_config=$(first_existing "$kernel_out/.config" "$kernel_out/dist/config" \
		"$kernel_out/build/.config") || kernel_config=
	[ -n "$kernel_config" ] || say "warning: kernel .config is missing; kernel provenance is partial"
	say "kernel: using kernel build output $image"
else
	[ "$allow_release_kernel_fallback" = 1 ] ||
		die_usage "kernel Image is missing and --strict-kernel was requested: $image"
	[ -f "$release_bootimg" ] ||
		die_usage "kernel Image is missing and the release boot.img fallback is unavailable: $image"
	[ "$(sha "$release_bootimg")" = "$RELEASE_BOOTIMG_SHA256" ] ||
		die "fallback release boot.img sha256 mismatch: $(sha "$release_bootimg")"
	python3 "$mkbootimg_dir/unpack_bootimg.py" --boot_img "$release_bootimg" \
		--out "$work/release-unpacked" --format info >"$work/release.info" ||
		die "could not unpack the fallback release boot.img"
	[ "$(sha "$work/release-unpacked/kernel")" = "$RELEASE_KERNEL_GZ_SHA256" ] ||
		die "fallback kernel gzip sha256 mismatch: $work/release-unpacked/kernel"
	gzip -dc "$work/release-unpacked/kernel" >"$work/Image.fallback"
	[ "$(stat -c '%s' "$work/Image.fallback")" = "$RELEASE_KERNEL_IMAGE_BYTES" ] ||
		die "fallback kernel size mismatch: $(stat -c '%s' "$work/Image.fallback")"
	[ "$(sha "$work/Image.fallback")" = "$RELEASE_KERNEL_IMAGE_SHA256" ] ||
		die "fallback kernel Image sha256 mismatch"
	image=$work/Image.fallback
	kernel_source=upstream-release-fallback
	kernel_release_expected=$(
		python3 - "$project_root/cache/upstream-v0.6.0/bundle.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("kernel_release", ""))
except Exception:
    print("")
PY
	)
	say "WARNING: kernel build output is not ready; using the PUBLISHED v0.6.0 kernel Image"
	say "         for structure validation only (kernel_source=upstream-release-fallback)"
fi
[ -f "$image" ] || die "kernel Image is unavailable: $image"
kernel_image_sha=$(sha "$image")
kernel_image_bytes=$(stat -c '%s' "$image")
# Metadata only: the release string embedded in the Image if no
# include/config/kernel.release is shipped by the kernel build layout.
if [ -z "$kernel_release_expected" ] && command -v strings >/dev/null 2>&1; then
	kernel_release_expected=$(LC_ALL=C strings "$image" 2>/dev/null |
		grep -m1 '^Linux version ' | sed -E 's/^Linux version ([^ ]+).*/\1/' || true)
fi
# ARM64 Image header magic 0x644d5241 ("ARMd", little endian) at offset 56.
if [ "$(dd if="$image" bs=1 skip=56 count=4 2>/dev/null | /usr/bin/od -An -tx1 | tr -d ' \n')" != '41524d64' ]; then
	die "kernel Image does not carry the ARM64 Image magic at offset 56: $image"
fi

# ---------------------------------------------------------------------------
# 2. DTB: choose the path
# ---------------------------------------------------------------------------
find_stock_dirs() {
	# Sets stock_overlay_dir / stock_base_dir when a usable stock ROM tree is
	# given; returns 1 otherwise.
	stock_overlay_dir=
	stock_base_dir=
	[ -n "$stock_rom_dir" ] || return 1
	for candidate in "$stock_rom_dir/analysis/dtbo" "$stock_rom_dir/dtbo"; do
		if [ -d "$candidate" ]; then stock_overlay_dir=$candidate; break; fi
	done
	for candidate in "$stock_rom_dir/analysis/vendor_boot/dtbs" "$stock_rom_dir/vendor_boot/dtbs"; do
		if [ -d "$candidate" ]; then stock_base_dir=$candidate; break; fi
	done
	[ -n "$stock_overlay_dir" ] && [ -n "$stock_base_dir" ] || return 1
	overlay_count=$(find "$stock_overlay_dir" -maxdepth 1 -type f -regex '.*/entry\.[0-9]+' | wc -l)
	base_count=$(find "$stock_base_dir" -maxdepth 1 -type f -regex '.*/dtb-[0-9][0-9]\.dtb' | wc -l)
	[ "$overlay_count" -eq 44 ] || die "stock overlay dir has $overlay_count entries, expected 44: $stock_overlay_dir"
	[ "$base_count" -eq 14 ] || die "stock base DTB dir has $base_count files, expected 14: $stock_base_dir"
	return 0
}

stock_paths_ok=0
if find_stock_dirs; then
	stock_paths_ok=1
fi

case $dtb_source in
auto)
	if [ "$stock_paths_ok" = 1 ] && [ -f "$raw_dtb" ] && [ -x "$kernel_dtc" ] && [ -x "$kernel_fdtoverlay" ]; then
		dtb_source=stock-rom
	else
		dtb_source=upstream-artifact
		[ -z "$stock_rom_dir" ] || say "warning: stock ROM tree or kernel dtc/fdtoverlay is not usable; falling back to upstream-artifact DTB"
	fi
	;;
stock-rom)
	[ "$stock_paths_ok" = 1 ] ||
		die_usage "--dtb-source stock-rom needs a usable --stock-rom-dir (44 entries + 14 base DTBs)"
	;;
upstream-artifact) ;;
esac
say "dtb: source=$dtb_source"

canonical_used=0
canonical_compat_patch_sha=
final_dtb=$work/final.dtb
dtb_provenance=

if [ "$dtb_source" = stock-rom ]; then
	[ -f "$raw_dtb" ] || die_usage "canonical DTB path needs the kernel build's board DTB: $raw_dtb"
	[ -x "$kernel_dtc" ] || die_usage "canonical DTB path needs dtc (kernel build or host): $kernel_dtc"
	[ -x "$kernel_fdtoverlay" ] || die_usage "canonical DTB path needs fdtoverlay (kernel build or host): $kernel_fdtoverlay"
	[ -f "$upstream/tools/lib/build-bootimg.sh" ] || die_usage "upstream build-bootimg.sh is missing"
	canonical_used=1

	# /chosen bootargs go into the DTB through an overlay, exactly as upstream
	# tools/build-liuqin-native-boot.sh does it; the header stays empty.
	python3 - "$cmdline" "$work/cmdline-overlay.dts" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[2]).write_text('/dts-v1/;\n/plugin/;\n/ { fragment@0 { target-path = "/chosen"; '
                             '__overlay__ { bootargs = ' + json.dumps(sys.argv[1]) + '; }; }; };\n')
PY
	"$kernel_dtc" -@ -q -I dts -O dtb -o "$work/cmdline-overlay.dtbo" "$work/cmdline-overlay.dts" ||
		die "could not compile the cmdline overlay"
	"$kernel_fdtoverlay" -i "$raw_dtb" -o "$work/input.dtb" "$work/cmdline-overlay.dtbo" ||
		die "could not apply the cmdline overlay to $raw_dtb"

	canonical_out=$work/canonical
	mkdir -p "$canonical_out"
	# Newer dtc restores labels from __symbols__ when decompiling with -@.
	# The pinned upstream parser otherwise mistakes the labeled sink for a
	# missing node. Patch a minimal scratch copy, never the read-only clone.
	command -v patch >/dev/null 2>&1 || die_usage "canonical DTB path needs host patch"
	canonical_tools=$work/upstream-compat
	mkdir -p "$canonical_tools/tools/lib" "$canonical_tools/device"
	for helper in build-bootimg.sh abl-symbols.py abl-dtb-ids.py; do
		cp "$upstream/tools/lib/$helper" "$canonical_tools/tools/lib/$helper"
	done
	cp "$upstream/device/liuqin-abl-boot-overlay.dts" "$canonical_tools/device/"
	canonical_compat_patch=$project_root/overlays/boot/abl-symbols-dtc-labels.patch
	patch --batch --fuzz=0 -p1 -d "$canonical_tools" <"$canonical_compat_patch" ||
		die "canonical DTB tool compatibility patch failed"
	canonical_compat_patch_sha=$(sha "$canonical_compat_patch")
	say "dtb: rebuilding the ABL-ready DTB with the upstream build-bootimg.sh (44+14 stock inputs)"
	KERNEL_OUT="$kernel_out" IMAGE="$image" DTB="$work/input.dtb" \
		RAMDISK="$ramdisk" DTC="$kernel_dtc" FDTOVERLAY="$kernel_fdtoverlay" \
		MKBOOTIMG_DIR="$mkbootimg_dir" \
		STOCK_OVERLAY_DIR="$stock_overlay_dir" STOCK_BASE_DIR="$stock_base_dir" \
		ABL_OVERLAY_SINK=1 ABL_DTB02_IDS=0 \
		CMDLINE="$cmdline" HEADER_CMDLINE="$header_cmdline" OUT_DIR="$canonical_out" \
		sh "$canonical_tools/tools/lib/build-bootimg.sh" ||
		die "upstream build-bootimg.sh failed"
	[ -f "$canonical_out/sm8475-xiaomi-liuqin-abl.dtb" ] ||
		die "upstream build-bootimg.sh did not produce the ABL-ready DTB"
	final_dtb=$work/final.dtb
	cp -f "$canonical_out/sm8475-xiaomi-liuqin-abl.dtb" "$final_dtb"
	dtb_provenance="canonical stock-rom rebuild (raw board DTB + /chosen cmdline overlay + upstream ABL overlay-sink injection from 44 DTBO entries and 14 base DTBs)"
else
	# Offline substitute: reuse the published boot.img's final, already
	# ABL-validated DTB.
	[ -f "$release_bootimg" ] || die "upstream-artifact DTB path needs --release-bootimg: $release_bootimg"
	release_sha=$(sha "$release_bootimg")
	[ "$release_sha" = "$RELEASE_BOOTIMG_SHA256" ] ||
		die "release boot.img sha256 mismatch: $release_sha != $RELEASE_BOOTIMG_SHA256"
	python3 "$mkbootimg_dir/unpack_bootimg.py" --boot_img "$release_bootimg" \
		--out "$work/release-dtb" --format info >"$work/release-dtb.info" ||
		die "could not unpack the release boot.img for its DTB"
	[ -f "$work/release-dtb/dtb" ] || die "release boot.img carries no DTB"
	[ "$(sha "$work/release-dtb/dtb")" = "$RELEASE_DTB_SHA256" ] ||
		die "release boot.img DTB sha256 mismatch: $(sha "$work/release-dtb/dtb")"
	cp -f "$work/release-dtb/dtb" "$final_dtb"
	dtb_provenance="upstream release v0.6.0 boot.img (sha256 $RELEASE_BOOTIMG_SHA256) final DTB (sha256 $RELEASE_DTB_SHA256)"
fi
[ -f "$final_dtb" ] || die "final DTB was not produced: $final_dtb"
if [ "$linux_splash" = 1 ]; then
	# ABL's UpdateSplashMemInfo() looks at the reserved-memory node name.  With
	# splash_region it keeps the live display and the 7.3 panel handoff is black
	# on a normal slot boot; with linux_splash it calls DisableDisplay() and the
	# kernel cold-initializes the panel.  The stock-ROM DTB still uses the old
	# name, so replace the exact null-terminated string-table entry in place.
	# The replacement is the same byte length
	# (splash_region@b8000000 + NUL -> linux_splash@b8000000 + NUL + NUL), so
	# every structure-block string offset stays valid and no phandle changes.
	python3 - "$final_dtb" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'rb') as stream:
    data = bytearray(stream.read())
old = b'splash_region@b8000000\x00'
new = b'linux_splash@b8000000\x00\x00'
renamed = data.count(old)
if renamed:
    data = data.replace(old, new)
    with open(path, 'wb') as stream:
        stream.write(data)
elif data.count(b'linux_splash@b8000000\x00') == 0:
    raise SystemExit('final DTB contains neither splash_region@b8000000 nor linux_splash@b8000000')
print(f'linux_splash: renamed {renamed} reserved-memory string(s)', file=sys.stderr)
PY
	dtb_provenance="$dtb_provenance + linux_splash reserved-memory rename"
else
	say "warning: --no-linux-splash: ABL may keep the live display and the 7.3 normal-slot boot can be black"
fi
dtb_provenance="$dtb_provenance; cmdline source: $cmdline_file"
# A valid boot header is insufficient: an upstream-artifact substitute can
# silently drop a board DTS fix. Canonical assembly preserves raw phandles;
# compare both the path cells and their names before accepting either mode.
raw_mdss_interconnects_match=unknown
if [ -f "$raw_dtb" ]; then
	mdss_node=/soc@0/display-subsystem@ae00000
	for property in interconnects interconnect-names; do
		property_type=x
		[ "$property" != interconnect-names ] || property_type=s
		raw_value=$(fdtget -t "$property_type" "$raw_dtb" "$mdss_node" "$property") ||
			die "raw DTB lacks MDSS $property"
		final_value=$(fdtget -t "$property_type" "$final_dtb" "$mdss_node" "$property") ||
			die "final DTB lacks MDSS $property"
		[ "$raw_value" = "$final_value" ] ||
			die "final DTB drops the kernel board MDSS $property; use --dtb-source stock-rom with matching ROM inputs"
	done
	raw_mdss_interconnects_match=true
fi
final_dtb_sha=$(sha "$final_dtb")
final_dtb_bytes=$(stat -c '%s' "$final_dtb")
say "dtb: $final_dtb ($final_dtb_bytes bytes, sha256 $final_dtb_sha)"

# ---------------------------------------------------------------------------
# 3. DTB identity / cmdline / framebuffer assertions (mirror upstream checks)
# ---------------------------------------------------------------------------
dtc_bin=dtc
[ -x "$kernel_dtc" ] && dtc_bin=$kernel_dtc
"$dtc_bin" -I dtb -O dts -o "$work/final.dts" "$final_dtb" 2>/dev/null ||
	die "final DTB does not decompile with dtc: $final_dtb"

if [ "$linux_splash" = 1 ]; then
	grep -q 'linux_splash@b8000000' "$work/final.dts" ||
		die "final DTB has no linux_splash@b8000000 reserved-memory node"
	if grep -q 'splash_region@b8000000' "$work/final.dts"; then
		die "final DTB still carries splash_region@b8000000; ABL would keep the live display"
	fi
fi

if [ "$dtb_source" = stock-rom ]; then
	grep -q 'qcom,msm-id = <0x213 0x10000 0x21c 0x10000 0x212 0x10000>;' "$work/final.dts" ||
		die "final DTB lost the liuqin qcom,msm-id identity"
	grep -q 'qcom,board-id = <0x10008 0x00>;' "$work/final.dts" ||
		die "final DTB lost the liuqin qcom,board-id identity"
	grep -q 'xiaomi,miboard-id = <0x10 0x00>;' "$work/final.dts" ||
		die "final DTB lost the liuqin xiaomi,miboard-id identity"
else
	# Assert the published DTB still carries what the ABL selection path reads,
	# and that whoever rebuilt that artifact kept the symbol sink.
	grep -q 'qcom,msm-id = <0x213 0x10000 0x21c 0x10000 0x212 0x10000>;' "$work/final.dts" ||
		die "upstream-artifact DTB lacks the liuqin qcom,msm-id identity"
	grep -q 'qcom,board-id = <0x10008 0x00>;' "$work/final.dts" ||
		die "upstream-artifact DTB lacks the liuqin qcom,board-id identity"
	grep -q 'xiaomi,miboard-id = <0x10 0x00>;' "$work/final.dts" ||
		die "upstream-artifact DTB lacks the liuqin xiaomi,miboard-id identity"
	grep -q 'liuqin-abl-overlay-sink' "$work/final.dts" ||
		die "upstream-artifact DTB lacks the ABL overlay sink node"
	awk '/^[[:space:]]*__symbols__ \{/ { inside = 1; next } inside && /^[[:space:]]*\};/ { inside = 0 } inside && /=/ { symbols++ } END { exit (symbols > 0) ? 0 : 1 }' "$work/final.dts" ||
		die "upstream-artifact DTB has no __symbols__ entries (ABL would refuse it)"
fi
if ! grep -qF "bootargs = \"$cmdline\";" "$work/final.dts"; then
	die "/chosen/bootargs in the final DTB does not match $cmdline_file"
fi
for required in \
	'compatible = "simple-framebuffer";' \
	'reg = <0x00 0xb8000000 0x00 0x2b00000>;' \
	'width = <0x708>;' \
	'height = <0xb40>;' \
	'stride = <0x1c20>;' \
	'format = "a8r8g8b8";'; do
	grep -qF "$required" "$work/final.dts" ||
		die "final DTB lost the earlycon framebuffer property: $required"
done
awk '/^\tchosen \{/,/^\t\};/' "$work/final.dts" | grep -qF '#address-cells = <0x02>;' ||
	die "final DTB /chosen lost #address-cells"
awk '/^\tchosen \{/,/^\t\};/' "$work/final.dts" | grep -qF '#size-cells = <0x02>;' ||
	die "final DTB /chosen lost #size-cells"
awk '/^\tchosen \{/,/^\t\};/' "$work/final.dts" | grep -qF 'ranges;' ||
	die "final DTB /chosen lost ranges"

# Cross-check the kernel build's raw board DTB against the DTB we boot with.
# The raw DTB is not bootable by itself: the ABL selection metadata and the
# 1781-entry __symbols__ union are injected by the upstream boot chain (identity
# overlay + 44 DTBO entries + 14 base DTBs).  What we can prove offline is that
# the *base* DTB is consistent: same /chosen bootargs, same model/framebuffer,
# and the upstream identity overlay applied to it reproduces the exact
# qcom,msm-id / qcom,board-id / xiaomi,miboard-id the release DTB carries.
raw_dtb_comparison=
if [ -f "$raw_dtb" ]; then
	raw_dtb_comparison="raw kernel DTB present (sha256 $(sha "$raw_dtb"), $(stat -c '%s' "$raw_dtb") bytes)"
	if "$dtc_bin" -I dtb -O dts -o "$work/raw.dts" "$raw_dtb" 2>/dev/null; then
		raw_symbols=no
		grep -q '__symbols__' "$work/raw.dts" && raw_symbols=yes
		raw_msm=no
		grep -q 'qcom,msm-id' "$work/raw.dts" && raw_msm=yes
		raw_bootargs=$("$dtc_bin" -I dtb -O dts "$raw_dtb" 2>/dev/null |
			grep -m1 'bootargs = ' | sed -E 's/^[[:space:]]*bootargs = "(.*)";[[:space:]]*$/\1/' || true)
		raw_bootargs_match=no
		[ "$raw_bootargs" = "$cmdline" ] && raw_bootargs_match=yes
		raw_identity_check=skipped
		if [ -x "$kernel_dtc" ] && [ -x "$kernel_fdtoverlay" ] &&
			[ -f "$upstream/device/liuqin-abl-boot-overlay.dts" ]; then
			if "$kernel_dtc" -@ -q -I dts -O dtb -o "$work/raw-identity.dtbo" \
					"$upstream/device/liuqin-abl-boot-overlay.dts" &&
				"$kernel_fdtoverlay" -i "$raw_dtb" -o "$work/raw-identity.dtb" \
					"$work/raw-identity.dtbo" &&
				"$dtc_bin" -I dtb -O dts -o "$work/raw-identity.dts" "$work/raw-identity.dtb" 2>/dev/null &&
				grep -q 'qcom,msm-id = <0x213 0x10000 0x21c 0x10000 0x212 0x10000>;' "$work/raw-identity.dts" &&
				grep -q 'qcom,board-id = <0x10008 0x00>;' "$work/raw-identity.dts" &&
				grep -q 'xiaomi,miboard-id = <0x10 0x00>;' "$work/raw-identity.dts"; then
				raw_identity_check=pass
			else
				raw_identity_check=FAIL
			fi
		fi
		raw_dtb_comparison="$raw_dtb_comparison; __symbols__=$raw_symbols (upstream injects the union from 44 DTBO entries + 14 base DTBs); qcom,msm-id=$raw_msm (upstream identity overlay injects it); /chosen bootargs matches native-bootargs=$raw_bootargs_match; identity-overlay cross-check=$raw_identity_check"
		# The canonical stock-rom path replaces /chosen bootargs through an
		# overlay generated from --cmdline-file, so a project cmdline (for
		# example an extra gnome.is_vm=0 token) may legitimately differ from the
		# raw kernel DTB. Only the published-DTB substitute must match it.
		if [ "$raw_bootargs_match" != yes ] && [ "$canonical_used" != 1 ]; then
			die "raw kernel DTB /chosen bootargs differ from $cmdline_file; the DTB substitute would not match the kernel tree"
		fi
		if [ "$raw_identity_check" = FAIL ]; then
			die "raw kernel DTB + upstream identity overlay does not reproduce the release ABL selection metadata; kernel DT tree has diverged from the published baseline"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 4. Assembly
# ---------------------------------------------------------------------------
image_gz=$work/Image.gz
gzip -n -9 -c "$image" >"$image_gz"
image_gz_sha=$(sha "$image_gz")
image_gz_bytes=$(stat -c '%s' "$image_gz")
ramdisk_sha=$(sha "$ramdisk")
ramdisk_bytes=$(stat -c '%s' "$ramdisk")
final_bootimg=$out_root/boot-liuqin-dev.img

# Always assemble the delivered image from the verified payloads.  The
# canonical path uses the upstream builder only to construct the ABL-ready
# DTB; we patch that DTB for the linux_splash handoff, so copying the upstream
# builder's pre-patch boot image would silently ship the old node name.
python3 "$mkbootimg_dir/mkbootimg.py" \
	--header_version 2 \
	--pagesize "$PAGESIZE" \
	--base 0 \
	--kernel_offset "$KERNEL_OFFSET" \
	--ramdisk_offset "$RAMDISK_OFFSET" \
	--tags_offset "$TAGS_OFFSET" \
	--dtb_offset "$DTB_OFFSET" \
	--kernel "$image_gz" \
	--ramdisk "$ramdisk" \
	--dtb "$final_dtb" \
	--cmdline "$header_cmdline" \
	--output "$final_bootimg.partial" ||
	die "mkbootimg.py failed"
bootimg_bytes=$(stat -c '%s' "$final_bootimg.partial")
[ "$bootimg_bytes" -le "$PARTITION_BYTES" ] ||
	die "boot image is $bootimg_bytes bytes, larger than the 192 MiB liuqin boot partition ($PARTITION_BYTES)"
mv -f "$final_bootimg.partial" "$final_bootimg"
bootimg_sha=$(sha "$final_bootimg")
say "boot image: $final_bootimg ($bootimg_bytes bytes, sha256 $bootimg_sha)"

# ---------------------------------------------------------------------------
# 5. Independent unpack + verification
# ---------------------------------------------------------------------------
python3 "$mkbootimg_dir/unpack_bootimg.py" --boot_img "$final_bootimg" \
	--out "$work/final-unpacked" --format info >"$work/final.info" ||
	die "final boot image could not be unpacked"
grep -qx 'boot image header version: 2' "$work/final.info" || die "final image is not boot header v2"
grep -qx "page size: $PAGESIZE" "$work/final.info" || die "final image page size is not $PAGESIZE"
grep -qx 'kernel load address: 0x00008000' "$work/final.info" || die "kernel load address mismatch"
grep -qx 'ramdisk load address: 0x01000000' "$work/final.info" || die "ramdisk load address mismatch"
grep -qx 'kernel tags load address: 0x00000100' "$work/final.info" || die "tags address mismatch"
grep -qx 'dtb address: 0x0000000001f00000' "$work/final.info" || die "dtb address mismatch"
if [ -n "$header_cmdline" ]; then
	grep -qxF "command line args: $header_cmdline" "$work/final.info" || die "header cmdline mismatch"
else
	grep -qx 'command line args: ' "$work/final.info" || die "header cmdline is not empty (got: $(grep -m1 'command line args:' "$work/final.info"))"
fi
grep -qx 'additional command line args: ' "$work/final.info" || die "additional cmdline is not empty"
grep -qx "kernel_size: $(stat -c '%s' "$image_gz")" "$work/final.info" || die "kernel_size field mismatch"
grep -qx "ramdisk size: $ramdisk_bytes" "$work/final.info" || die "ramdisk size field mismatch"
grep -qx "dtb size: $final_dtb_bytes" "$work/final.info" || die "dtb size field mismatch"
cmp -s "$image_gz" "$work/final-unpacked/kernel" || die "unpacked kernel differs from the gzipped Image"
gzip -dc "$work/final-unpacked/kernel" >"$work/Image.roundtrip"
cmp -s "$image" "$work/Image.roundtrip" || die "unpacked kernel does not decompress to the source Image"
cmp -s "$final_dtb" "$work/final-unpacked/dtb" || die "unpacked DTB differs from the assembled DTB"
cmp -s "$ramdisk" "$work/final-unpacked/ramdisk" || die "unpacked ramdisk differs from the input initramfs"

# ramdisk content spot checks (the initramfs itself is verified by
# scripts/build-initramfs.sh; here we prove it survived the packaging).
ramdisk_dir=$work/ramdisk
mkdir -p "$ramdisk_dir"
gzip -dc "$work/final-unpacked/ramdisk" | (cd "$ramdisk_dir" && cpio -idm --quiet) ||
	die "unpacked ramdisk could not be extracted"
[ -f "$ramdisk_dir/init" ] || die "ramdisk has no /init"
[ -f "$ramdisk_dir/bin/busybox" ] || die "ramdisk has no /bin/busybox"
# auto: the RAM installer is the ramdisk that carries the installer marker.
detected_ramdisk_mode=persistent
[ -f "$ramdisk_dir/etc/liuqin-installer" ] && detected_ramdisk_mode=installer
if [ "$ramdisk_mode" = auto ]; then
	ramdisk_mode=$detected_ramdisk_mode
elif [ "$ramdisk_mode" != "$detected_ramdisk_mode" ]; then
	die "ramdisk is a $detected_ramdisk_mode ramdisk, not $ramdisk_mode: $ramdisk"
fi
if [ "$ramdisk_mode" = installer ]; then
	[ "$(cat "$ramdisk_dir/etc/liuqin-installer")" = liuqin ] || die "installer ramdisk marker is wrong"
	[ "$(cat "$ramdisk_dir/etc/liuqin-storage-mode")" = readonly ] ||
		die "installer ramdisk is not in read-only storage mode"
	[ -e "$ramdisk_dir/usr/sbin/mkfs.ext4" ] || die "installer ramdisk lacks mkfs.ext4"
	[ -e "$ramdisk_dir/usr/lib/liuqin/install-root.sh" ] || die "installer ramdisk lacks install-root.sh"
	# ADR-0004 D4: installer.img must embed the admission contract v2.
	[ -f "$ramdisk_dir/etc/liuqin-fedora-root.contract" ] ||
		die "installer ramdisk has no Fedora root contract (ADR-0004 D4)"
	[ "$(head -n 1 "$ramdisk_dir/etc/liuqin-fedora-root.contract")" = LIUQIN_FEDORA_ROOT_CONTRACT_V2 ] ||
		die "installer ramdisk contract header is not LIUQIN_FEDORA_ROOT_CONTRACT_V2"
else
	[ -f "$ramdisk_dir/etc/liuqin-fedora-root.contract" ] || die "ramdisk has no Fedora root contract"
	[ "$(head -n 1 "$ramdisk_dir/etc/liuqin-fedora-root.contract")" = LIUQIN_FEDORA_ROOT_CONTRACT_V2 ] ||
		die "ramdisk contract header is not LIUQIN_FEDORA_ROOT_CONTRACT_V2"
	[ "$(cat "$ramdisk_dir/etc/liuqin-root-profile")" = fedora ] || die "ramdisk root profile is not fedora"
	[ "$(cat "$ramdisk_dir/etc/liuqin-fedora-root.contract" | wc -l)" -ge 8 ] ||
		die "ramdisk contract has fewer than 8 lines"
	[ -x "$ramdisk_dir/bin/liuqin-mark-slot-successful" ] || die "ramdisk lacks the slot-success helper"
	[ -x "$ramdisk_dir/bin/liuqin-charger-mode" ] || die "ramdisk lacks the charger-mode state machine"
fi
say "ramdisk mode: $ramdisk_mode"

# boot partition zero-padding expectation: upstream zero-fills to 192 MiB when
# flashing; the image itself must fit.
headroom=$((PARTITION_BYTES - bootimg_bytes))

# The ramdisk's own build info says whether it is device-ready (real firmware +
# real root contract).  The boot image is only device-ready if both are.
ramdisk_device_ready=false
if [ "$ramdisk_mode" = installer ]; then
	ramdisk_info=$(dirname -- "$ramdisk")/installer-initramfs-info.json
else
	ramdisk_info=$(dirname -- "$ramdisk")/initramfs-info.json
fi
if [ -r "$ramdisk_info" ]; then
	ramdisk_device_ready=$(python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("device_ready") else "false")' "$ramdisk_info" 2>/dev/null || echo false)
fi
if [ "$ramdisk_device_ready" != true ]; then
	say "WARNING: the ramdisk is not device-ready (missing firmware or synthetic root contract);"
	say "         this boot image is an offline structure-validation artifact"
fi

# ---------------------------------------------------------------------------
# 6. Structure comparison against the published v0.6.0 boot.img
# ---------------------------------------------------------------------------
release_info_ok=0
if [ -f "$release_bootimg" ] && [ "$(sha "$release_bootimg")" = "$RELEASE_BOOTIMG_SHA256" ]; then
	if [ -f "$work/release.info" ]; then
		release_info_ok=1
	else
		python3 "$mkbootimg_dir/unpack_bootimg.py" --boot_img "$release_bootimg" \
			--out "$work/release-unpacked-cmp" --format info >"$work/release.info" && release_info_ok=1
	fi
fi
release_kernel_bytes=$(awk -F': ' '/^kernel_size:/{print $2}' "$work/release.info" 2>/dev/null || echo unknown)
release_ramdisk_bytes=$(awk -F': ' '/^ramdisk size:/{print $2}' "$work/release.info" 2>/dev/null || echo unknown)
release_dtb_bytes=$(awk -F': ' '/^dtb size:/{print $2}' "$work/release.info" 2>/dev/null || echo unknown)

# ---------------------------------------------------------------------------
# 7. Provenance: kernel source commit vs the published release
# ---------------------------------------------------------------------------
# Kernel source lock: kernel-builder may publish kernel/source.json; until then
# the read-only upstream clone's copy is the authoritative pin.
kernel_lock_json=$project_root/kernel/source.json
[ -f "$kernel_lock_json" ] || kernel_lock_json=$upstream/kernel/source.json
kernel_commit_ours=
kernel_config_sha=
if [ -f "$kernel_lock_json" ]; then
	kernel_commit_ours=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",""))' "$kernel_lock_json" 2>/dev/null || true)
	kernel_config_sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("config_sha256",""))' "$kernel_lock_json" 2>/dev/null || true)
fi
release_kernel_commit=
release_project_commit=
if [ -f "$project_root/cache/upstream-v0.6.0/bundle.json" ]; then
	release_kernel_commit=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("kernel_commit",""))' "$project_root/cache/upstream-v0.6.0/bundle.json" 2>/dev/null || true)
	release_project_commit=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("project_commit",""))' "$project_root/cache/upstream-v0.6.0/bundle.json" 2>/dev/null || true)
fi
source_commit_match=unknown
if [ -n "$kernel_commit_ours" ] && [ -n "$release_kernel_commit" ]; then
	if [ "$kernel_commit_ours" = "$release_kernel_commit" ]; then
		source_commit_match=true
	else
		source_commit_match=false
		say "WARNING: kernel source commit ($kernel_commit_ours) differs from the published release commit ($release_kernel_commit)"
	fi
fi

# ---------------------------------------------------------------------------
# 8. Artifacts: SHA256SUMS, build-info.json, VERIFICATION.md
# ---------------------------------------------------------------------------
cp -f "$image_gz" "$out_root/Image.gz"
cp -f "$final_dtb" "$out_root/liuqin-abl-boot.dtb"
cp -f "$work/final.dts" "$out_root/liuqin-abl-boot.dtb.dts"
# Keep the actual build/RPM config separately from the upstream config lock.
# Do not silently reuse a previous run's snapshot for a fallback kernel.
kernel_config_snapshot_sha=
if [ -n "$kernel_config" ]; then
	cp -f "$kernel_config" "$out_root/kernel.config"
	kernel_config_snapshot_sha=$(sha "$out_root/kernel.config")
elif [ -f "$out_root/kernel.config" ]; then
	rm -f -- "$out_root/kernel.config"
fi

[ -n "$kernel_provenance" ] || kernel_provenance=$kernel_source
kernel_source_note="real cross-compiled Image from --kernel-out"
[ "$kernel_source" = kernel-build ] ||
	kernel_source_note="PUBLISHED v0.6.0 kernel Image fallback (structure validation only)"

python3 - "$out_root/build-info.json" \
	"$bootimg_sha" "$bootimg_bytes" "$headroom" \
	"$kernel_source" "$kernel_image_sha" "$kernel_image_bytes" "$kernel_release_expected" "$kernel_provenance" \
	"$image_gz_sha" "$image_gz_bytes" \
	"$ramdisk" "$ramdisk_sha" "$ramdisk_bytes" \
	"$dtb_source" "$dtb_provenance" "$final_dtb_sha" "$final_dtb_bytes" \
	"$cmdline" "$header_cmdline" "$release_bootimg" "$release_kernel_commit" \
	"$release_project_commit" "$kernel_commit_ours" "$kernel_config_sha" \
	"$source_commit_match" "$raw_dtb_comparison" "$canonical_used" \
	"$release_kernel_bytes" "$release_ramdisk_bytes" "$release_dtb_bytes" \
	"$release_info_ok" "$ramdisk_device_ready" "$ramdisk_mode" "$kernel_config_snapshot_sha" \
	"$canonical_compat_patch_sha" "$raw_mdss_interconnects_match" <<'PY'
import json
import sys
from pathlib import Path

(out, boot_sha, boot_bytes, headroom, kernel_source, image_sha, image_bytes,
 kernel_release, kernel_provenance, image_gz_sha, image_gz_bytes, ramdisk, ramdisk_sha,
 ramdisk_bytes, dtb_source, dtb_provenance, dtb_sha, dtb_bytes, cmdline,
 header_cmdline, release_bootimg, release_kernel_commit, release_project_commit,
 kernel_commit_ours, kernel_config_sha, source_commit_match, raw_dtb_comparison,
 canonical_used, release_kernel_bytes, release_ramdisk_bytes, release_dtb_bytes,
 release_info_ok, ramdisk_device_ready, ramdisk_mode, config_snapshot_sha,
 canonical_compat_patch_sha, raw_mdss_interconnects_match) = sys.argv[1:38]

Path(out).write_text(json.dumps({
    "artifact": "boot-liuqin-dev.img",
    "artifact_sha256": boot_sha,
    "artifact_bytes": int(boot_bytes),
    "format": "Android boot image v2 (pagesize 4096)",
    "device": "liuqin (Xiaomi Pad 6 Pro, SM8475)",
    "partition_bytes": 201326592,
    "partition_headroom_bytes": int(headroom),
    "fits_partition": int(boot_bytes) <= 201326592,
    "header": {
        "version": 2,
        "pagesize": 4096,
        "kernel_offset": "0x00008000",
        "ramdisk_offset": "0x01000000",
        "tags_offset": "0x00000100",
        "dtb_offset": "0x01f00000",
        "cmdline": header_cmdline,
        "second": None,
        "recovery_dtbo": None,
    },
    "payload": {
        "kernel": {
            "source": kernel_source,
            "provenance": kernel_provenance,
            "image_sha256": image_sha,
            "image_bytes": int(image_bytes),
            "gzip_sha256": image_gz_sha,
            "gzip_bytes": int(image_gz_bytes),
            "release": kernel_release or None,
            "config_snapshot": "kernel.config" if config_snapshot_sha else None,
            "config_sha256": config_snapshot_sha or None,
        },
        "ramdisk": {
            "path": ramdisk,
            "sha256": ramdisk_sha,
            "bytes": int(ramdisk_bytes),
            "mode": ramdisk_mode,
            "description": ("RAM-installer initramfs (read-only storage, telnet install shell)"
                            if ramdisk_mode == "installer"
                            else "Fedora-fied stage-1 initramfs (PID 1 /init, BusyBox 1.36.1)"),
        },
        "dtb": {
            "source": dtb_source,
            "provenance": dtb_provenance,
            "sha256": dtb_sha,
            "bytes": int(dtb_bytes),
            "cmdline_source": "DTB /chosen/bootargs",
            "dt_bootargs": cmdline,
            "header_cmdline_empty": header_cmdline == "",
            "canonical_stock_rom_rebuild": canonical_used == "1",
            "linux_splash": "linux_splash" in dtb_provenance,
            "raw_mdss_interconnects_match": {"true": True, "unknown": None}[raw_mdss_interconnects_match],
            "builder_compatibility_patch": ({
                "path": "overlays/boot/abl-symbols-dtc-labels.patch",
                "sha256": canonical_compat_patch_sha,
                "scope": "scratch copy of pinned upstream tools; clone unchanged",
            } if canonical_compat_patch_sha else None),
        },
    },
    "kernel_source_commit": {
        "project_lock_commit": kernel_commit_ours or None,
        "project_lock_config_sha256": kernel_config_sha or None,
        "release_kernel_commit": release_kernel_commit or None,
        "release_project_commit": release_project_commit or None,
        "match": {"true": True, "false": False, "unknown": None}[source_commit_match],
        "raw_kernel_dtb_comparison": raw_dtb_comparison or None,
    },
    "release_structure_reference": {
        "bootimg": release_bootimg,
        "bootimg_sha256": "7a368e58291f974f1cebd1e91e81ce8edc7256a19f75c4baea3fffd883157900",
        "kernel_gzip_bytes": release_kernel_bytes,
        "ramdisk_bytes": release_ramdisk_bytes,
        "dtb_bytes": release_dtb_bytes,
        "compared": release_info_ok == "1",
    },
    "verification": {
        "unpack_bootimg.py": "06b54dd9a07c5281778e29e234e76f6e3faee8bf0c904a5ef88fdee30eeed12e",
        "mkbootimg.py": "37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c",
        "checks": [
            "header v2, page size 4096, offsets and dtb address",
            "header cmdline empty, additional cmdline empty",
            "kernel/ramdisk/dtb sizes match the fields",
            "unpacked payload byte-identical to inputs (kernel .gz, decompressed Image, DTB, ramdisk)",
            "ramdisk re-extracts and carries /init, BusyBox, Fedora root contract, helpers",
            "DTB board identity, /chosen bootargs, __symbols__ sink, framebuffer, /chosen cells",
            "DTB linux_splash reserved-memory handoff (ABL cold display)",
            "image fits the 192 MiB boot partition",
        ],
        "device_write": "none: this image was assembled and verified offline only",
    },
    "device_ready": (kernel_source == "kernel-build") and ramdisk_device_ready == "true",
}, indent=2) + "\n")
PY

cat >"$out_root/VERIFICATION.md" <<EOF
# boot-liuqin-dev.img — offline structure verification

> Generated by \`scripts/build-bootimg.sh\` on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
> **Offline only.** No tablet was connected, no fastboot command was run and no
> device partition was written. This file describes image *structure*, not
> on-device behaviour.

## 1. Artifact

| field | value |
|---|---|
| file | \`boot-liuqin-dev.img\` |
| sha256 | \`$bootimg_sha\` |
| bytes | $bootimg_bytes |
| partition | 192 MiB (201,326,592 B), headroom $headroom B |
| header | Android boot image **v2**, page size 4096 |
| header cmdline | empty (ABL supplies DT \`/chosen/bootargs\`) |
| kernel load address | 0x00008000 |
| ramdisk load address | 0x01000000 |
| tags address | 0x00000100 |
| DTB address | 0x01f00000 |

## 2. Payload provenance

| part | source | sha256 | bytes |
|---|---|---|---|
| kernel | $kernel_source_note | \`$kernel_image_sha\` (Image), gz \`$image_gz_sha\` | Image $kernel_image_bytes / gz $image_gz_bytes |
| ramdisk | Fedora stage-1 initramfs (\`scripts/build-initramfs.sh\`) | \`$ramdisk_sha\` | $ramdisk_bytes |
| DTB | $dtb_provenance | \`$final_dtb_sha\` | $final_dtb_bytes |

Kernel release expected: \`${kernel_release_expected:-unknown}\`.

Kernel source commit vs published v0.6.0 release: project lock
\`${kernel_commit_ours:-unknown}\`, release \`${release_kernel_commit:-unknown}\`,
match: \`${source_commit_match}\`. ${raw_dtb_comparison:+Raw DTB comparison: $raw_dtb_comparison.}

## 3. DTB path decision

- requested mode: \`$dtb_source\`
- canonical stock-ROM rebuild used: \`$canonical_used\`
- provenance: $dtb_provenance

Canonical path (\`--dtb-source stock-rom\`) requires the user's stock ROM analysis
tree (44 \`entry.NN\` DTBO entries + 14 \`dtb-NN.dtb\` base DTBs from
\`OS2.0.6.0.VMYCNXM\`) and the kernel build's \`dtc\`/\`fdtoverlay\`. The offline
substitute reuses the published release DTB byte-for-byte after re-verifying its
board identity, \`/chosen\` bootargs, ABL symbol sink and framebuffer properties.

**Risk of the substitute path:** the DTB is the one upstream validated on this
device, but it was produced from the same kernel source commit as the published
kernel. If our kernel tree/DT patches ever diverge, this DTB may not match the
kernel's expectations (e.g. /chosen, reserved-memory, firmware nodes). Treat the
substitute image as offline-valid only until the canonical stock-ROM rebuild is
possible on the user's machine.

## 4. Structure comparison with the published v0.6.0 boot.img

| field | published v0.6.0 | this image |
|---|---|---|
| header version | 2 | 2 |
| page size | 4096 | $PAGESIZE |
| kernel (gzip bytes) | ${release_kernel_bytes:-unknown} | $image_gz_bytes |
| kernel (Image bytes) | 56826368 | $kernel_image_bytes |
| ramdisk bytes | ${release_ramdisk_bytes:-unknown} | $ramdisk_bytes |
| dtb bytes | ${release_dtb_bytes:-unknown} | $final_dtb_bytes |
| header cmdline | empty | ${header_cmdline:-empty} |
| kernel/ramdisk/tags/dtb addresses | 0x8000/0x01000000/0x100/0x01f00000 | same |
| boot image bytes | 50216960 | $bootimg_bytes |
| partition headroom | 151109632 | $headroom |

The published image's ramdisk is 31.8 MB because it embeds the full Ubuntu
firmware set; this dev image is much smaller because firmware categories were
skipped (see \`initramfs-info.json\`). A device-ready build adds them back and
lands in the same order of magnitude as the published ramdisk.

## 5. Checks that ran

- header v2 / page size / load addresses / DTB address via \`unpack_bootimg.py\`
- empty header cmdline and empty additional cmdline
- kernel/ramdisk/DTB sizes equal their header fields
- payload round-trip byte comparisons (gzip kernel, decompressed Image, DTB, ramdisk)
- ramdisk re-extracted; /init, /bin/busybox, Fedora root admission contract v2, slot/charger helpers present
- DTB: qcom,msm-id / qcom,board-id / xiaomi,miboard-id, /chosen bootargs, __symbols__ sink, simple-framebuffer geometry, /chosen cell counts and ranges
- boot image fits the 192 MiB partition

## 6. Not verified here (requires hardware, Phase 6)

- ABL acceptance of the DTB and of the image as a whole
- kernel boot, UFS fail-closed admission, slot-successful marking
- charger-mode hold, USB NCM rescue, switch_root into the Fedora root
- panel, touch, keyboard, audio, Wi-Fi/BT, fingerprint, sensors
EOF

(
	cd "$out_root"
	sha256sum boot-liuqin-dev.img Image.gz liuqin-abl-boot.dtb \
		liuqin-abl-boot.dtb.dts >SHA256SUMS
	if [ -n "$kernel_config_snapshot_sha" ]; then
		sha256sum kernel.config >>SHA256SUMS
	fi
	# The ramdisk artifacts live beside the boot image only when this output
	# directory is also the initramfs output directory (persistent image);
	# installer.img assembly uses a separate initramfs output directory.
	for ramdisk_artifact in initramfs/liuqin-firstboot.cpio.gz \
		initramfs/liuqin-installer.cpio.gz \
		initramfs/liuqin-fedora-root.contract; do
		[ -f "$ramdisk_artifact" ] || continue
		sha256sum "$ramdisk_artifact" >>SHA256SUMS
	done
)
say "verification: $out_root/VERIFICATION.md"
say "build info:   $out_root/build-info.json"
say "sha256sums:   $out_root/SHA256SUMS"
say "boot image:   $final_bootimg"
printf '%s\n' "$final_bootimg"
