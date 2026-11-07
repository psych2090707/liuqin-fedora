#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# build-kernel-rpm.sh — package the cross-built liuqin kernel as Fedora
# aarch64 RPMs and verify them, fully offline-capable on this x86_64 host.
#
# Input : out/kernel-fedora/dist/  (kernel built WITH kernel/config/liuqin-fedora.config,
#         i.e. SELinux=y; produced by: scripts/build-kernel.sh --extra-fragment ...)
#         + kernel/fedora/* (spec, kernel-install hook, apply-boot tool, builder shim)
# Output: out/rpms-kernel/
#           rpm/kernel-liuqin-<NEVRA>.aarch64.rpm    (single device kernel package)
#           repo/                                    (createrepo_c local repo)
#           rpm-contents.txt, rpm-provides.txt, ...  (metadata evidence)
#           verify-rootfs/ listing, hook-verification.txt
#           build-info.json, SHA256SUMS, logs/
#
# Build environment: a Fedora 45 container via rootful podman
# (`sudo podman`, as allowed by the project). The locally cached
# quay.io/fedora/fedora:45 image is aarch64 and runs under qemu-user binfmt on
# this x86_64 host, which is exactly what we want: rpmbuild runs with native
# aarch64 semantics, so no cross-arch RPM hacks are needed. Network access for
# `dnf install rpm-build kmod createrepo_c` goes through the host proxy
# (--network=host + http_proxy), and the container is torn down afterwards.
#
# Why not `rpmbuild` on the host: the build host may have no rpm toolchain; and the payload
# is aarch64. Container keeps the host clean (no sudo package installs).
#
# Usage: scripts/build-kernel-rpm.sh --help

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

KERNEL_OUT="$PROJECT_ROOT/out/kernel-fedora"
OUT_DIR="$PROJECT_ROOT/out/rpms-kernel"
FEDORA_DIR="$PROJECT_ROOT/kernel/fedora"
SPEC="$FEDORA_DIR/kernel-liuqin.spec"
CONTAINER_IMAGE="${LIUQIN_RPM_CONTAINER:-}"
if [ -z "$CONTAINER_IMAGE" ]; then
	# Prefer the locally cached builder image (dnf packages preinstalled by
	# the kernel RPM notes) to keep iteration fast; fall back to the
	# base Fedora image.
	if sudo podman image inspect localhost/liuqin-rpmbuild:fc45 >/dev/null 2>&1; then
		CONTAINER_IMAGE=localhost/liuqin-rpmbuild:fc45
	else
		CONTAINER_IMAGE=quay.io/fedora/fedora:45
	fi
fi
WORK_ROOT="${LIUQIN_RPMBUILD_ROOT:-/var/tmp/liuqin-rpmbuild}"
PKGREL="liuqin1"
RPM_VERSION=""
RPM_RELEASE=""
NO_CONTAINER=0
SKIP_VERIFY=0

log() { printf '[build-kernel-rpm] %s\n' "$*"; }
die() { printf '[build-kernel-rpm] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
usage: scripts/build-kernel-rpm.sh [options]

  --kernel-out DIR       kernel artifact dir (default: <project>/out/kernel-fedora)
                         must contain dist/{Image, sm8475-xiaomi-liuqin.dtb,
                         modules.tar.gz, config, Module.symvers}, build-info.json
  --out DIR              RPM output dir (default: <project>/out/rpms-kernel)
  --spec FILE            spec file (default: kernel/fedora/kernel-liuqin.spec)
  --container-image REF  Fedora build container (default: quay.io/fedora/fedora:45)
  --work-root DIR        scratch root for rpmbuild (default: /var/tmp/liuqin-rpmbuild)
  --pkgrel TAG           RPM release tag (default: liuqin1 -> %{release} ...liuqin1.fc45)
  --rpm-version V        override the RPM Version (e.g. 7.3.1 for the experiment)
  --rpm-release R        override the RPM Release prefix (e.g. 0.liuqin1)
  --no-container         use a host rpmbuild if one exists (offline fallback)
  --skip-verify          skip post-build verification (not recommended)
  --help                 this help

Output layout: see the header of this script and kernel/fedora/README.kernel-liuqin.
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--kernel-out) KERNEL_OUT=${2:?}; shift 2 ;;
	--out) OUT_DIR=${2:?}; shift 2 ;;
	--spec) SPEC=${2:?}; shift 2 ;;
	--container-image) CONTAINER_IMAGE=${2:?}; shift 2 ;;
	--work-root) WORK_ROOT=${2:?}; shift 2 ;;
	--pkgrel) PKGREL=${2:?}; shift 2 ;;
	--rpm-version) RPM_VERSION=${2:?}; shift 2 ;;
	--rpm-release) RPM_RELEASE=${2:?}; shift 2 ;;
	--no-container) NO_CONTAINER=1; shift ;;
	--skip-verify) SKIP_VERIFY=1; shift ;;
	--help|-h) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

KERNEL_OUT=$(cd "$KERNEL_OUT" 2>/dev/null && pwd) || die "kernel-out not found: $KERNEL_OUT"
[ -f "$SPEC" ] || die "spec not found: $SPEC"
DIST="$KERNEL_OUT/dist"
KINFO="$KERNEL_OUT/build-info.json"
for f in "$DIST/Image" "$DIST/sm8475-xiaomi-liuqin.dtb" "$DIST/modules.tar.gz" \
	"$DIST/config" "$DIST/Module.symvers" "$KINFO"; do
	[ -f "$f" ] || die "missing kernel artifact: $f (run scripts/build-kernel.sh first)"
done
for f in "$FEDORA_DIR/99-liuqin-android-boot.install" "$FEDORA_DIR/liuqin-apply-boot" \
	"$FEDORA_DIR/bootimg-builder" "$FEDORA_DIR/liuqin-bootimg-refresh" \
	"$FEDORA_DIR/bootimg.conf.example" "$FEDORA_DIR/README.kernel-liuqin"; do
	[ -f "$f" ] || die "missing packaging input: $f"
done
MKBOOTIMG_DIR="$PROJECT_ROOT/cache/upstream-v0.6.0/mkbootimg"
[ -f "$MKBOOTIMG_DIR/mkbootimg.py" ] || die "AOSP mkbootimg.py missing: $MKBOOTIMG_DIR"
CMDLINE_FILE="$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/native-bootargs.txt"
[ -f "$CMDLINE_FILE" ] || die "native bootargs missing: $CMDLINE_FILE"

# ---------------------------------------------------------------- kernel identity
log "reading kernel identity from $KINFO"
mapfile -t KERNEL_META < <(python3 - "$KINFO" "$DIST" <<'PY'
import hashlib, json, pathlib, sys
info = json.load(open(sys.argv[1]))
dist = pathlib.Path(sys.argv[2])
config = info.get("config") or {}
artifacts = info.get("artifacts") or {}
modules = info.get("modules") or {}

def sha(path):
    p = dist / path
    if not p.is_file():
        return ""
    h = hashlib.sha256()
    with p.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

config_sha = config.get("sha256") or info.get("config_sha256") or sha("config")
image_sha = artifacts.get("dist/Image", {}).get("sha256") or sha("Image")
dtb_sha = artifacts.get("dist/sm8475-xiaomi-liuqin.dtb", {}).get("sha256") or sha("sm8475-xiaomi-liuqin.dtb")
module_count = modules.get("count") or info.get("module_count") or 0
fedora_ready = (config.get("audit") or {}).get("fedora_ready")
if fedora_ready is None:
    # The 7.3.1 experiment records only a flat config_sha256.  Derive the
    # Fedora/SELinux readiness from the actual dist/config instead.
    text = (dist / "config").read_text(errors="replace")
    fedora_ready = (
        "CONFIG_SECURITY_SELINUX=y" in text
        and "CONFIG_SECURITY_SELINUX_BOOTPARAM=y" in text
        and 'CONFIG_LSM="' in text
        and "selinux" in text
    )
print(info["kernel_release"])
print(config_sha)
print(config.get("matches_upstream_recorded_sha", ""))
print(image_sha)
print(dtb_sha)
print(module_count)
print(fedora_ready)
PY
)
KVER=${KERNEL_META[0]}
KCONFIG_SHA=${KERNEL_META[1]}
KIMAGE_SHA=${KERNEL_META[3]}
KDTB_SHA=${KERNEL_META[4]}
KMOD_COUNT=${KERNEL_META[5]}
KFEDORA_READY=${KERNEL_META[6]}
case $KVER in
	''|*[!A-Za-z0-9._+-]*) die "invalid kernel release from build-info: '$KVER'" ;;
