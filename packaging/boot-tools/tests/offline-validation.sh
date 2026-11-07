#!/bin/bash
# SPDX-License-Identifier: MIT
#
# offline-validation.sh — offline validation of the installed liuqin-boot-tools
# tree. Called by scripts/build-boot-tools-rpm.sh with RPM payloads extracted
# into temporary roots (the host has no rpm/yum; extraction happens in the
# Fedora builder container).
#
# What is validated (no device, no network):
#   1. installed asset tree integrity (assets.manifest, BusyBox sha, helpers);
#   2. initramfs rebuild from the packaged scripts/tools/BusyBox (no firmware:
#      --allow-missing-firmware) + the generated contract v2 (ADR-0004 D2)
#      must NOT content-pin kernel identity (P0-1): an existence-only `file`
#      entry is the reviewed v2 interface, a sha256 `marker` pin is not;
#   3. boot.img assembly (header v2) using the packaged mkbootimg scripts, the
#      packaged build-bootimg.sh and the real Fedora-fragment kernel Image; the
#      dev-only published-DTB fallback stands in for the user's stock ROM;
#   4. fail-closed behaviour of the kernel-install hook / refresh pipeline from
#      the kernel-liuqin RPM for missing stock ROM, missing firmware pool and
#      missing rootfs hash manifest (nothing may be staged);
#   5. `liuqin-boot-tools stage` firmware staging from the extracted
#      liuqin-firmware/liuqin-audio RPM trees (copy mapping only; not fed into
#      build-initramfs because vendor-only files are absent offline).
#
# The full canonical refresh success path needs the user's own stock ROM
# analysis tree (44 DTBO entries + 14 vendor_boot base DTBs) and real device
# firmware; that is device/Phase-6 validation and is reported as not-validated.
set -euo pipefail

BOOT_TOOLS_ROOT=
KERNEL_ROOT=
FIRMWARE_ROOT=
FIRMWARE_RPM_ROOT=
AUDIO_ROOT=
KERNEL_DIST=
PUBLISHED_BOOTIMG=
WORK=
STOCK_ROM_DIR=

while [ $# -gt 0 ]; do
	case $1 in
	--boot-tools-root) BOOT_TOOLS_ROOT=${2:?}; shift 2 ;;
	--kernel-root) KERNEL_ROOT=${2:?}; shift 2 ;;
	--firmware-root) FIRMWARE_ROOT=${2:?}; shift 2 ;;
	--firmware-rpm-root) FIRMWARE_RPM_ROOT=${2:?}; shift 2 ;;
	--audio-root) AUDIO_ROOT=${2:?}; shift 2 ;;
	--kernel-dist) KERNEL_DIST=${2:?}; shift 2 ;;
	--published-bootimg) PUBLISHED_BOOTIMG=${2:?}; shift 2 ;;
	--work) WORK=${2:?}; shift 2 ;;
	--stock-rom-dir) STOCK_ROM_DIR=${2:?}; shift 2 ;;
	*) printf 'offline-validation: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done
for var in BOOT_TOOLS_ROOT KERNEL_ROOT FIRMWARE_ROOT FIRMWARE_RPM_ROOT AUDIO_ROOT KERNEL_DIST PUBLISHED_BOOTIMG WORK; do
	eval "value=\${$var}"
	[ -n "$value" ] || { printf 'offline-validation: --%s is required\n' "$var" >&2; exit 2; }
done

ASSETS="$BOOT_TOOLS_ROOT/usr/libexec/liuqin/boot-assets"
PASS=0
FAIL=0
ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
no() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf 'INFO  %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

[ -d "$ASSETS" ] || { printf 'assets tree missing: %s\n' "$ASSETS" >&2; exit 1; }
rm -rf "$WORK"
mkdir -p "$WORK"

KERNEL_DIST=$(CDPATH= cd -- "$KERNEL_DIST" && pwd)
PUBLISHED_BOOTIMG=$(CDPATH= cd -- "$(dirname -- "$PUBLISHED_BOOTIMG")" && pwd)/$(basename -- "$PUBLISHED_BOOTIMG")
KVER=$(cat "$KERNEL_ROOT/usr/share/liuqin/kernel.release")
info "kernel release: $KVER"
info "assets tree: $ASSETS"

