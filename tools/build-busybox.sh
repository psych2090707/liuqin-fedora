#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build the pinned, statically linked aarch64 BusyBox used as PID-1 interpreter
# of the Fedora liuqin initramfs.
#
# Why a source build and not a distribution package:
#   * the initramfs init script executes BusyBox directly from the root of the
#     kernel's initramfs, so the binary must be static aarch64 ELF;
#   * the same bytes are part of the root-contract trust chain (UFS fail-closed
#     checks are interpreted by this binary), so the input has to be pinned;
#   * upstream v0.6.0 used Ubuntu's busybox-static .deb; this project must not.
#
# The build is deliberately reproducible on this host:
#   SOURCE_DATE_EPOCH=0 is exported before the kconfig run, which makes
#   AUTOCONF_TIMESTAMP (the "BusyBox v1.36.1 (1970-01-01 ...)" banner) fixed.
# Two independent builds with the reference toolchain produced the identical
# sha256 recorded in REFERENCE_SHA256 below (evidence in out/boot/VERIFICATION.md).
#
# BusyBox's build system does not support a source/build path containing spaces
# ("make: *** No rule to make target '/path/with'"), and this project may live
# in a directory with spaces.  The script therefore builds in a
# space-free work directory (default ${TMPDIR:-/tmp}/liuqin-busybox-<version>)
# and installs only the resulting artifact into the repository.
#
# Usage:
#   tools/build-busybox.sh [--force] [--jobs N] [--out PATH] [--work-dir DIR]
#                          [--allow-drift]
#
# Exit codes: 0 success; 1 build/verify failure; 2 usage or environment error.

set -eu
umask 022

BUSYBOX_VERSION=1.36.1
BUSYBOX_URL="https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
# sha256 of the upstream tarball (downloaded from busybox.net over HTTPS;
# cross-checked against buildroot's package hash of the same release).
BUSYBOX_TARBALL_SHA256=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
# sha256 of the artifact this recipe produces with:
#   aarch64-linux-gnu-gcc (GCC) 16.2.0, make -j22, SOURCE_DATE_EPOCH=0
# A mismatch means the toolchain or the recipe changed; the caller must decide
# deliberately whether that is acceptable (--allow-drift) instead of silently
# shipping different PID-1 bytes.
REFERENCE_SHA256=ef5ffc6c553a2a855f410db102179f9f18b76d57b8c9ae4b1c693ae62b40d1f7
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
export SOURCE_DATE_EPOCH

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
force=0
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
work_dir=${TMPDIR:-/tmp}/liuqin-busybox-$BUSYBOX_VERSION
out_bin=
allow_drift=0

usage() {
	cat <<'EOF'
usage: tools/build-busybox.sh [options]

  --force            rebuild even if the output already exists and matches
  --jobs N           parallel make jobs (default: number of CPUs)
  --out PATH         artifact destination
                     (default: out/boot/toolchain/busybox-1.36.1-aarch64-static)
  --work-dir DIR     space-free scratch directory
                     (default: ${TMPDIR:-/tmp}/liuqin-busybox-1.36.1)
  --allow-drift      accept a binary whose sha256 differs from REFERENCE_SHA256
  -h, --help         show this help

The artifact destination must stay below <project>/out.  Nothing is installed
on the host and no device is touched.
EOF
}

die() { printf 'build-busybox: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--force) force=1 ;;
	--jobs)
		[ $# -ge 2 ] && [ -n "$2" ] || die "--jobs needs a value"
		jobs=$2
		shift
		;;
	--out)
		[ $# -ge 2 ] && [ -n "$2" ] || die "--out needs a value"
		out_bin=$2
		shift
		;;
	--work-dir)
		[ $# -ge 2 ] && [ -n "$2" ] || die "--work-dir needs a value"
		work_dir=$2
		shift
		;;
	--allow-drift) allow_drift=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

[ -n "$out_bin" ] || out_bin=$project_root/out/boot/toolchain/busybox-$BUSYBOX_VERSION-aarch64-static
case $jobs in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$jobs" -ge 1 ] || die "--jobs must be a positive integer"