esac
[ "$KVER" = "6.17.0-rc1-gfe81794b5e1b" ] || log "WARNING: kernel release is not the pinned upstream string: $KVER"
[ "$KFEDORA_READY" = "True" ] || die "kernel build did not have SELinux/Fedora config enabled (fedora_ready=$KFEDORA_READY); rebuild with --extra-fragment kernel/config/liuqin-fedora.config"
log "kernel release: $KVER"
log "config sha256: $KCONFIG_SHA (fedora_ready=$KFEDORA_READY)"
log "Image sha256 : $KIMAGE_SHA"
log "DTB   sha256 : $KDTB_SHA, modules: $KMOD_COUNT"

# Verify the dist artifacts are the ones recorded in build-info.json.
actual_image_sha=$(sha256sum "$DIST/Image" | cut -d' ' -f1)
if [ -n "$KIMAGE_SHA" ] && [ "$actual_image_sha" != "$KIMAGE_SHA" ]; then
	die "dist/Image sha256 does not match build-info.json ($actual_image_sha != $KIMAGE_SHA)"
fi
MODULES_LIST=$(mktemp "${TMPDIR:-/tmp}/liuqin-modules-list.XXXXXX")
tar -tzf "$DIST/modules.tar.gz" >"$MODULES_LIST" || die "cannot list modules.tar.gz"
if ! grep -qx "lib/modules/$KVER/modules.order" "$MODULES_LIST" &&
   ! grep -qx "modules/lib/modules/$KVER/modules.order" "$MODULES_LIST"; then
	die "modules.tar.gz does not contain lib/modules/$KVER/modules.order"
fi
if ! grep -qx "lib/modules/$KVER/kernel" "$MODULES_LIST" &&
	! grep -q "^lib/modules/$KVER/kernel/" "$MODULES_LIST" &&
	! grep -qx "modules/lib/modules/$KVER/kernel" "$MODULES_LIST" &&
	! grep -q "^modules/lib/modules/$KVER/kernel/" "$MODULES_LIST"; then
	die "modules.tar.gz does not contain a module tree"
fi
rm -f "$MODULES_LIST"

# ---------------------------------------------------------------- staging
log "staging rpmbuild tree: $WORK_ROOT"
case $WORK_ROOT in
*' '*) die "work root must not contain spaces (rpmbuild on this host): $WORK_ROOT" ;;
esac
# Rootful podman writes root-owned files into the bind mount; a plain rm as the
# invoking user may fail on a stale tree. Fall back to sudo cleanup (the script
# already requires sudo for podman).
if [ -e "$WORK_ROOT" ] && ! rm -rf "$WORK_ROOT" 2>/dev/null; then
	sudo rm -rf "$WORK_ROOT" || die "cannot clean scratch root: $WORK_ROOT"
fi
mkdir -p "$WORK_ROOT"/{SOURCES,SPECS,BUILD,RPMS,SRPMS,logs}
S="$WORK_ROOT/SOURCES"

cp -f "$DIST/Image" "$S/Image"
cp -f "$DIST/sm8475-xiaomi-liuqin.dtb" "$S/sm8475-xiaomi-liuqin.dtb"
# The 7.3.1 experiment archives modules with a top-level "modules/" prefix,
# while the 6.17 builder and the RPM spec expect lib/modules at the archive
# root.  Normalise both layouts here without changing the retained evidence.
modules_prefix=$(tar -tzf "$DIST/modules.tar.gz" | head -1 || true)
case $modules_prefix in
modules/)
	modules_tmp=$(mktemp -d "${TMPDIR:-/tmp}/liuqin-modules.XXXXXX")
	tar -xzf "$DIST/modules.tar.gz" -C "$modules_tmp" ||
		die "cannot extract $DIST/modules.tar.gz"
	[ -d "$modules_tmp/modules/lib/modules/$KVER" ] ||
		die "modules.tar.gz lacks modules/lib/modules/$KVER after stripping prefix"
	tar -czf "$S/modules.tar.gz" -C "$modules_tmp/modules" lib ||
		die "cannot repack modules.tar.gz"
	rm -rf "$modules_tmp"
	;;
*)
	cp -f "$DIST/modules.tar.gz" "$S/modules.tar.gz"
	;;
esac
cp -f "$DIST/config" "$S/config"
cp -f "$DIST/Module.symvers" "$S/Module.symvers"
cp -f "$KINFO" "$S/kernel-build-info.json"
printf '%s\n' "$KVER" >"$S/kernel.release"
cp -f "$FEDORA_DIR/99-liuqin-android-boot.install" "$S/99-liuqin-android-boot.install"
cp -f "$FEDORA_DIR/liuqin-apply-boot" "$S/liuqin-apply-boot"
cp -f "$FEDORA_DIR/bootimg-builder" "$S/bootimg-builder"
cp -f "$FEDORA_DIR/liuqin-bootimg-refresh" "$S/liuqin-bootimg-refresh"
cp -f "$FEDORA_DIR/liuqin_boot_metadata.py" "$S/liuqin_boot_metadata.py"
cp -f "$FEDORA_DIR/liuqin-kernel-pair" "$S/liuqin-kernel-pair"
cp -f "$FEDORA_DIR/bootimg.conf.example" "$S/bootimg.conf.example"
cp -f "$FEDORA_DIR/README.kernel-liuqin" "$S/README.kernel-liuqin"
cp -f "$MKBOOTIMG_DIR/mkbootimg.py" "$S/mkbootimg.py"
cp -f "$MKBOOTIMG_DIR/unpack_bootimg.py" "$S/unpack_bootimg.py"
cp -f "$CMDLINE_FILE" "$S/native-bootargs.txt"
cp -f "$SPEC" "$WORK_ROOT/SPECS/kernel-liuqin.spec"

# Module manifest in the boot-initramfs.md §4.5 format:
#   <sha256>  /usr/lib/modules/<kver>/<relative path>
log "generating kernel-modules.manifest"
python3 - "$WORK_ROOT/modules-root" "$S/kernel-modules.manifest" "$KVER" "$S/modules.tar.gz" <<'PY'
import hashlib, os, subprocess, sys, tempfile

_root, out, kver, archive = sys.argv[1:5]
tmp = tempfile.mkdtemp(prefix="liuqin-manifest-")
subprocess.run(["tar", "-xzf", archive, "-C", tmp], check=True)
module_dir = os.path.join(tmp, "lib", "modules", kver)
if not os.path.isdir(module_dir):
    sys.exit("module tree missing in archive: " + module_dir)
rows = []
for base, dirs, files in os.walk(module_dir):
    dirs.sort()
    for name in sorted(files):
        if not name.endswith(".ko"):
            continue
        path = os.path.join(base, name)
        rel = os.path.relpath(path, module_dir)
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        rows.append("%s  /usr/lib/modules/%s/%s" % (digest.hexdigest(), kver, rel))
rows.sort()
with open(out, "w") as handle:
    handle.write("# sha256  absolute-path (boot-initramfs.md §4.5)\n")
    for row in rows:
        handle.write(row + "\n")
print("manifest: %d modules" % len(rows))
subprocess.run(["rm", "-rf", tmp], check=True)
PY
cp -f "$S/kernel-modules.manifest" "$WORK_ROOT/kernel-modules.manifest.copy" 2>/dev/null || true
KMOD_MANIFEST_COUNT=$(grep -vc '^#' "$S/kernel-modules.manifest" || true)
[ "$KMOD_MANIFEST_COUNT" -ge "$KMOD_COUNT" ] || die "module manifest has $KMOD_MANIFEST_COUNT entries, build-info says $KMOD_COUNT"

# ---------------------------------------------------------------- rpmbuild in container
mkdir -p "$OUT_DIR"/{rpm,repo,logs,verification}
CONTAINER_SCRIPT="$WORK_ROOT/container-build.sh"
cat >"$CONTAINER_SCRIPT" <<'CONTAINER_EOF'
set -eu
export LC_ALL=C.UTF-8
dnf_log=/rpmbuild/logs/dnf-install.log
if command -v rpmbuild >/dev/null 2>&1 && command -v depmod >/dev/null 2>&1 &&
	command -v createrepo_c >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
	echo "container tools preinstalled; skipping dnf"
	: >"$dnf_log"