# ---------------------------------------------------------------- 1. integrity
section "1. installed asset tree integrity"
if (cd "$ASSETS" && sha256sum -c assets.manifest --quiet); then
	ok "assets.manifest verifies ($(grep -c . "$ASSETS/assets.manifest") files)"
else
	no "assets.manifest mismatch"
fi
for f in bin/busybox bin/cc-prebuilt bin/build-initramfs.sh bin/build-bootimg.sh \
	initramfs/init tools/build-root-contract.py mkbootimg/mkbootimg.py \
	overlays/boot/abl-symbols-dtc-labels.patch \
	helpers/liuqin-mark-slot-successful helpers/liuqin-charger-mode-power-key \
	helpers/liuqin-charger-mode-exit \
	out/boot/toolchain/busybox-1.36.1-aarch64-static; do
	if [ -e "$ASSETS/$f" ]; then ok "present: $f"; else no "missing: $f"; fi
done
want_bb=$(cut -d' ' -f1 <"$ASSETS/busybox.sha256")
got_bb=$(sha256sum "$ASSETS/bin/busybox" | cut -d' ' -f1)
[ "$want_bb" = "$got_bb" ] && ok "BusyBox sha256 matches pinned $want_bb" || no "BusyBox sha mismatch"
if /bin/sh "$ASSETS/bin/liuqin-boot-tools" verify >"$WORK/verify-cli.txt" 2>&1; then
	ok "liuqin-boot-tools verify: PASS"
else
	no "liuqin-boot-tools verify FAILED"
fi
grep -E 'asset verification' "$WORK/verify-cli.txt" | sed 's/^/  /' || true

# ---------------------------------------------------------------- 2. initramfs + contract
section "2. initramfs rebuild + root contract v2 (no kernel identity pins)"
ROOTFS_MANIFEST="$WORK/rootfs.files.sha256"
cp "$ASSETS/tools/examples/fedora-root.manifest.example" "$ROOTFS_MANIFEST"
mkdir -p "$WORK/kernel-out-metadata/include/config" "$WORK/kernel-out-metadata/arch/arm64/boot/dts/qcom"
printf '%s\n' "$KVER" >"$WORK/kernel-out-metadata/include/config/kernel.release"
if /bin/sh "$ASSETS/bin/build-initramfs.sh" \
	--out "$WORK/initramfs" \
	--kernel-out "$WORK/kernel-out-metadata" \
	--rootfs-manifest "$ROOTFS_MANIFEST" \
	--allow-missing-firmware >"$WORK/initramfs-build.txt" 2>&1; then
	ok "build-initramfs.sh (packaged scripts/busybox/helpers) exit 0"
else
	no "build-initramfs.sh failed (see below)"
	tail -n 20 "$WORK/initramfs-build.txt" | sed 's/^/  /'
fi
RAMDISK="$WORK/initramfs/initramfs/liuqin-firstboot.cpio.gz"
CONTRACT="$WORK/initramfs/initramfs/liuqin-fedora-root.contract"
if [ -s "$RAMDISK" ]; then
	ok "ramdisk produced: $(stat -c '%s' "$RAMDISK") B"
	gzip -dc "$RAMDISK" | cpio -it --quiet 2>/dev/null | grep -qxE '(\./)?init' &&
		ok "ramdisk contains ./init" || no "ramdisk lacks ./init"
	gzip -dc "$RAMDISK" | cpio -it --quiet 2>/dev/null | grep -qxE '(\./)?bin/busybox' &&
		ok "ramdisk contains ./bin/busybox" || no "ramdisk lacks ./bin/busybox"
else
	no "no ramdisk produced"
