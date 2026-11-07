#!/bin/sh
# SPDX-License-Identifier: MIT
#
# /usr/libexec/liuqin/boot-assets/bin/build-initramfs.sh — on-device wrapper
# around the (copied) project scripts/build-initramfs.sh.
#
# It pins the on-device defaults that differ from the development checkout:
#   * BusyBox: the static aarch64 binary shipped in this package;
#   * compiler for the static stage-1 helpers: bin/cc-prebuilt, which installs
#     the prebuilt static aarch64 helpers shipped in this package (no compiler
#     is required on the device).
#
# Callers (liuqin-bootimg-refresh / kernel-install hook / tests) may override
# any of these by passing their own --busybox/--slot-gcc after the defaults;
# the project script uses the last value.
set -eu

assets=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$assets/scripts/build-initramfs.sh
[ -f "$script" ] || {
	printf 'build-initramfs: packaged script is missing: %s\n' "$script" >&2
	exit 2
}

exec /bin/sh "$script" \
	--slot-gcc "$assets/bin/cc-prebuilt" \
	--busybox "$assets/out/boot/toolchain/busybox-1.36.1-aarch64-static" \
	"$@"