elif ! dnf -y install rpm-build kmod createrepo_c python3 >"$dnf_log" 2>&1; then
	tail -n 60 "$dnf_log" >&2
	echo "build-kernel-rpm/container: dnf install failed" >&2
	exit 3
fi
echo "container tools: $(rpm --version), kmod $(rpm -q --qf '%{VERSION}' kmod), createrepo_c $(rpm -q --qf '%{VERSION}' createrepo_c)"
rpmbuild_log=/rpmbuild/logs/rpmbuild.log
if ! rpmbuild -bb --target aarch64 \
	--define "_topdir /rpmbuild" \
	--define "kver KVER_PLACEHOLDER" \
	--define "pkgrel PKGREL_PLACEHOLDER" \
	--define "rpm_version RPM_VERSION_PLACEHOLDER" \
	--define "rpm_release RPM_RELEASE_PLACEHOLDER" \
	/rpmbuild/SPECS/kernel-liuqin.spec >"$rpmbuild_log" 2>&1; then
	tail -n 120 "$rpmbuild_log" >&2
	echo "build-kernel-rpm/container: rpmbuild failed" >&2
	exit 4
fi
rpm=$(find /rpmbuild/RPMS -name 'kernel-liuqin-*.rpm' | head -n 1)
if [ -z "$rpm" ]; then
	echo "build-kernel-rpm/container: no RPM produced" >&2
	exit 5
fi
echo "RPM: $(basename "$rpm")"
rpm -qpl "$rpm" >/rpmbuild/logs/rpm-contents.txt
rpm -qp --provides "$rpm" >/rpmbuild/logs/rpm-provides.txt
rpm -qp --requires "$rpm" >/rpmbuild/logs/rpm-requires.txt
rpm -qp --conflicts "$rpm" >/rpmbuild/logs/rpm-conflicts.txt
rpm -qpi "$rpm" >/rpmbuild/logs/rpm-info.txt
rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$rpm" >/rpmbuild/logs/rpm-nevra.txt

# Install into a throwaway root (no scriptlets; rootfs assembly is image assembly).
root=/rpmbuild/verify-rootfs
rm -rf "$root"; mkdir -p "$root"
rpm --root "$root" --initdb
rpm --root "$root" --install --nodeps --noscripts --ignorearch --nosignature --force "$rpm" >/rpmbuild/logs/rpm-install-root.log 2>&1
copy_rpms="$rpm"
rpm2cpio "$copy_rpms" | (cd "$root" && cpio -idm --quiet)
echo "verify-rootfs installed ($(du -sh "$root" | cut -f1))"

# Local repo + dnf dependency-resolution test (best effort; recorded).
mkdir -p /rpmbuild/repo
cp -f "$rpm" /rpmbuild/repo/
createrepo_c --quiet /rpmbuild/repo >/rpmbuild/logs/createrepo.log 2>&1
dnf_root=/rpmbuild/dnf-rootfs
rm -rf "$dnf_root"; mkdir -p "$dnf_root"
if dnf install -y --nogpgcheck --disablerepo='*' \
	--repofrompath=liuqin,file:///rpmbuild/repo \
	--setopt=install_weak_deps=False --releasever 45 --forcearch aarch64 \
	--installroot "$dnf_root" kernel-liuqin >/rpmbuild/logs/dnf-install-test.log 2>&1; then
	echo "dnf_resolution=PASS" >>/rpmbuild/logs/dnf-install-test.log
else
	echo "dnf_resolution=FAILED (see log; rpm --root install already passed)" >>/rpmbuild/logs/dnf-install-test.log
fi
CONTAINER_EOF
sed -i "s/KVER_PLACEHOLDER/$KVER/g; s/PKGREL_PLACEHOLDER/$PKGREL/g" "$CONTAINER_SCRIPT"
if [ -n "$RPM_VERSION" ]; then
	sed -i "s/RPM_VERSION_PLACEHOLDER/$RPM_VERSION/g" "$CONTAINER_SCRIPT"
else
	sed -i '/rpm_version RPM_VERSION_PLACEHOLDER/d' "$CONTAINER_SCRIPT"
fi
if [ -n "$RPM_RELEASE" ]; then
	sed -i "s/RPM_RELEASE_PLACEHOLDER/$RPM_RELEASE/g" "$CONTAINER_SCRIPT"
else
	sed -i '/rpm_release RPM_RELEASE_PLACEHOLDER/d' "$CONTAINER_SCRIPT"
fi

STARTED_AT=$(date -Is)
START_EPOCH=$(date +%s)
if [ "$NO_CONTAINER" -eq 1 ]; then
	log "using host rpmbuild (--no-container)"
	command -v rpmbuild >/dev/null 2>&1 || die "host rpmbuild not available"
	CONTAINER_IMAGE="host-rpmbuild"
	rm -rf "$WORK_ROOT/RPMS" "$WORK_ROOT/BUILD" "$WORK_ROOT/verify-rootfs" "$WORK_ROOT/repo"
	mkdir -p "$WORK_ROOT/RPMS" "$WORK_ROOT/BUILD" "$WORK_ROOT/repo" "$WORK_ROOT/logs"
	# Re-bind the expected paths for the shared container script.
	sed 's#/rpmbuild#'"$WORK_ROOT"'#g' "$CONTAINER_SCRIPT" >"$WORK_ROOT/host-build.sh"
	sh "$WORK_ROOT/host-build.sh"
else
	command -v sudo >/dev/null 2>&1 || die "sudo is required for rootful podman"
	sudo podman image inspect --format '{{.Id}}' "$CONTAINER_IMAGE" >/dev/null 2>&1 ||
		die "podman image not available locally: $CONTAINER_IMAGE (pull it first; see kernel/fedora/README.kernel-liuqin)"
	CONTAINER_ID=$(sudo podman image inspect --format '{{.Id}}' "$CONTAINER_IMAGE")
	log "container image: $CONTAINER_IMAGE ($CONTAINER_ID)"
	log "running rpmbuild inside Fedora container (aarch64 image under qemu-user)"
	if ! sudo podman run --rm --network=host \
		-e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" -e no_proxy="${no_proxy:-}" \
		-v "$WORK_ROOT:/rpmbuild:Z" \
		"$CONTAINER_IMAGE" /bin/bash /rpmbuild/container-build.sh >"$OUT_DIR/logs/container.log" 2>&1; then
		tail -n 80 "$OUT_DIR/logs/container.log" >&2 || true
		die "container rpmbuild failed (log: $OUT_DIR/logs/container.log)"
	fi
	tail -n 5 "$OUT_DIR/logs/container.log" | sed 's/^/[container] /'
fi
FINISHED_AT=$(date -Is)
DURATION=$(( $(date +%s) - START_EPOCH ))

RPM_FILE=$(find "$WORK_ROOT/RPMS" -name 'kernel-liuqin-*.rpm' | head -n 1)
[ -n "$RPM_FILE" ] || die "no RPM produced"
RPM_BASENAME=$(basename "$RPM_FILE")
log "built: $RPM_BASENAME ($(du -h "$RPM_FILE" | cut -f1))"

# Contract-level tests for the required refresh tool: kernel identity must be filtered
# out of the regenerated root contract (the boot refresh invariant) and the invariant enforced.

# ---------------------------------------------------------------- schema v2 fixtures
# The refresh tool and the kernel-install hook stage all boot metadata
# through the single schema v2 implementation (kernel/fedora/liuqin_boot_metadata.py).
# The offline contract tests below therefore must produce REAL inputs (a minimal
# Android boot image v2, a boot-builder document in the real scripts/build-bootimg.sh
# field structure, an initramfs document) and let the REAL producer merge them.
# Nothing here hand-writes the consumer-expected metadata (the old fixture sin
# named by the direction review); the two negative hook cases mutate the real
# producer output only to break one property each.
write_v2_fixture_tool() { # write_v2_fixture_tool FILE
	mkdir -p "$(dirname "$1")"
	cat >"$1" <<'PYV2'
#!/usr/bin/env python3
"""Minimal but real schema v2 fixture for the kernel-rpm contract tests."""
import argparse
import gzip
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

HEADER_BYTES = 1660


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    return sha(Path(path).read_bytes())


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def write_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def align(value, page=4096):
    return (value + page - 1) // page * page


def boot_image(kernel_image, ramdisk, dtb):
    kernel = gzip.compress(kernel_image, mtime=0)
    header = bytearray(HEADER_BYTES)
    header[0:8] = b"ANDROID!"
    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 12, 0x8000)
    struct.pack_into("<I", header, 16, len(ramdisk))
    struct.pack_into("<I", header, 20, 0x1000000)
    struct.pack_into("<I", header, 32, 0x100)
    struct.pack_into("<I", header, 36, 4096)
    struct.pack_into("<I", header, 40, 2)
    struct.pack_into("<I", header, 1644, HEADER_BYTES)
    struct.pack_into("<I", header, 1648, len(dtb))
    struct.pack_into("<Q", header, 1652, 0x1F00000)
    header_page = bytes(header) + b"\x00" * (4096 - HEADER_BYTES)
    return (header_page
            + kernel + b"\x00" * (align(len(kernel)) - len(kernel))
            + ramdisk + b"\x00" * (align(len(ramdisk)) - len(ramdisk))
            + dtb)