fi
if [ -s "$CONTRACT" ]; then
	ok "root contract generated ($(wc -l <"$CONTRACT") lines)"
	# P0-1 / ADR-0004 D2/D5: contract v2 keeps kernel identity as an
	# existence-only interface (`file ...`).  The v1 defect was a content
	# hash (marker) pin of it, which turned a dnf kernel upgrade into a
	# rescue boot; that is the only form the test must reject.
	if grep -qE '^marker +/usr/(share/liuqin/(kernel\.release|kernel-modules\.manifest)|lib/modules/)' "$CONTRACT"; then
		no "P0-1 violation: contract content-pins kernel identity"
	elif ! grep -qE '^file +/usr/share/liuqin/(kernel\.release|kernel-modules\.manifest)$' "$CONTRACT"; then
		no "contract v2 is missing the kernel identity existence interface"
	else
		ok "P0-1: kernel identity is existence-only in contract v2 (no content pin)"
	fi
else
	no "no contract generated"
fi

# ---------------------------------------------------------------- 3. boot.img (header v2)
section "3. boot.img assembly (header v2) with packaged mkbootimg"
KO="$WORK/kernel-out"
mkdir -p "$KO/arch/arm64/boot/dts/qcom" "$KO/include/config" "$KO/scripts/dtc"
ln -sfn "$KERNEL_DIST/Image" "$KO/arch/arm64/boot/Image"
ln -sfn "$KERNEL_DIST/sm8475-xiaomi-liuqin.dtb" "$KO/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb"
printf '%s\n' "$KVER" >"$KO/include/config/kernel.release"
for tool in dtc fdtoverlay; do
	[ -x "/usr/bin/$tool" ] && ln -sfn "/usr/bin/$tool" "$KO/scripts/dtc/$tool"
done
# With project DTS fixes, validation must use canonical ROM inputs: the
# published-DTB substitute intentionally fails if it would discard the fix.
DTB_ARGS=(--dtb-source upstream-artifact)
if [ -n "$STOCK_ROM_DIR" ]; then
	STOCK_ROM_DIR=$(CDPATH= cd -- "$STOCK_ROM_DIR" && pwd)
	DTB_ARGS=(--dtb-source stock-rom --stock-rom-dir "$STOCK_ROM_DIR")
fi
python3 "$ASSETS/mkbootimg/unpack_bootimg.py" --boot_img "$PUBLISHED_BOOTIMG" \
	--out "$WORK/published" --format info >"$WORK/published-info.txt" 2>&1 || true
if [ -s "$RAMDISK" ]; then
	if /bin/sh "$ASSETS/bin/build-bootimg.sh" \
		--kernel-out "$KO" \
		--ramdisk "$RAMDISK" \
		--out "$WORK/boot" \
		"${DTB_ARGS[@]}" \
		--release-bootimg "$PUBLISHED_BOOTIMG" \
		--strict-kernel >"$WORK/bootimg-build.txt" 2>&1; then
		ok "build-bootimg.sh exit 0 (--strict-kernel, ${DTB_ARGS[*]})"
	else
		no "build-bootimg.sh failed"
		tail -n 25 "$WORK/bootimg-build.txt" | sed 's/^/  /'
	fi
