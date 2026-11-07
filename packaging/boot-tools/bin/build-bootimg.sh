#!/bin/sh
# SPDX-License-Identifier: MIT
#
# /usr/libexec/liuqin/boot-assets/bin/build-bootimg.sh — on-device wrapper
# around the (copied) project scripts/build-bootimg.sh.
#
# Pins the packaged defaults (AOSP mkbootimg scripts and the DT /chosen
# bootargs source). Callers may override with their own arguments; the project
# script uses the last value for repeated options.
set -eu

assets=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$assets/scripts/build-bootimg.sh
[ -f "$script" ] || {
	printf 'build-bootimg: packaged script is missing: %s\n' "$script" >&2
	exit 2
}

exec /bin/sh "$script" \
	--mkbootimg-dir "$assets/mkbootimg" \
	--cmdline-file "$assets/liuqin-bootargs.txt" \
	"$@"