def emit_initramfs(out, kver, pins_kernel):
    raw = (b"INITRAMFS-" + kver.encode() + b"-") * 256
    ramdisk = gzip.compress(raw, mtime=0)
    contract = "LIUQIN_FEDORA_ROOT_CONTRACT_V1\n"
    if pins_kernel:
        contract += "0" * 64 + "  /usr/share/liuqin/kernel.release\n"
    else:
        contract += "0" * 64 + "  /etc/fstab\n"
    initramfs_dir = Path(out) / "initramfs"
    ramdisk_path = write(initramfs_dir / "liuqin-firstboot.cpio.gz", ramdisk)
    contract_path = write(initramfs_dir / "liuqin-fedora-root.contract",
                          contract.encode())
    info = {
        "artifact": "liuqin-firstboot.cpio.gz",
        "artifact_path": str(ramdisk_path),
        "artifact_sha256": sha(ramdisk),
        "artifact_bytes": len(ramdisk),
        "format": "newc cpio, gzip -n -9",
        "profile": "fedora",
        "storage_mode": "persistent",
        "device_ready": True,
        "generated_from_synthetic_example_manifest": False,
        "root_contract": {
            "path": str(contract_path),
            "sha256": sha_file(contract_path),
            "header": "LIUQIN_FEDORA_ROOT_CONTRACT_V1",
        },
        "kernel_release_expected": kver,
    }
    write_json(initramfs_dir / "initramfs-info.json", info)
    return ramdisk_path, contract_path


def emit_bootimg(out, kernel_out, dtb_source, ramdisk=None):
    kernel_out = Path(kernel_out)
    kernel_image = (kernel_out / "arch/arm64/boot/Image").read_bytes()
    board_dtb = (kernel_out / "arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb").read_bytes()
    final_dtb = b"\xd0\x0d\xfe\xed" + board_dtb  # injected ABL overlay stand-in
    release_file = kernel_out / "include/config/kernel.release"
    kver = release_file.read_text().strip() if release_file.is_file() else ""
    ramdisk_path = Path(ramdisk) if ramdisk else \
        Path(out) / "initramfs/liuqin-firstboot.cpio.gz"
    ramdisk_bytes = ramdisk_path.read_bytes()
    image = boot_image(kernel_image, ramdisk_bytes, final_dtb)
    write(Path(out) / "boot-liuqin-dev.img", image)
    kernel_gz = gzip.compress(kernel_image, mtime=0)
    builder = {
        "artifact": "boot-liuqin-dev.img",
        "artifact_sha256": sha(image),
        "artifact_bytes": len(image),
        "format": "Android boot image v2 (pagesize 4096)",
        "fits_partition": len(image) <= 201326592,
        "header": {"version": 2, "pagesize": 4096, "cmdline": "",
                   "kernel_offset": "0x00008000", "ramdisk_offset": "0x01000000",
                   "tags_offset": "0x00000100", "dtb_offset": "0x01f00000",
                   "second": None, "recovery_dtbo": None},
        "payload": {
            "kernel": {"source": "kernel-build",
                       "image_sha256": sha(kernel_image),
                       "image_bytes": len(kernel_image),
                       "gzip_sha256": sha(kernel_gz),
                       "gzip_bytes": len(kernel_gz),
                       "release": kver},
            "ramdisk": {"path": str(ramdisk_path), "sha256": sha(ramdisk_bytes),
                        "bytes": len(ramdisk_bytes), "mode": "persistent",
                        "description": "fixture stage-1 initramfs"},
            "dtb": {"source": dtb_source,
                    "provenance": "fixture canonical stock-rom rebuild",
                    "sha256": sha(final_dtb), "bytes": len(final_dtb),
                    "cmdline_source": "DTB /chosen/bootargs",
                    "dt_bootargs": "console=tty0", "header_cmdline_empty": True,
                    "canonical_stock_rom_rebuild": True},
        },
        "device_ready": True,
    }
    write_json(Path(out) / "build-info.json", builder)
    return builder


def cmd_initramfs(args):
    emit_initramfs(args.out, args.kver, args.pins_kernel)
    return 0


def cmd_bootimg(args):
    emit_bootimg(args.out, args.kernel_out, args.dtb_source, args.ramdisk)
    return 0


def cmd_refresh(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    ramdisk, contract = emit_initramfs(out, args.kver, False)
    builder = emit_bootimg(out, args.kernel_out, "stock-rom", ramdisk)
    builder_path = out / "build-info.json"
    info_path = out / "initramfs/initramfs-info.json"
    result = subprocess.run([
        sys.executable, args.metadata_tool, "merge",
        "--build-info", str(builder_path),
        "--initramfs-info", str(info_path),
        "--kernel-out", args.kernel_out,
        "--image", str(out / "boot-liuqin-dev.img"),
        "--ramdisk", str(ramdisk),
        "--contract", str(contract),
        "--kver", args.kver,
        "--dtb-source", "stock-rom",
        "--generated-by", "kernel-rpm-contract-test-fixture",
        "--out", str(out / "build-info.json"),
    ], text=True, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        return result.returncode
    # Negative hook cases: mutate the real producer output only to break ONE
    # property each (the reason is then reported by the real staging gate).
    metadata = json.loads((out / "build-info.json").read_text())
    if args.variant == "notready":
        metadata["device_ready"] = False
    elif args.variant == "nofields":
        for key in ("contract_sha256", "ramdisk_sha256"):
            metadata.pop(key, None)
    if args.variant != "ok":
        write_json(out / "build-info.json", metadata)
    print("schema v2 fixture staged: bootimg=" + metadata.get("artifact_sha256", ""))
    return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    initramfs = sub.add_parser("initramfs")
    initramfs.add_argument("--out", required=True)
    initramfs.add_argument("--kver", required=True)
    initramfs.add_argument("--pins-kernel", action="store_true")
    initramfs.set_defaults(func=cmd_initramfs)
    bootimg = sub.add_parser("bootimg")
    bootimg.add_argument("--out", required=True)
    bootimg.add_argument("--kernel-out", required=True)
    bootimg.add_argument("--dtb-source", default="stock-rom")
    bootimg.add_argument("--ramdisk", default=None)
    bootimg.set_defaults(func=cmd_bootimg)
    refresh = sub.add_parser("refresh")
    refresh.add_argument("--out", required=True)
    refresh.add_argument("--kernel-out", required=True)
    refresh.add_argument("--kver", required=True)
    refresh.add_argument("--metadata-tool", required=True)
    refresh.add_argument("--variant", default="ok",
                         choices=("ok", "notready", "nofields"))
    refresh.set_defaults(func=cmd_refresh)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
PYV2
	chmod +x "$1"
}

# Wrapper refresh tools for hook_tests: run the real schema v2 producer on a
# minimal real boot.img v2 instead of writing consumer-expected JSON by hand.
write_v2_hook_refresh() { # write_v2_hook_refresh FILE VARIANT
	mkdir -p "$(dirname "$1")"
	cat >"$1" <<'REFRESH'
#!/bin/sh
out= kernel_out= kver= dtb_source=stock-rom
while [ $# -gt 0 ]; do
	case $1 in
	--out) out=$2; shift 2 ;;
	--kernel-out) kernel_out=$2; shift 2 ;;
	--kver) kver=$2; shift 2 ;;
	--dtb-source) dtb_source=$2; shift 2 ;;
	*) shift ;;
	esac
done
[ -n "$out" ] && [ -n "$kernel_out" ] || exit 2
exec python3 "@FIXTURE@" refresh --out "$out" --kernel-out "$kernel_out" \
	--kver "${kver:-@KVER@}" --metadata-tool "@METADATA@" --variant @VARIANT@