fi
# TN0085: the same builder must accept the project cmdline (upstream bootargs
# plus gnome.is_vm=0) on the canonical stock-rom path and put it in the final
# DTB /chosen bootargs. This is the cmdline a kernel update will use.
if [ -s "$RAMDISK" ] && [ -n "$STOCK_ROM_DIR" ]; then
	if /bin/sh "$ASSETS/bin/build-bootimg.sh" \
		--kernel-out "$KO" \
		--ramdisk "$RAMDISK" \
		--out "$WORK/boot-project" \
		"${DTB_ARGS[@]}" \
		--cmdline-file "$ASSETS/liuqin-bootargs.txt" \
		--release-bootimg "$PUBLISHED_BOOTIMG" \
		--strict-kernel >"$WORK/bootimg-project-build.txt" 2>&1; then
		ok "build-bootimg.sh exit 0 with project cmdline ($ASSETS/liuqin-bootargs.txt)"
		python3 "$ASSETS/mkbootimg/unpack_bootimg.py" --boot_img "$WORK/boot-project/boot-liuqin-dev.img" \
			--out "$WORK/boot-project-unpacked" --format info >/dev/null 2>&1 || true
		# Search the DTB bytes directly.  Do not pipe strings/dtc into grep -q:
		# this script uses pipefail, and grep -q exits early, so the producer
		# gets SIGPIPE and the pipeline is reported as a false failure.
		if [ -f "$WORK/boot-project-unpacked/dtb" ] &&
		   grep -aq 'gnome.is_vm=0' "$WORK/boot-project-unpacked/dtb"; then
			ok "project cmdline token gnome.is_vm=0 is present in the final DTB /chosen bootargs"
		else
			no "project cmdline token missing from the final DTB /chosen bootargs"
		fi
		if [ -f "$WORK/boot-project-unpacked/dtb" ] &&
		   grep -aq 'linux_splash@b8000000' "$WORK/boot-project-unpacked/dtb" &&
		   ! grep -aq 'splash_region@b8000000' "$WORK/boot-project-unpacked/dtb"; then
			ok "project DTB uses linux_splash@b8000000 for the ABL cold-display handoff"
		else
			no "project DTB missing linux_splash@b8000000 or still uses splash_region@b8000000"
		fi
	else
		no "build-bootimg.sh failed with project cmdline"
		tail -n 25 "$WORK/bootimg-project-build.txt" | sed 's/^/  /'
	fi
fi

IMG="$WORK/boot/boot-liuqin-dev.img"
if [ -s "$IMG" ]; then
	size=$(stat -c '%s' "$IMG")
	[ "$size" -le 201326592 ] && ok "boot.img size $size B <= 192 MiB partition" || no "boot.img too large: $size"
	python3 "$ASSETS/mkbootimg/unpack_bootimg.py" --boot_img "$IMG" --out "$WORK/boot-unpacked" \
		--format info >"$WORK/boot-info.txt" 2>&1 || true
	grep -q 'boot image header version: 2' "$WORK/boot-info.txt" && ok "boot image header version = 2" || no "header version is not 2"
	grep -q 'page size: 4096' "$WORK/boot-info.txt" && ok "page size = 4096" || no "page size is not 4096"
	gzip -dc "$WORK/boot-unpacked/kernel" >"$WORK/Image.unpacked" 2>/dev/null || cp "$WORK/boot-unpacked/kernel" "$WORK/Image.unpacked"
	kernel_sha=$(sha256sum "$WORK/Image.unpacked" | cut -d' ' -f1)
	want_kernel=$(sha256sum "$KERNEL_DIST/Image" | cut -d' ' -f1)
	[ "$kernel_sha" = "$want_kernel" ] &&
		ok "boot.img kernel == Fedora-fragment Image ($kernel_sha)" ||
		no "boot.img kernel mismatch: $kernel_sha != $want_kernel"
	if [ -f "$WORK/published/dtb" ] && [ -f "$WORK/boot-unpacked/dtb" ]; then
		sha256sum "$WORK/boot-unpacked/dtb" >/dev/null
		ok "boot.img dtb extracted ($(stat -c '%s' "$WORK/boot-unpacked/dtb") B, ${DTB_ARGS[*]})"
	fi
else
	no "no boot.img produced"
fi