case $work_dir in
*' '*) die "work dir contains a space ($work_dir); BusyBox cannot build there. Use --work-dir with a space-free path." ;;
esac
case $out_bin in
"$project_root"/out/*) ;;
*) die "artifact destination must be below $project_root/out: $out_bin" ;;
esac
case $out_bin in */../*|*/..|*/./*) die "artifact destination must not contain traversal" ;; esac

for tool in curl tar make gzip readelf sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
	die "missing cross compiler: ${CROSS_COMPILE}gcc (aarch64-linux-gnu-gcc is expected)"
fi
compiler_version=$("${CROSS_COMPILE}gcc" -dumpfullversion -dumpversion 2>/dev/null || "${CROSS_COMPILE}gcc" --version | head -n 1)
compiler_path=$(command -v "${CROSS_COMPILE}gcc")

out_dir=$(dirname -- "$out_bin")
mkdir -p "$out_dir"

if [ "$force" -eq 0 ] && [ -f "$out_bin" ] && [ ! -L "$out_bin" ]; then
	current_sha=$(sha256sum "$out_bin" | cut -d' ' -f1)
	if [ "$allow_drift" -eq 1 ] || [ "$current_sha" = "$REFERENCE_SHA256" ]; then
		printf 'build-busybox: up to date, sha256 %s: %s\n' "$current_sha" "$out_bin"
		exit 0
	fi
	printf 'build-busybox: existing artifact has sha256 %s (expected %s); rebuilding\n' \
		"$current_sha" "$REFERENCE_SHA256" >&2
fi

# ---------------------------------------------------------------------------
# 1. Source
# ---------------------------------------------------------------------------
src_dir=$work_dir/src
tarball=$work_dir/busybox-$BUSYBOX_VERSION.tar.bz2
mkdir -p "$work_dir"

if [ -f "$tarball" ]; then
	tarball_sha=$(sha256sum "$tarball" | cut -d' ' -f1)
	if [ "$tarball_sha" != "$BUSYBOX_TARBALL_SHA256" ]; then
		printf 'build-busybox: cached tarball hash mismatch, re-downloading\n' >&2
		rm -f "$tarball"
	fi
fi
if [ ! -f "$tarball" ]; then
	printf 'build-busybox: downloading %s\n' "$BUSYBOX_URL" >&2
	curl -fsSL --retry 3 --connect-timeout 20 -o "$tarball.part" "$BUSYBOX_URL" ||
		die "download failed: $BUSYBOX_URL"
	mv -f "$tarball.part" "$tarball"
fi
tarball_sha=$(sha256sum "$tarball" | cut -d' ' -f1)
[ "$tarball_sha" = "$BUSYBOX_TARBALL_SHA256" ] ||
	die "busybox-$BUSYBOX_VERSION.tar.bz2 sha256 mismatch: $tarball_sha != $BUSYBOX_TARBALL_SHA256"

rm -rf "$src_dir"
mkdir -p "$src_dir"
tar -xf "$tarball" -C "$src_dir" --no-same-owner
build_dir=$src_dir/busybox-$BUSYBOX_VERSION
[ -f "$build_dir/Makefile" ] || die "unexpected tarball layout: $build_dir/Makefile missing"

# ---------------------------------------------------------------------------
# 2. Configure
#    - CONFIG_STATIC=y: the initramfs has no dynamic loader.
#    - CONFIG_TC=n: BusyBox 1.36.1's tc applet references TCA_CBQ_*, enums that
#      current kernel headers no longer provide (CBQ scheduler removed), so the
#      build fails on a 2026 host.  tc is not used by initramfs/init.
# ---------------------------------------------------------------------------
(
	cd "$build_dir"
	make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
	sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' .config
	sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
	grep -qx 'CONFIG_STATIC=y' .config || die 'failed to enable CONFIG_STATIC'
	if grep -qx 'CONFIG_TC=y' .config; then
		die 'failed to disable CONFIG_TC (BusyBox 1.36.1 tc applet needs removed TCA_CBQ_* enums)'
	fi
	# Pinned build timestamp (see the header comment).
	grep -q '^# CONFIG_' .config || die 'defconfig did not produce a usable .config'
	printf 'build-busybox: building busybox %s with %s (jobs=%s)\n' \
		"$BUSYBOX_VERSION" "$compiler_version" "$jobs" >&2
	make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$jobs" busybox
)

built=$build_dir/busybox
[ -f "$built" ] || die "build produced no binary: $built"

# ---------------------------------------------------------------------------
# 3. Verify what was built
# ---------------------------------------------------------------------------
if ! LC_ALL=C readelf -h "$built" | grep -q 'Machine:.*AArch64'; then
	die 'built BusyBox is not an AArch64 ELF'
fi
if LC_ALL=C readelf -l "$built" | grep -q 'INTERP'; then
	die 'built BusyBox is dynamically linked (CONFIG_STATIC did not take effect)'
fi
if LC_ALL=C readelf -l "$built" 2>/dev/null | grep -q 'interpreter'; then
	die 'built BusyBox requests an ELF interpreter'
fi

# The init script and rescue shell need these applets.  Check the compiled-in
# applet table rather than trusting the source defaults.
required_applets='basename blockdev cat chmod chroot cp cttyhack cut dmesg findfs hostname ip kill killall ln losetup ls mkdir mount poweroff readlink reboot setsid sh sha256sum sleep stat switch_root sync telnetd udhcpd umount mdev'
applet_list=$out_dir/busybox-applets.txt
qemu=
for candidate in qemu-aarch64-static qemu-aarch64; do
	if command -v "$candidate" >/dev/null 2>&1; then
		qemu=$(command -v "$candidate")
		break
	fi
done
if [ -n "$qemu" ] && "$qemu" "$built" --list >"$applet_list" 2>/dev/null; then
	missing=
	for applet in $required_applets; do
		grep -qx "$applet" "$applet_list" || missing="$missing $applet"
	done
	[ -z "$missing" ] || die "BusyBox lacks required applet(s):$missing"
	applet_count=$(wc -l <"$applet_list")
	printf 'build-busybox: %s applets compiled in; required set present\n' "$applet_count" >&2
else
	# Do not invent a pass: record that the applet execution check was skipped.
	applet_list=
	printf 'build-busybox: warning: no working qemu-aarch64 found; applet execution check skipped\n' >&2
fi

built_sha=$(sha256sum "$built" | cut -d' ' -f1)
drift=0
if [ "$built_sha" != "$REFERENCE_SHA256" ]; then
	drift=1
	if [ "$allow_drift" -eq 0 ]; then
		printf 'build-busybox: built binary sha256 %s differs from the pinned reference %s\n' \
			"$built_sha" "$REFERENCE_SHA256" >&2
		printf 'build-busybox: refusing to install silently; re-run with --allow-drift after reviewing\n' >&2
		printf 'build-busybox: the difference usually means a different cross compiler or source change\n' >&2
		exit 1
	fi
	printf 'build-busybox: warning: toolchain drift accepted (sha256 %s)\n' "$built_sha" >&2
fi

# ---------------------------------------------------------------------------
# 4. Install artifact + audit sidecars
# ---------------------------------------------------------------------------
install -m 0755 "$built" "$out_bin"
cp -f "$build_dir/.config" "$out_dir/busybox-$BUSYBOX_VERSION.config"
sha256sum "$out_bin" >"$out_bin.sha256"

cat >"$out_dir/busybox-build-info.json" <<EOF
{
  "name": "busybox",
  "version": "$BUSYBOX_VERSION",
  "source_url": "$BUSYBOX_URL",
  "source_tarball_sha256": "$tarball_sha",
  "source_date_epoch": "$SOURCE_DATE_EPOCH",
  "config": "busybox-$BUSYBOX_VERSION.config",
  "build_host": "$(uname -srm)",
  "cross_compile": "$CROSS_COMPILE",
  "compiler_path": "$compiler_path",
  "compiler_version": "$compiler_version",
  "jobs": $jobs,
  "artifact": "$(basename -- "$out_bin")",
  "artifact_sha256": "$built_sha",
  "reference_sha256": "$REFERENCE_SHA256",
  "toolchain_drift_accepted": $drift,
  "applet_list": "$(basename -- "${applet_list:-none}")",
  "notes": "CONFIG_STATIC=y; CONFIG_TC disabled (BusyBox 1.36.1 tc references TCA_CBQ_* removed from current kernel headers); CONFIG_-timestamp pinned by SOURCE_DATE_EPOCH."
}
EOF

printf 'build-busybox: installed %s\n' "$out_bin"
printf 'build-busybox: sha256 %s\n' "$built_sha"
printf 'build-busybox: build info %s\n' "$out_dir/busybox-build-info.json"