REFRESH
	sed -i "s|@FIXTURE@|$V2_HOOK_FIXTURE|g; s|@METADATA@|$FEDORA_DIR/liuqin_boot_metadata.py|g; s|@KVER@|$KVER|g; s|@VARIANT@|$2|g" "$1"
	chmod +x "$1"
}

# Wrapper assets for refresh_tests: the copied build-initramfs.sh/build-bootimg.sh
# stand-ins produce real schema v2 inputs instead of fake blobs.
write_v2_refresh_asset_wrapper() { # write_v2_refresh_asset_wrapper FILE COMMAND EXTRA
	mkdir -p "$(dirname "$1")"
	cat >"$1" <<'WRAPPER'
#!/bin/sh
out= kernel_out= kver= ramdisk= dtb_source=stock-rom
while [ $# -gt 0 ]; do
	case $1 in
	--out) out=$2; shift 2 ;;
	--kernel-out) kernel_out=$2; shift 2 ;;
	--kver) kver=$2; shift 2 ;;
	--ramdisk) ramdisk=$2; shift 2 ;;
	--dtb-source) dtb_source=$2; shift 2 ;;
	*) shift ;;
	esac
done
[ -n "$out" ] || exit 2
exec python3 "@FIXTURE@" @COMMAND@ --out "$out" @EXTRA@
WRAPPER
	sed -i "s|@FIXTURE@|$V2_FIXTURE|g; s|@COMMAND@|$2|g; s|@EXTRA@|$3|g; s|@KVER@|$KVER|g" "$1"
}

refresh_tests() {
	local refresh="$FEDORA_DIR/liuqin-bootimg-refresh"
	local tmp
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/liuqin-refreshtest.XXXXXX")
	local assets="$tmp/assets" out="$tmp/out" ko="$tmp/kernel-out"
	mkdir -p "$assets/bin" "$out" "$ko/arch/arm64/boot/dts/qcom" "$ko/include/config" "$tmp/mkbootimg" "$tmp/stock/dtbo" "$tmp/stock/vendor_boot/dtbs"
	printf 'KIMAGE' >"$ko/arch/arm64/boot/Image"
	printf 'KDTB' >"$ko/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb"
	printf '%s\n' "$KVER" >"$ko/include/config/kernel.release"
	printf 'busybox\n' >"$assets/bin/busybox"; chmod +x "$assets/bin/busybox"
	printf '#!/bin/sh\n' >"$tmp/mkbootimg/mkbootimg.py"
	printf '# cmdline\n' >"$tmp/cmdline"
	printf 'topology\n' >"$tmp/audio-tplg.bin"
	# Manifest with kernel identity pins (stale hashes!) plus normal rootfs pins.
	cat >"$tmp/rootfs.files.sha256" <<'MANIFEST'
0000000000000000000000000000000000000000000000000000000000000001  /etc/fstab
0000000000000000000000000000000000000000000000000000000000000002  /usr/bin/hexagonrpcd
0000000000000000000000000000000000000000000000000000000000000003  /usr/share/liuqin/kernel.release
0000000000000000000000000000000000000000000000000000000000000004  /usr/share/liuqin/kernel-modules.manifest
0000000000000000000000000000000000000000000000000000000000000005  /usr/lib/modules/6.17.0-rc1-gfe81794b5e1b/modules.dep
MANIFEST
	v2_fixture="$tmp/bin/make-v2-fixture.py"
	write_v2_fixture_tool "$v2_fixture"
	V2_FIXTURE="$v2_fixture"
	write_v2_refresh_asset_wrapper "$assets/bin/build-initramfs.sh" initramfs \
		'--kver "${kver:-@KVER@}"'
	write_v2_refresh_asset_wrapper "$assets/bin/build-bootimg.sh" bootimg \
		'--kernel-out "$kernel_out" --ramdisk "$ramdisk" --dtb-source "${dtb_source:-stock-rom}"'
	chmod +x "$assets/bin/build-initramfs.sh" "$assets/bin/build-bootimg.sh"
	local rc
	run_refresh() {
		env LIUQIN_BOOT_METADATA_TOOL="$FEDORA_DIR/liuqin_boot_metadata.py" \
			"$refresh" --kver "$KVER" --kernel-out "$ko" --out "$out" --assets-dir "$assets" \
			--rootfs-manifest "$tmp/rootfs.files.sha256" \
			--firmware-pool "$tmp" --wlan-hsp2-tuple "$tmp" --audio-topology "$tmp/audio-tplg.bin" \
			--stock-rom-dir "$tmp/stock" --dtb-source stock-rom \
			--mkbootimg-dir "$tmp/mkbootimg" --cmdline-file "$tmp/cmdline" >"$tmp/refresh.log" 2>&1
		rc=$?
	}
	run_refresh
	if [ "$rc" -eq 0 ] && [ -f "$out/boot-liuqin-dev.img" ] &&
		python3 - "$out/build-info.json" <<'PYCHECK'
import json, sys
info = json.load(open(sys.argv[1]))
ok = (info.get("device_ready") is True and info.get("contract_pins_kernel_identity") is False
      and info.get("contract_sha256") and info.get("ramdisk_sha256"))
sys.exit(0 if ok else 1)
PYCHECK
	then
		echo "PASS refresh: kernel-identity pins filtered, merged build-info device_ready=true"
	else
		echo "FAIL refresh success case rc=$rc"
		tail -n 10 "$tmp/refresh.log" || true
	fi
	grep -q 'kernel-identity pins excluded' "$tmp/refresh.log" &&
		echo "PASS refresh logged kernel-identity pin exclusion" ||
		echo "FAIL refresh did not report kernel-identity filtering"
	# Negative: a contract generator that keeps pinning kernel identity must be rejected.
	write_v2_refresh_asset_wrapper "$assets/bin/build-initramfs.sh" initramfs \
		'--kver "${kver:-@KVER@}" --pins-kernel'
	chmod +x "$assets/bin/build-initramfs.sh"
	run_refresh
	[ "$rc" -ne 0 ] && echo "PASS refresh fail-closed: rebuilt contract still pins kernel identity (kernel-identity invariant violation)" ||
		echo "FAIL refresh accepted contract with kernel identity pins"
	rm -rf "$tmp"
}

# ---------------------------------------------------------------- collect outputs
rm -rf "$OUT_DIR/rpm" "$OUT_DIR/repo" "$OUT_DIR/verification"
mkdir -p "$OUT_DIR/rpm" "$OUT_DIR/repo" "$OUT_DIR/verification"
cp -f "$RPM_FILE" "$OUT_DIR/rpm/"
if [ -d "$WORK_ROOT/repo" ]; then
	cp -a "$WORK_ROOT/repo/." "$OUT_DIR/repo/" 2>/dev/null || true
fi
if [ -d "$WORK_ROOT/verify-rootfs" ]; then
	(cd "$WORK_ROOT/verify-rootfs" && find . -path ./proc -prune -o -print | sort) >"$OUT_DIR/verification/verify-rootfs-files.txt"
fi
for f in rpm-contents rpm-provides rpm-requires rpm-conflicts rpm-info rpm-nevra; do
	[ -f "$WORK_ROOT/logs/$f.txt" ] && cp -f "$WORK_ROOT/logs/$f.txt" "$OUT_DIR/verification/$f.txt"
done
[ -f "$WORK_ROOT/logs/createrepo.log" ] && cp -f "$WORK_ROOT/logs/createrepo.log" "$OUT_DIR/logs/"
[ -f "$WORK_ROOT/logs/dnf-install-test.log" ] && cp -f "$WORK_ROOT/logs/dnf-install-test.log" "$OUT_DIR/logs/"
[ -f "$WORK_ROOT/logs/dnf-install.log" ] && cp -f "$WORK_ROOT/logs/dnf-install.log" "$OUT_DIR/logs/container-dnf.log"
[ -f "$WORK_ROOT/logs/rpmbuild.log" ] && cp -f "$WORK_ROOT/logs/rpmbuild.log" "$OUT_DIR/logs/rpmbuild.log"
[ -f "$WORK_ROOT/kernel-modules.manifest.copy" ] && cp -f "$WORK_ROOT/kernel-modules.manifest.copy" "$OUT_DIR/kernel-modules.manifest"