# ---------------------------------------------------------------- 4. fail-closed
section "4. kernel-install hook / refresh fail-closed cases"
HOOK="$KERNEL_ROOT/usr/lib/kernel/install.d/99-liuqin-android-boot.install"
REFRESH="$KERNEL_ROOT/usr/libexec/liuqin/liuqin-bootimg-refresh"
MODULES="$KERNEL_ROOT/usr/lib/modules"
KBINFO="$KERNEL_ROOT/usr/share/liuqin/kernel-build-info.json"
[ -x "$HOOK" ] && ok "hook present from kernel-liuqin RPM" || no "hook missing"
[ -x "$REFRESH" ] && ok "refresh present from kernel-liuqin RPM" || no "refresh missing"
STG="$WORK/staging"
LOGS="$WORK/logs"
mkdir -p "$STG" "$LOGS" "$WORK/entry"
write_conf() { # write_conf FILE STOCK FIRMWARE MANIFEST
	# The hook sources this file as shell.  Values are quoted so the fixture also
	# works when the project checkout path contains spaces (the hook's own
	# pre-source LOG_DIR default is passed via LIUQIN_BOOT_LOG_DIR in run_hook).
	cat >"$1" <<CONF
LIUQIN_BOOT_ASSETS_DIR="$ASSETS"
LIUQIN_BOOTIMG_REFRESH="$REFRESH"
LIUQIN_MODULES_DIR="$MODULES"
LIUQIN_KERNEL_BUILD_INFO="$KBINFO"
LIUQIN_ROOTFS_MANIFEST="$4"
LIUQIN_FIRMWARE_POOL="$3"
LIUQIN_WLAN_HSP2_TUPLE="$3"
LIUQIN_AUDIO_TOPOLOGY="$4"
LIUQIN_STOCK_ROM_DIR="$2"
LIUQIN_BOOTIMG_DTB_SOURCE=stock-rom
LIUQIN_MKBOOTIMG_DIR="$ASSETS/mkbootimg"
LIUQIN_CMDLINE_FILE="$ASSETS/liuqin-bootargs.txt"
LIUQIN_BOOT_STAGING_DIR="$STG"
LIUQIN_BOOT_LOG_DIR="$LOGS"
CONF
}
run_hook() { # run_hook CONF -> rc in RC
	# LIUQIN_BOOT_LOG_DIR is set in the environment because the hook resolves
	# LOG_DIR before it sources the conf file.
	if env LIUQIN_BOOT_LOG_DIR="$LOGS" LIUQIN_BOOTIMG_CONF="$1" sh "$HOOK" add "$KVER" "$WORK/entry" \
		"$MODULES/$KVER/vmlinuz" >/dev/null 2>&1; then
		RC=0
	else
		RC=$?
	fi
}
check_refused() { # check_refused NAME
	if [ "${RC:-0}" -ne 0 ]; then ok "$1: hook refused (rc=$RC), nothing staged"
	else no "$1: hook unexpectedly succeeded"; fi
	[ -e "$STG/boot-$KVER.img" ] && no "$1: something was staged" || true
}

# create a usable stock-rom dir shape (contents validated only by boot-builder;
# this fail-closed test stops before the canonical DTB path)
mkdir -p "$WORK/stock/dtbo" "$WORK/stock/vendor_boot/dtbs" "$WORK/fw"
for i in $(seq -w 0 43); do printf 'x' >"$WORK/stock/dtbo/entry.$i"; done
for i in $(seq -w 0 13); do printf 'x' >"$WORK/stock/vendor_boot/dtbs/dtb-$i.dtb"; done
cp "$ASSETS/tools/examples/fedora-root.manifest.example" "$WORK/manifest-full"
printf 'audio\n' >"$WORK/topology.bin"

# F1: no stock ROM analysis tree
write_conf "$WORK/conf-f1" "$WORK/no-stock" "$WORK/fw" "$WORK/manifest-full"
sed -i "s|^LIUQIN_AUDIO_TOPOLOGY=.*|LIUQIN_AUDIO_TOPOLOGY=\"$WORK/topology.bin\"|" "$WORK/conf-f1"
run_hook "$WORK/conf-f1"; check_refused "missing stock ROM"

# F2: stock ROM present but firmware pool missing
rm -rf "$WORK/fw"
write_conf "$WORK/conf-f2" "$WORK/stock" "$WORK/fw" "$WORK/manifest-full"
sed -i "s|^LIUQIN_AUDIO_TOPOLOGY=.*|LIUQIN_AUDIO_TOPOLOGY=\"$WORK/topology.bin\"|" "$WORK/conf-f2"
run_hook "$WORK/conf-f2"; check_refused "missing firmware pool"

# F3: everything present except the rootfs hash manifest
mkdir -p "$WORK/fw"
write_conf "$WORK/conf-f3" "$WORK/stock" "$WORK/fw" "$WORK/no-manifest"
sed -i "s|^LIUQIN_AUDIO_TOPOLOGY=.*|LIUQIN_AUDIO_TOPOLOGY=\"$WORK/topology.bin\"|" "$WORK/conf-f3"
run_hook "$WORK/conf-f3"; check_refused "missing rootfs hash manifest"