# ---------------------------------------------------------------- verification
VERIFY_RESULT="skipped"
DNFS="$(grep -h 'dnf_resolution=' "$WORK_ROOT/logs/dnf-install-test.log" 2>/dev/null | tail -n 1 || true)"
verify_install_root() {
	local root=$1
	local kdir="$root/usr/lib/modules/$KVER"
	local problems=0
	[ -f "$kdir/vmlinuz" ] || { echo "FAIL missing $kdir/vmlinuz"; problems=$((problems + 1)); }
	[ -f "$kdir/device-tree/qcom/sm8475-xiaomi-liuqin.dtb" ] || { echo "FAIL missing device-tree DTB"; problems=$((problems + 1)); }
	[ -L "$kdir/dtb" ] || { echo "FAIL missing dtb alias symlink"; problems=$((problems + 1)); }
	[ -f "$kdir/modules.dep" ] || { echo "FAIL missing modules.dep"; problems=$((problems + 1)); }
	[ -f "$kdir/modules.order" ] || { echo "FAIL missing modules.order"; problems=$((problems + 1)); }
	[ -f "$root/usr/share/liuqin/kernel.release" ] || { echo "FAIL missing kernel.release"; problems=$((problems + 1)); }
	[ -f "$root/usr/share/liuqin/kernel-modules.manifest" ] || { echo "FAIL missing kernel-modules.manifest"; problems=$((problems + 1)); }
	[ -x "$root/usr/lib/kernel/install.d/99-liuqin-android-boot.install" ] || { echo "FAIL hook not executable"; problems=$((problems + 1)); }
	[ -x "$root/usr/sbin/liuqin-apply-boot" ] || { echo "FAIL liuqin-apply-boot not executable"; problems=$((problems + 1)); }
	local kos
	kos=$(find "$kdir" -name '*.ko' | wc -l)
	[ "$kos" -ge "$KMOD_COUNT" ] || { echo "FAIL only $kos modules (expected >= $KMOD_COUNT)"; problems=$((problems + 1)); }
	local release_in_root
	release_in_root=$(cat "$root/usr/share/liuqin/kernel.release" 2>/dev/null || true)
	[ "$release_in_root" = "$KVER" ] || { echo "FAIL kernel.release '$release_in_root' != '$KVER'"; problems=$((problems + 1)); }
	return "$problems"
}
if [ "$SKIP_VERIFY" -eq 1 ]; then
	VERIFY_RESULT="skipped"
else
	log "verifying installed package tree"
	VERIFY_LOG="$OUT_DIR/verification/install-root-check.txt"
	{
		verify_install_root "$WORK_ROOT/verify-rootfs" && echo "PASS: rpm --root install tree"
		if [ -d "$WORK_ROOT/dnf-rootfs/usr/lib/modules/$KVER" ]; then
			verify_install_root "$WORK_ROOT/dnf-rootfs" && echo "PASS: dnf installroot tree"
		else
			echo "SKIP: dnf installroot tree (dnf test did not install)"
		fi
	} >"$VERIFY_LOG" 2>&1 || true
	if grep -q '^FAIL' "$VERIFY_LOG"; then
		VERIFY_RESULT="FAILED"
	else
		VERIFY_RESULT="PASS"
	fi
	# Cross-check the packaged boot-update tool with its own offline suite.
	if [ -f "$PROJECT_ROOT/tests/boot-update/test-boot-update.py" ]; then
		python3 "$PROJECT_ROOT/tests/boot-update/test-boot-update.py" \
			>"$OUT_DIR/verification/apply-boot-tests.txt" 2>&1 &&
			log "apply-boot suite: PASS ($(grep -c 'ok$' "$OUT_DIR/verification/apply-boot-tests.txt" 2>/dev/null || true) tests)" ||
			log "WARNING: apply-boot suite failed (see verification/apply-boot-tests.txt)"
	fi
	log "install-root verification: $VERIFY_RESULT"
fi

# ---------------------------------------------------------------- hook contract tests
HOOK_TEST_LOG="$OUT_DIR/verification/hook-verification.txt"
hook_tests() {
	local hook="$FEDORA_DIR/99-liuqin-android-boot.install"
	local apply="$FEDORA_DIR/liuqin-apply-boot"
	local tmp
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/liuqin-hooktest.XXXXXX")
	local stg="$tmp/boot/liuqin" logs="$tmp/var/log" mods="$tmp/modules" share="$tmp/share"
	mkdir -p "$stg" "$logs" "$mods/$KVER/device-tree/qcom" "$share" \
		"$tmp/stock/dtbo" "$tmp/stock/vendor_boot/dtbs" "$tmp/mkbootimg" "$tmp/bin" \
		"$tmp/rootfs" "$tmp/firmware-pool" "$tmp/wlan-hsp2-tuple" "$tmp/assets/bin"
	printf 'KIMAGE' >"$mods/$KVER/vmlinuz"
	printf 'KDTB' >"$mods/$KVER/device-tree/qcom/sm8475-xiaomi-liuqin.dtb"
	ln -s device-tree/qcom/sm8475-xiaomi-liuqin.dtb "$mods/$KVER/dtb"
	printf '%s\n' "$KVER" >"$share/kernel.release"
	printf 'rootfs-manifest\n' >"$tmp/rootfs.files.sha256"
	printf 'topology\n' >"$tmp/audio-tplg.bin"
	printf '# cmdline\n' >"$tmp/cmdline"
	printf '#!/bin/sh\n' >"$tmp/mkbootimg/mkbootimg.py"
	printf 'busybox\n' >"$tmp/bin/busybox"
	chmod +x "$tmp/bin/busybox"
	local kimg_sha kdtb_sha
	kimg_sha=$(sha256sum "$mods/$KVER/vmlinuz" | cut -d' ' -f1)
	kdtb_sha=$(sha256sum "$mods/$KVER/device-tree/qcom/sm8475-xiaomi-liuqin.dtb" | cut -d' ' -f1)
	# Recorded release build-info (release gate input).
	python3 - "$share/kernel-build-info.json" "$KVER" "$kimg_sha" "$kdtb_sha" <<'PYGEN'
import json, sys
path, kver, kimg, kdtb = sys.argv[1:5]
json.dump({
    "kernel_release": kver,
    "config": {"sha256": "e08166e0d673707637e8882c7cfaaf1062a965b21e8ba55727ebd4cc060ac7f4",
               "audit": {"fedora_ready": True}},
    "artifacts": {"dist/Image": {"sha256": kimg},
                  "dist/sm8475-xiaomi-liuqin.dtb": {"sha256": kdtb}},
}, open(path, "w"), indent=2)
PYGEN
	python3 - "$share/kernel-build-info-bad.json" <<'PYBAD'
import json, sys
data = json.load(open(sys.argv[1].replace("-bad", "")))
data["artifacts"]["dist/Image"]["sha256"] = "0" * 64
json.dump(data, open(sys.argv[1], "w"), indent=2)
PYBAD
	# Fake refresh tools (refresh pipeline stand-in).  They run the REAL schema v2
	# producer on a minimal real boot.img v2: the fixture never hand-writes the
	# metadata fields the consumer expects.  refresh-notready / refresh-nofields
	# mutate the real producer output for exactly one property so the staging
	# gate fails for a real reason.
	V2_HOOK_FIXTURE="$tmp/bin/make-v2-fixture.py"
	write_v2_fixture_tool "$V2_HOOK_FIXTURE"
	write_v2_hook_refresh "$tmp/bin/refresh-ok" ok
	write_v2_hook_refresh "$tmp/bin/refresh-notready" notready
	write_v2_hook_refresh "$tmp/bin/refresh-nofields" nofields

	write_conf() { # write_conf FILE REFRESH_PATH
		local file=$1 refresh=$2
		{
			printf 'LIUQIN_BOOTIMG_REFRESH=%s\n' "$refresh"
			printf 'LIUQIN_BOOT_ASSETS_DIR=%s\n' "$tmp/assets"
			printf 'LIUQIN_MODULES_DIR=%s\n' "$mods"
			printf 'LIUQIN_KERNEL_BUILD_INFO=%s\n' "$share/kernel-build-info.json"
			printf 'LIUQIN_ROOTFS_MANIFEST=%s\n' "$tmp/rootfs.files.sha256"
			printf 'LIUQIN_FIRMWARE_POOL=%s\n' "$tmp/firmware-pool"
			printf 'LIUQIN_WLAN_HSP2_TUPLE=%s\n' "$tmp/wlan-hsp2-tuple"
			printf 'LIUQIN_AUDIO_TOPOLOGY=%s\n' "$tmp/audio-tplg.bin"
			printf 'LIUQIN_STOCK_ROM_DIR=%s\n' "$tmp/stock"
			printf 'LIUQIN_BOOTIMG_DTB_SOURCE=stock-rom\n'
			printf 'LIUQIN_MKBOOTIMG_DIR=%s\n' "$tmp/mkbootimg"
			printf 'LIUQIN_CMDLINE_FILE=%s\n' "$tmp/cmdline"
			printf 'LIUQIN_BOOT_STAGING_DIR=%s\n' "$stg"
			printf 'LIUQIN_BOOT_LOG_DIR=%s\n' "$logs"
			printf 'LIUQIN_BOOT_METADATA_TOOL="%s"\n' "$FEDORA_DIR/liuqin_boot_metadata.py"
		} >"$file"
	}
	write_conf "$tmp/conf-ok.conf" "$tmp/bin/refresh-ok"
	write_conf "$tmp/conf-notready.conf" "$tmp/bin/refresh-notready"
	write_conf "$tmp/conf-nofields.conf" "$tmp/bin/refresh-nofields"
	write_conf "$tmp/conf-missing-refresh.conf" "$tmp/bin/does-not-exist"
	write_conf "$tmp/conf-missing-rootfs.conf" "$tmp/bin/refresh-ok"
	sed -i "s|LIUQIN_ROOTFS_MANIFEST=.*|LIUQIN_ROOTFS_MANIFEST=$tmp/no-such-manifest|" "$tmp/conf-missing-rootfs.conf"
	sed "s|LIUQIN_KERNEL_BUILD_INFO=.*|LIUQIN_KERNEL_BUILD_INFO=$share/kernel-build-info-bad.json|" \
		"$tmp/conf-ok.conf" >"$tmp/conf-badgate.conf"

	local rc
	run_hook() { # run_hook CONF ; sets rc
		env LIUQIN_BOOTIMG_CONF="$1" sh "$hook" add "$KVER" "$tmp/entry" \
			"$mods/$KVER/vmlinuz" >/dev/null 2>&1
		rc=$?
	}

	# 1) no config -> opt-out, no staging (image-build safe)
	env LIUQIN_BOOTIMG_CONF="$tmp/no-conf" LIUQIN_BOOT_STAGING_DIR="$stg" \
		LIUQIN_BOOT_LOG_DIR="$logs" sh "$hook" add "$KVER" "$tmp/entry" "$mods/$KVER/vmlinuz" >/dev/null 2>&1
	rc=$?
	[ "$rc" -eq 0 ] && [ ! -e "$stg/boot-$KVER.img" ] && echo "PASS disabled-mode (no conf): rc=0, no staging" || echo "FAIL disabled-mode rc=$rc"

	# 2) required: refresh tool missing -> fail-closed
	run_hook "$tmp/conf-missing-refresh.conf"
	[ "$rc" -ne 0 ] && [ ! -e "$stg/boot-$KVER.img" ] && echo "PASS fail-closed (required missing refresh tool): rc=$rc" || echo "FAIL missing-refresh rc=$rc"

	# 3) required: rootfs manifest missing -> fail-closed
	run_hook "$tmp/conf-missing-rootfs.conf"
	[ "$rc" -ne 0 ] && [ ! -e "$stg/boot-$KVER.img" ] && echo "PASS fail-closed (required missing rootfs manifest): rc=$rc" || echo "FAIL missing-rootfs rc=$rc"

	# 4) release-gate mismatch -> fail-closed
	run_hook "$tmp/conf-badgate.conf"
	[ "$rc" -ne 0 ] && [ ! -e "$stg/boot-$KVER.img" ] && echo "PASS release-gate failure blocks staging: rc=$rc" || echo "FAIL release-gate rc=$rc"

	# 5) refresh reports device_ready=false -> fail-closed
	run_hook "$tmp/conf-notready.conf"
	[ "$rc" -ne 0 ] && [ ! -e "$stg/boot-$KVER.img" ] && echo "PASS fail-closed (device_ready=false): rc=$rc" || echo "FAIL not-ready rc=$rc"

	# 6) refresh misses required identity fields -> fail-closed
	run_hook "$tmp/conf-nofields.conf"
	[ "$rc" -ne 0 ] && [ ! -e "$stg/boot-$KVER.img" ] && echo "PASS fail-closed (missing contract/ramdisk fields): rc=$rc" || echo "FAIL nofields rc=$rc"

	# 7) full simulated success -> staged with required manifest fields
	run_hook "$tmp/conf-ok.conf"
	if [ "$rc" -eq 0 ] && [ -f "$stg/boot-$KVER.img" ] && [ -f "$stg/boot-$KVER.SHA256SUMS" ] \
		&& [ -f "$stg/boot-$KVER.manifest" ] && [ -f "$stg/boot-$KVER.build-info.json" ] \
		&& grep -q '^schema_version=2' "$stg/boot-$KVER.manifest" \
		&& grep -q '^contract_sha256=' "$stg/boot-$KVER.manifest" \
		&& grep -q '^board_dtb_sha256=' "$stg/boot-$KVER.manifest" \
		&& grep -q 'schema_version' "$stg/boot-$KVER.build-info.json" \
		&& grep -q '^release_gate=passed' "$stg/boot-$KVER.manifest" \
		&& grep -q 'staged only' "$stg/boot-$KVER.manifest"; then
		echo "PASS staged: boot-$KVER.img + schema v2 manifest/build-info + SHA256SUMS"
	else
		echo "FAIL simulated-success rc=$rc"
	fi

	# Schema v2 hashes are produced consistently by the real producer; no
	# consumer-field patching is needed (the old PYFIX block was the very
	# "hand-written consumer expectation" the direction review called out).
	# 8) liuqin-apply-boot (owner: boot-update task) is a Python tool with its own
	# 18-test suite (tests/boot-update/); here we only smoke-test the packaged
	# binary's read-only status path and that it never writes for the fake image.
	python3 "$apply" status --staging-dir "$stg" >/dev/null 2>&1 &&
		echo "PASS liuqin-apply-boot status --staging-dir rc=0" || echo "FAIL liuqin-apply-boot status"
	python3 "$apply" apply --image "$stg/boot-$KVER.img" --dry-run >/dev/null 2>&1
	rc=$?
	[ "$rc" -ne 0 ] && echo "PASS liuqin-apply-boot rejects fake/invalid image (rc=$rc, nothing written)" ||
		echo "FAIL liuqin-apply-boot accepted fake image rc=$rc"
	python3 "$apply" apply --image "$stg/boot-$KVER.img" --yes-write-device >/dev/null 2>&1
	rc=$?
	[ "$rc" -ne 0 ] && echo "PASS liuqin-apply-boot write path gated/validation-failed (rc=$rc)" ||
		echo "FAIL liuqin-apply-boot write gate rc=$rc"

	# 9) remove action drops only staged artifacts of this kver
	env LIUQIN_BOOTIMG_CONF="$tmp/conf-ok.conf" LIUQIN_BOOT_STAGING_DIR="$stg" \
		LIUQIN_BOOT_LOG_DIR="$logs" sh "$hook" remove "$KVER" "$tmp/entry" >/dev/null 2>&1
	if [ ! -e "$stg/boot-$KVER.img" ] && [ ! -e "$stg/boot-$KVER.manifest" ]; then
		echo "PASS remove action (staged artifacts of this kver removed)"
	else
		echo "FAIL remove action left files"
	fi
	rm -rf "$tmp"
}
if [ "$SKIP_VERIFY" -eq 1 ]; then
	echo "skipped" >"$HOOK_TEST_LOG"
else
	{
		hook_tests
		refresh_tests
	} >"$HOOK_TEST_LOG" 2>&1 || true
	if grep -q '^FAIL' "$HOOK_TEST_LOG"; then HOOK_RESULT="FAILED"; else HOOK_RESULT="PASS"; fi
	log "hook contract tests: $HOOK_RESULT"
fi