# F4: assets tree missing entirely
STG="$WORK/staging-f4"; mkdir -p "$STG"
write_conf "$WORK/conf-f4" "$WORK/stock" "$WORK/fw" "$WORK/manifest-full"
sed -i "s|^LIUQIN_BOOT_ASSETS_DIR=.*|LIUQIN_BOOT_ASSETS_DIR=\"$WORK/no-assets\"|" "$WORK/conf-f4"
sed -i "s|^LIUQIN_BOOTIMG_REFRESH=.*|LIUQIN_BOOTIMG_REFRESH=\"$WORK/no-refresh\"|" "$WORK/conf-f4"
sed -i "s|^LIUQIN_AUDIO_TOPOLOGY=.*|LIUQIN_AUDIO_TOPOLOGY=\"$WORK/topology.bin\"|" "$WORK/conf-f4"
run_hook "$WORK/conf-f4"; check_refused "missing boot-assets/refresh"
if [ -f "$LOGS/bootimg-$KVER.log" ]; then
	if grep -qiE 'stock ROM analysis tree missing|firmware pool missing|rootfs hash manifest missing|boot rebuild tool is missing' "$LOGS/bootimg-$KVER.log"; then
		ok "hook logs name the missing input (fail-closed message)"
	fi
fi

# ---------------------------------------------------------------- 5. stage command
section "5. liuqin-boot-tools stage (firmware copy mapping from device RPMs)"
STAGE_ASSETS="$WORK/stage-assets"
cp -a "$ASSETS" "$STAGE_ASSETS"
chmod -R u+w "$STAGE_ASSETS"
# Merge the extracted liuqin-firmware + liuqin-audio trees into one firmware root.
mkdir -p "$WORK/fw-merged"
cp -al "$FIRMWARE_ROOT/." "$WORK/fw-merged/" 2>/dev/null || cp -a "$FIRMWARE_ROOT/." "$WORK/fw-merged/"
if [ -f "$AUDIO_ROOT/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin" ]; then
	mkdir -p "$WORK/fw-merged/qcom/sm8450"
	cp -a "$AUDIO_ROOT/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin" \
		"$WORK/fw-merged/qcom/sm8450/"
fi
if /bin/sh "$STAGE_ASSETS/bin/liuqin-boot-tools" stage \
	--firmware-root "$WORK/fw-merged" \
	--stock-rom-dir "$WORK/stock" >"$WORK/stage.txt" 2>&1; then
	ok "liuqin-boot-tools stage exit 0"
else
	no "liuqin-boot-tools stage failed"
	tail -n 15 "$WORK/stage.txt" | sed 's/^/  /'
fi
for probe in \
	touch-nt36532/vendor/firmware bt-qca6490/vendor/bt_firmware/image \
	wlan-qca6490/upstream/WCN6855/hw2.0 dsp-sm8475/vendor/qcom/sm8475/liuqin \
	audio/Xiaomi-Pad-6-Pro-tplg.bin; do
	if [ -e "$STAGE_ASSETS/firmware-pool/$probe" ]; then
		ok "staged firmware-pool/$probe"
	else
		info "not staged offline (firmware/vendor file absent): $probe"
	fi
done
[ -e "$STAGE_ASSETS/wlan-hsp2-tuple/hw2.0" ] &&
	ok "staged wlan-hsp2-tuple/hw2.0" || info "wlan-hsp2-tuple not staged offline"
if /bin/sh "$STAGE_ASSETS/bin/liuqin-boot-tools" verify >"$WORK/stage-verify.txt" 2>&1; then
	ok "stage tree verify: PASS"
else
	no "stage tree verify FAILED (asset manifest was modified by staging; expected only for copied tree check)"
fi

# ---------------------------------------------------------------- summary
section "summary"
printf 'offline validation: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
printf 'not validated offline: real canonical refresh success (needs user stock ROM 44+14 + vendor firmware), '
printf 'device runtime under dnf, real boot_a write.\n'
[ "$FAIL" -eq 0 ]