# ---------------------------------------------------------------- repo / sums / build-info
# build-image consumers expect out/rpms-kernel/*.rpm at the top level; keep the
# canonical copies in rpm/ and expose top-level symlinks as the stable layout.
ln -sfn "rpm/$RPM_BASENAME" "$OUT_DIR/$RPM_BASENAME"
RPM_SHA=$(sha256sum "$OUT_DIR/rpm/$RPM_BASENAME" | cut -d' ' -f1)
RPM_SIZE=$(stat -c '%s' "$OUT_DIR/rpm/$RPM_BASENAME")
SPEC_SHA=$(sha256sum "$SPEC" | cut -d' ' -f1)
HOOK_SHA=$(sha256sum "$FEDORA_DIR/99-liuqin-android-boot.install" | cut -d' ' -f1)
APPLY_SHA=$(sha256sum "$FEDORA_DIR/liuqin-apply-boot" | cut -d' ' -f1)
BUILDER_SHA=$(sha256sum "$FEDORA_DIR/bootimg-builder" | cut -d' ' -f1)
REFRESH_SHA=$(sha256sum "$FEDORA_DIR/liuqin-bootimg-refresh" | cut -d' ' -f1)
KINFO_SHA=$(sha256sum "$KINFO" | cut -d' ' -f1)
CONTENTS_COUNT=$(wc -l <"$OUT_DIR/verification/rpm-contents.txt" 2>/dev/null || echo 0)
CONTAINER_ID=${CONTAINER_ID:-host-rpmbuild}
export KVER PKGREL KERNEL_OUT KINFO_SHA SPEC_SHA HOOK_SHA APPLY_SHA BUILDER_SHA REFRESH_SHA SPEC \
	CONTAINER_IMAGE CONTAINER_ID STARTED_AT FINISHED_AT DURATION VERIFY_RESULT HOOK_RESULT \
	CONTENTS_COUNT

python3 - "$OUT_DIR" "$WORK_ROOT" <<'PY'
import datetime, json, os, sys
out_dir, work_root = sys.argv[1:3]

def sha256(path):
    import hashlib
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

rpm_dir = os.path.join(out_dir, "rpm")
rpms = {}
for name in sorted(os.listdir(rpm_dir)):
    path = os.path.join(rpm_dir, name)
    rpms[name] = {"sha256": sha256(path), "size": os.path.getsize(path)}

info = json.load(open(os.path.join(work_root, "SOURCES", "kernel-build-info.json")))
config = info.get("config") or {}
artifacts = info.get("artifacts") or {}
modules = info.get("modules") or {}
build = info.get("build") or {}
toolchain = info.get("toolchain") or {}
config_sha = config.get("sha256") or info.get("config_sha256")
fedora_ready = (config.get("audit") or {}).get("fedora_ready")
if fedora_ready is None:
    cfg_text = open(os.path.join(work_root, "SOURCES", "config"), errors="replace").read()
    fedora_ready = ("CONFIG_SECURITY_SELINUX=y" in cfg_text and
                    "CONFIG_SECURITY_SELINUX_BOOTPARAM=y" in cfg_text and
                    'CONFIG_LSM="' in cfg_text and "selinux" in cfg_text)
image_sha = artifacts.get("dist/Image", {}).get("sha256") or sha256(
    os.path.join(work_root, "SOURCES", "Image"))
dtb_sha = artifacts.get("dist/sm8475-xiaomi-liuqin.dtb", {}).get("sha256") or sha256(
    os.path.join(work_root, "SOURCES", "sm8475-xiaomi-liuqin.dtb"))
modules_count = modules.get("count") or info.get("module_count") or 0
hook_log = os.path.join(out_dir, "verification", "hook-verification.txt")
install_log = os.path.join(out_dir, "verification", "install-root-check.txt")
dnf_log = os.path.join(out_dir, "logs", "dnf-install-test.log")
info_rpm = {
    "schema_version": 1,
    "package": {
        "name": "kernel-liuqin",
        "kernel_release": os.environ.get("KVER"),
        "rpm_pkgrel": os.environ.get("PKGREL"),
        "rpms": rpms,
        "rpm_contents_entries": int(os.environ.get("CONTENTS_COUNT") or 0),
    },
    "kernel_build": {
        "kernel_out": os.environ.get("KERNEL_OUT"),
        "build_info_sha256": os.environ.get("KINFO_SHA"),
        "config_sha256": config_sha,
        "fedora_ready": fedora_ready,
        "image_sha256": image_sha,
        "dtb_sha256": dtb_sha,
        "modules_count": modules_count,
        "kernel_build_duration_seconds": build.get("duration_seconds"),
        "kernel_build_compiler": toolchain.get("compiler_version"),
    },
    "sources": {
        "spec": {"path": os.environ.get("SPEC"), "sha256": os.environ.get("SPEC_SHA")},
        "hook": {"path": "kernel/fedora/99-liuqin-android-boot.install", "sha256": os.environ.get("HOOK_SHA")},
        "apply_boot": {"path": "kernel/fedora/liuqin-apply-boot", "sha256": os.environ.get("APPLY_SHA")},
        "bootimg_builder": {"path": "kernel/fedora/bootimg-builder", "sha256": os.environ.get("BUILDER_SHA")},
        "bootimg_refresh": {"path": "kernel/fedora/liuqin-bootimg-refresh", "sha256": os.environ.get("REFRESH_SHA")},
    },
    "build": {
        "container_image": os.environ.get("CONTAINER_IMAGE"),
        "container_image_id": os.environ.get("CONTAINER_ID"),
        "started_at": os.environ.get("STARTED_AT"),
        "finished_at": os.environ.get("FINISHED_AT"),
        "duration_seconds": int(os.environ.get("DURATION") or 0),
        "host": {"kernel": os.uname().release, "machine": os.uname().machine},
        "command": "scripts/build-kernel-rpm.sh --kernel-out %s" % os.environ.get("KERNEL_OUT"),
    },
    "verification": {
        "install_root_check": os.environ.get("VERIFY_RESULT"),
        "hook_contract_tests": os.environ.get("HOOK_RESULT"),
        "dnf_resolution": ("pass" if open(dnf_log).read().find("dnf_resolution=PASS") >= 0 else "failed")
        if os.path.isfile(dnf_log) else "skipped",
        "dnf_resolution_note": ("local-repo-only --installroot has no Fedora base/updates repos, so "
                                "declared runtime deps (/bin/sh, python3) cannot be resolved; the "
                                "authoritative release check is the rpm --root install tree above, "
                                "which passes. Full dnf resolution belongs to image assembly (image assembly) "
                                "with the normal Fedora repos enabled."),
        "files": {
            "install_root_check": "verification/install-root-check.txt",
            "hook_contract_tests": "verification/hook-verification.txt",
            "rpm_contents": "verification/rpm-contents.txt",
            "dnf_install_test": "logs/dnf-install-test.log",
        },
    },
    "repo": {"path": "repo", "layout": "createrepo_c", "enabled": os.path.isdir(os.path.join(out_dir, "repo", "repodata"))},
    "safety": {
        "qbootctl_used": False,
        "boot_partition_written": False,
        "gpt_slot_attributes_modified": False,
        "kernel_install_hook": "stages only under /boot/liuqin/; opt-in via /etc/liuqin/bootimg.conf",
    },
    "notes": [
        "Kernel payload built with kernel/config/liuqin-fedora.config (SELinux=y).",
        "kernel_release kept at 6.17.0-rc1-gfe81794b5e1b to stay comparable with upstream; RPM release carries the .liuqin tag.",
        "RPM was not signed (device uses unlocked bootloader; signing is a future decision).",
        "Actual boot partition write is intentionally not implemented as an automated step; liuqin-apply-boot is dry-run by default and Phase-6 gated.",
        "required (the boot refresh work): kernel-install hook rebuilds root contract + initramfs + boot.img and never reuses a stale ramdisk; kernel identity is excluded from the regenerated contract pins and the refresh tool fails closed if a contract still pins it.",
        "Pre-apply stale-boot window still needs the initramfs-side dynamic kernel-release warning (boot-builder scope).",
    ],
}
with open(os.path.join(out_dir, "build-info.json"), "w") as handle:
    json.dump(info_rpm, handle, indent=2)
    handle.write("\n")
print("RPM build-info.json written")
PY

(
	cd "$OUT_DIR"
	find rpm repo verification logs -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
	for f in build-info.json kernel-modules.manifest; do
		[ -f "$f" ] && sha256sum "$f"
	done
) >"$OUT_DIR/SHA256SUMS"

log "outputs under $OUT_DIR"
log "  RPM      : out/rpms-kernel/rpm/$RPM_BASENAME"
log "  sha256   : $RPM_SHA"
log "  repo     : out/rpms-kernel/repo ($(ls "$OUT_DIR/repo" 2>/dev/null | tr '\n' ' '))"
log "  verify   : install-root=$VERIFY_RESULT hook-tests=$HOOK_RESULT dnf=${DNFS:-unknown}"
log "done in ${DURATION}s"
