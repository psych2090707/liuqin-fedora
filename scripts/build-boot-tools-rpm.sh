#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# build-boot-tools-rpm.sh — build and offline-verify the on-device boot asset
# package `liuqin-boot-tools`.
#
# Inputs (all local, no network needed for the build itself):
#   scripts/build-initramfs.sh, scripts/build-bootimg.sh      (boot-builder, MIT)
#   initramfs/{init,etc}, tools/build-root-contract.py,
#   tools/build-busybox.sh, tools/examples/…                  (boot-builder, MIT)
#   upstream/xiaomipad-6pro-mainline subset: initramfs/init, device/{native-bootargs,
#     liuqin-abl-boot-overlay.dts, charger-mode/*, boot/*}, tools/lib/*, kernel/source.json
#   cache/upstream-v0.6.0/mkbootimg/{mkbootimg,unpack_bootimg}.py   (AOSP, Apache-2.0)
#   out/boot/toolchain/busybox-1.36.1-aarch64-static           (pinned artifact)
#   out/kernel-fedora/dist + out/rpms-kernel/rpm + out/rpms/*.rpm (verification)
#
# Outputs: $LIUQIN_BOOT_TOOLS_OUT_DIR (default: out/rpms-boot)
#   rpm/liuqin-boot-tools-<NEVRA>.aarch64.rpm
#   repo/ (createrepo_c local repo)
#   verification/{rpm-contents.txt,offline-validation.txt,install-tree.txt,…}
#   verification/repo-consistency.txt  (packaged tools == repository, hard gate)
#   logs/, build-info.json, SHA256SUMS
#
# The RPM is built inside the cached aarch64 Fedora 45 builder image
# (localhost/liuqin-rpmbuild:fc45, qemu-user on this x86_64 host).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

OUT_DIR="${LIUQIN_BOOT_TOOLS_OUT_DIR:-$PROJECT_ROOT/out/rpms-boot}"
WORK_ROOT="${LIUQIN_BOOT_TOOLS_BUILD_ROOT:-/var/tmp/liuqin-boot-tools-build}"
CONTAINER_IMAGE="${LIUQIN_RPM_CONTAINER:-}"
VERSION="0.6.0"

KERNEL_OUT="${LIUQIN_BOOT_TOOLS_KERNEL_OUT:-$PROJECT_ROOT/out/kernel-fedora}"
KERNEL_RPM_DIR="${LIUQIN_BOOT_TOOLS_KERNEL_RPM_DIR:-$PROJECT_ROOT/out/rpms-kernel/rpm}"
STOCK_ROM_DIR="${LIUQIN_BOOT_TOOLS_STOCK_ROM_DIR:-}"
DEVICE_RPM_DIR="${LIUQIN_BOOT_TOOLS_DEVICE_RPM_DIR:-$PROJECT_ROOT/out/rpms}"
BOOT_TOOLS_DIR="$PROJECT_ROOT/packaging/boot-tools"
BUSYBOX="$PROJECT_ROOT/out/boot/toolchain/busybox-1.36.1-aarch64-static"
PUBLISHED_BOOTIMG="$PROJECT_ROOT/cache/upstream-v0.6.0/boot.img"
MKBOOTIMG_DIR="$PROJECT_ROOT/cache/upstream-v0.6.0/mkbootimg"

log() { printf '[build-boot-tools-rpm] %s\n' "$*"; }
die() { printf '[build-boot-tools-rpm] ERROR: %s\n' "$*" >&2; exit 1; }

[ -z "$CONTAINER_IMAGE" ] && {
	if sudo podman image inspect localhost/liuqin-rpmbuild:fc45 >/dev/null 2>&1; then
		CONTAINER_IMAGE=localhost/liuqin-rpmbuild:fc45
	else
		CONTAINER_IMAGE=quay.io/fedora/fedora:45
	fi
}

# Each reviewed RPM build needs a distinct artifact/work directory. Refuse to
# delete an earlier build (including the historical default) as a side effect.
[[ "$OUT_DIR" = /* ]] || OUT_DIR="$PROJECT_ROOT/$OUT_DIR"
[[ "$WORK_ROOT" = /* ]] || die "LIUQIN_BOOT_TOOLS_BUILD_ROOT must be absolute"
[ ! -e "$OUT_DIR" ] || die "output already exists; set LIUQIN_BOOT_TOOLS_OUT_DIR to a new directory"
[ ! -e "$WORK_ROOT" ] || die "work root already exists; set LIUQIN_BOOT_TOOLS_BUILD_ROOT to a new directory"
mkdir -p "$OUT_DIR"/{rpm,repo,verification,logs}
log "work root: $WORK_ROOT"
mkdir -p "$WORK_ROOT/assets" "$WORK_ROOT/rpmbuild"/{SOURCES,SPECS,RPMS,BUILD,SRPMS}

# ---------------------------------------------------------------- inputs
for f in "$PROJECT_ROOT/scripts/build-initramfs.sh" "$PROJECT_ROOT/scripts/build-bootimg.sh" \
	"$PROJECT_ROOT/overlays/boot/abl-symbols-dtc-labels.patch" \
	"$PROJECT_ROOT/overlays/boot/liuqin-bootargs.txt" \
	"$PROJECT_ROOT/initramfs/init" "$PROJECT_ROOT/tools/build-root-contract.py" \
	"$PROJECT_ROOT/tools/build-busybox.sh" "$BUSYBOX" \
	"$MKBOOTIMG_DIR/mkbootimg.py" "$MKBOOTIMG_DIR/unpack_bootimg.py" \
	"$BOOT_TOOLS_DIR/liuqin-boot-tools.spec" "$BOOT_TOOLS_DIR/bootimg.conf.default" \
	"$BOOT_TOOLS_DIR/NOTICE" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/initramfs/init" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/native-bootargs.txt" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/liuqin-abl-boot-overlay.dts" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/boot/liuqin-mark-slot-successful.c" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-power-key.c" \
	"$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-exit.c" \
	"$KERNEL_RPM_DIR" "$PUBLISHED_BOOTIMG"; do
	if [ -d "$f" ] || [ -f "$f" ]; then :; else
		die "missing input: $f"
	fi
done
ls "$KERNEL_OUT/dist/Image" >/dev/null 2>&1 || die "missing kernel build: $KERNEL_OUT/dist (run scripts/build-kernel.sh --out out/kernel-fedora --extra-fragment …)"
ls "$KERNEL_RPM_DIR"/kernel-liuqin-*.rpm >/dev/null 2>&1 || die "missing kernel RPM in $KERNEL_RPM_DIR"

A="$WORK_ROOT/assets"
copy() { # copy SRC DEST_REL
	mkdir -p "$A/$(dirname -- "$2")"
	cp -a -- "$1" "$A/$2"
}
copy "$PROJECT_ROOT/scripts/build-initramfs.sh" scripts/build-initramfs.sh
copy "$PROJECT_ROOT/scripts/build-bootimg.sh" scripts/build-bootimg.sh
copy "$PROJECT_ROOT/overlays/boot/abl-symbols-dtc-labels.patch" overlays/boot/abl-symbols-dtc-labels.patch
copy "$PROJECT_ROOT/initramfs/init" initramfs/init
copy "$PROJECT_ROOT/initramfs/etc" initramfs/etc
copy "$PROJECT_ROOT/initramfs/README.md" initramfs/README.md
copy "$PROJECT_ROOT/initramfs/fedora-profile.diff" initramfs/fedora-profile.diff
copy "$PROJECT_ROOT/tools/build-root-contract.py" tools/build-root-contract.py
copy "$PROJECT_ROOT/tools/build-busybox.sh" tools/build-busybox.sh
copy "$PROJECT_ROOT/tools/examples/fedora-root.manifest.example" tools/examples/fedora-root.manifest.example
copy "$BUSYBOX" bin/busybox
copy "$PROJECT_ROOT/out/boot/toolchain/busybox-1.36.1.config" busybox.config
copy "$MKBOOTIMG_DIR/mkbootimg.py" mkbootimg/mkbootimg.py
copy "$MKBOOTIMG_DIR/unpack_bootimg.py" mkbootimg/unpack_bootimg.py
# mkbootimg.py imports the AOSP gki support package (generate_gki_certificate).
mkdir -p "$A/mkbootimg/gki"
for f in "$MKBOOTIMG_DIR"/gki/*.py; do
	[ -f "$f" ] || continue
	copy "$f" "mkbootimg/gki/$(basename -- "$f")"
done
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh" \
	upstream/xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/initramfs/init" \
	upstream/xiaomipad-6pro-mainline/initramfs/init
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/native-bootargs.txt" \
	upstream/xiaomipad-6pro-mainline/device/native-bootargs.txt
# linux_splash: the on-device boot rebuild must use the same verified
# A-slot cmdline as the host image (console=tty0, gnome.is_vm=0).  Copy the
# project file instead of deriving it again so the host and device cannot drift.
copy "$PROJECT_ROOT/overlays/boot/liuqin-bootargs.txt" liuqin-bootargs.txt
[ "$(cat "$A/liuqin-bootargs.txt")" = "$(cat "$PROJECT_ROOT/overlays/boot/liuqin-bootargs.txt")" ] ||
	die "packaged liuqin-bootargs.txt differs from overlays/boot/liuqin-bootargs.txt"
grep -q 'gnome.is_vm=0' "$A/liuqin-bootargs.txt" ||
	die "packaged liuqin-bootargs.txt lacks gnome.is_vm=0"
if grep -q 'console=drm_log' "$A/liuqin-bootargs.txt"; then
	die "packaged liuqin-bootargs.txt still uses console=drm_log"
fi
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/liuqin-abl-boot-overlay.dts" \
	upstream/xiaomipad-6pro-mainline/device/liuqin-abl-boot-overlay.dts
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/boot/liuqin-mark-slot-successful.c" \
	upstream/xiaomipad-6pro-mainline/device/boot/liuqin-mark-slot-successful.c
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode" \
	upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-power-key.c" \
	upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-power-key.c
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-exit.c" \
	upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-exit.c
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/kernel/source.json" \
	upstream/xiaomipad-6pro-mainline/kernel/source.json
mkdir -p "$A/upstream/xiaomipad-6pro-mainline/tools/lib"
for f in "$PROJECT_ROOT"/upstream/xiaomipad-6pro-mainline/tools/lib/*; do
	[ -f "$f" ] || continue
	copy "$f" "upstream/xiaomipad-6pro-mainline/tools/lib/$(basename -- "$f")"
done
mkdir -p "$A/bin"
for f in build-initramfs.sh build-bootimg.sh cc-prebuilt liuqin-boot-tools; do
	copy "$BOOT_TOOLS_DIR/bin/$f" "bin/$f"
	chmod 0755 "$A/bin/$f"
done
chmod 0755 "$A/bin/busybox"
printf '%s\n' "$VERSION" >"$A/VERSION"

# busybox identity (pinned by tools/build-busybox.sh REFERENCE_SHA256)
bb_sha=$(sha256sum "$BUSYBOX" | cut -d' ' -f1)
printf '%s  bin/busybox\n' "$bb_sha" >"$A/busybox.sha256"

# Prebuilt static stage-1 helpers (device has no compiler). Sources are the
# packaged upstream C files; the cc-prebuilt shim installs these at refresh time.
mkdir -p "$A/helpers"
compile_helper() { # compile_helper SRC OUT [extra flags…]
	local src=$1 out=$2
	shift 2
	aarch64-linux-gnu-gcc -static -Os -s "$@" "$A/$src" -o "$A/helpers/$out" ||
		die "failed to compile helper $out"
	LC_ALL=C readelf -h "$A/helpers/$out" | grep -q 'Machine:.*AArch64' ||
		die "helper is not AArch64: $out"
	if LC_ALL=C readelf -l "$A/helpers/$out" | grep -q INTERP; then
		die "helper is dynamically linked: $out"
	fi
}
compile_helper upstream/xiaomipad-6pro-mainline/device/boot/liuqin-mark-slot-successful.c liuqin-mark-slot-successful
compile_helper upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-power-key.c liuqin-charger-mode-power-key -Wall -Wextra -Werror
compile_helper upstream/xiaomipad-6pro-mainline/device/charger-mode/liuqin-charger-mode-exit.c liuqin-charger-mode-exit -Wall -Wextra -Werror

# Compatibility path expected by the copied build-initramfs.sh default.
mkdir -p "$A/out/boot/toolchain"
cp -f "$A/bin/busybox" "$A/out/boot/toolchain/busybox-1.36.1-aarch64-static"

# Licenses / notices
mkdir -p "$A/LICENSES"
copy "$PROJECT_ROOT/LICENSE" LICENSES/LICENSE.project-MIT
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/LICENSE" LICENSES/LICENSE.upstream-MIT
copy "$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/NOTICE" LICENSES/NOTICE.upstream
copy "$BOOT_TOOLS_DIR/NOTICE" NOTICE
for spdx in GPL-2.0-only Apache-2.0; do
	for candidate in "/usr/share/licenses/spdx/$spdx.txt" "/usr/share/licenses/common/$spdx"; do
		if [ -f "$candidate" ]; then
			copy "$candidate" "LICENSES/LICENSE.$spdx"
			break
		fi
	done
done
for spdx in GPL-2.0-only Apache-2.0; do
	[ -f "$A/LICENSES/LICENSE.$spdx" ] || printf 'License text for %s is available from https://spdx.org/licenses/%s.html (offline host lacked the SPDX text file)\n' "$spdx" "$spdx" >"$A/LICENSES/LICENSE.$spdx"
done

# Provenance: every copied file with its source path + sha256.
python3 - "$A" "$PROJECT_ROOT" "$WORK_ROOT/assets-provenance.json" <<'PY'
import hashlib, json, os, sys
assets, project, out = sys.argv[1:4]

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

records = []
for base, dirs, files in os.walk(assets):
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(base, name)
        rel = os.path.relpath(path, assets)
        if rel.startswith("helpers/") or rel.startswith("bin/") or rel in ("VERSION", "busybox.sha256", "assets.manifest"):
            continue
        src = rel
        candidates = [os.path.join(project, rel), os.path.join(project, "upstream/xiaomipad-6pro-mainline", rel)]
        source = next((c for c in candidates if os.path.isfile(c)), None)
        records.append({"asset": rel, "sha256": sha256(path),
                        "source": (os.path.relpath(source, project) if source else "generated/packaged")})
json.dump({"schema": 1, "assets": records}, open(out, "w"), indent=2)
print("provenance entries:", len(records))
PY
mkdir -p "$A/PACKAGING"
cp "$WORK_ROOT/assets-provenance.json" "$A/PACKAGING/provenance.json"
printf '%s\n' "$bb_sha" >"$A/PACKAGING/busybox.sha256.recorded"
{
	printf 'liuqin-boot-tools asset bundle\n'
	printf 'version=%s\n' "$VERSION"
	printf 'built_from_project=%s\n' "$PROJECT_ROOT"
	printf 'busybox_sha256=%s\n' "$bb_sha"
	printf 'helper_aarch64_static=yes\n'
} >"$A/PACKAGING/assets-info.txt"

# Deterministic asset manifest over everything except itself.
(cd "$A" && find . -type f ! -name assets.manifest ! -path './firmware-pool/*' ! -path './wlan-hsp2-tuple/*' \
	-printf '%P\n' | LC_ALL=C sort | xargs sha256sum) >"$A/assets.manifest"
log "asset files: $(wc -l <"$A/assets.manifest"), size: $(du -sh "$A" | cut -f1)"

# ---------------------------------------------------------------- tarball + spec
tar --sort=name --mtime="@0" --owner=0 --group=0 --numeric-owner \
	--transform "s,^assets,liuqin-boot-tools-$VERSION," \
	-C "$WORK_ROOT" -czf "$WORK_ROOT/rpmbuild/SOURCES/liuqin-boot-assets-$VERSION.tar.gz" assets
cp "$BOOT_TOOLS_DIR/liuqin-boot-tools.spec" "$WORK_ROOT/rpmbuild/SPECS/"
cp "$BOOT_TOOLS_DIR/bootimg.conf.default" "$WORK_ROOT/rpmbuild/SOURCES/"
cp "$BOOT_TOOLS_DIR/NOTICE" "$WORK_ROOT/rpmbuild/SOURCES/"

# ---------------------------------------------------------------- rpmbuild in container
CONTAINER_ID=$(sudo podman image inspect --format '{{.Id}}' "$CONTAINER_IMAGE")
log "container: $CONTAINER_IMAGE ($CONTAINER_ID)"
STARTED_AT=$(date -Is)
START_EPOCH=$(date +%s)
cat >"$WORK_ROOT/container-build.sh" <<'CONTAINER_EOF'
set -eu
if ! command -v rpmbuild >/dev/null 2>&1; then
	dnf -y install rpm-build >/tmp/dnf.log 2>&1 || { tail -30 /tmp/dnf.log; exit 3; }
fi
rpmbuild -bb --target aarch64 --define "_topdir /work/rpmbuild" /work/rpmbuild/SPECS/liuqin-boot-tools.spec \
	2>&1 | tee /work/rpmbuild.log
rpm=$(find /work/rpmbuild/RPMS -name 'liuqin-boot-tools-*.rpm' | head -n 1)
[ -n "$rpm" ] || { echo "no RPM produced" >&2; exit 5; }
mkdir -p /work/meta
rpm -qpl "$rpm" >/work/meta/rpm-contents.txt
rpm -qpi "$rpm" >/work/meta/rpm-info.txt
rpm -qp --provides "$rpm" >/work/meta/rpm-provides.txt
rpm -qp --requires "$rpm" >/work/meta/rpm-requires.txt
rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$rpm" >/work/meta/rpm-nevra.txt
mkdir -p /work/repo
cp -f "$rpm" /work/repo/
if command -v createrepo_c >/dev/null 2>&1; then
	createrepo_c --quiet /work/repo >/work/meta/createrepo.log 2>&1
fi
# Extract payloads for offline validation (boot-tools + kernel + device firmware).
extract() { # extract RPM DEST
	mkdir -p "$2"
	rpm2cpio "$1" | (cd "$2" && cpio -idm --quiet)
}
extract "$rpm" /work/roots/boot-tools
for krpm in /work/input-rpms/kernel-liuqin-*.rpm; do extract "$krpm" /work/roots/kernel; done
for drpm in /work/input-rpms/liuqin-firmware-*.rpm; do extract "$drpm" /work/roots/firmware; done
for drpm in /work/input-rpms/liuqin-audio-*.rpm; do extract "$drpm" /work/roots/audio; done
echo "container build OK: $(basename "$rpm")"
CONTAINER_EOF
mkdir -p "$WORK_ROOT/input-rpms" "$WORK_ROOT/roots"
cp -f "$KERNEL_RPM_DIR"/kernel-liuqin-*.rpm "$WORK_ROOT/input-rpms/"
cp -f "$DEVICE_RPM_DIR"/liuqin-firmware-*.rpm "$DEVICE_RPM_DIR"/liuqin-audio-*.rpm "$WORK_ROOT/input-rpms/"
cp -f "$PUBLISHED_BOOTIMG" "$WORK_ROOT/input-rpms/published-boot.img"
if ! sudo podman run --rm --network=host \
	-e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" -e no_proxy="${no_proxy:-}" \
	-v "$WORK_ROOT:/work:Z" "$CONTAINER_IMAGE" /bin/bash /work/container-build.sh \
	>"$OUT_DIR/logs/container.log" 2>&1; then
	tail -n 80 "$OUT_DIR/logs/container.log" >&2 || true
	for f in rpmbuild.log; do [ -f "$WORK_ROOT/$f" ] && cp -f "$WORK_ROOT/$f" "$OUT_DIR/logs/"; done
	die "container build failed (logs: $OUT_DIR/logs/)"
fi
tail -n 3 "$OUT_DIR/logs/container.log" | sed 's/^/[container] /'
cp -f "$WORK_ROOT/rpmbuild.log" "$OUT_DIR/logs/rpmbuild.log" 2>/dev/null || true
# Rootful podman wrote root-owned files into the bind mount; restore host
# ownership so the offline validation can write into the extracted trees.
sudo chown -R "$(id -u):$(id -g)" "$WORK_ROOT"
cp -f "$WORK_ROOT/meta/"*.txt "$OUT_DIR/verification/" 2>/dev/null || true
FINISHED_AT=$(date -Is)
DURATION=$(( $(date +%s) - START_EPOCH ))

RPM_FILE=$(find "$WORK_ROOT/repo" -name 'liuqin-boot-tools-*.rpm' | head -n 1)
[ -n "$RPM_FILE" ] || die "no RPM produced"
RPM_BASENAME=$(basename "$RPM_FILE")
RPM_SHA=$(sha256sum "$RPM_FILE" | cut -d' ' -f1)
RPM_SIZE=$(stat -c '%s' "$RPM_FILE")
log "RPM: $RPM_BASENAME ($RPM_SIZE B, sha256 $RPM_SHA)"
cp -f "$RPM_FILE" "$OUT_DIR/rpm/"
cp -a "$WORK_ROOT/repo/repodata" "$OUT_DIR/repo/" 2>/dev/null || true
cp -f "$RPM_FILE" "$OUT_DIR/repo/"

# ---------------------------------------------------------------- repo consistency
# The packaged tools must be byte-identical to the repository versions they were
# built from (single producer/consumer surface: the kernel-install hook, the
# refresh pipeline, the schema v2 metadata implementation, the kernel pair tool
# and the boot-assets build scripts).  The RPM payloads were extracted into
# $WORK_ROOT/roots/{boot-tools,kernel} by the container above.
log "verifying packaged tools match the repository (repo consistency)"
if python3 - "$PROJECT_ROOT" "$WORK_ROOT" "$OUT_DIR/verification/repo-consistency.txt" <<'PY'
import hashlib, os, sys
from pathlib import Path

project, work_root, report_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
boot_tools = work_root / "roots/boot-tools"
kernel = work_root / "roots/kernel"
assets = boot_tools / "usr/libexec/liuqin/boot-assets"

# (repository file, packaged file) — every repository-sourced tool in the two
# RPMs that participate in building/staging/applying/rolling back boot images.
PAIRS = [
    # liuqin-boot-tools: copied project build scripts + contract generator + helpers
    ("scripts/build-initramfs.sh", assets / "scripts/build-initramfs.sh"),
    ("scripts/build-bootimg.sh", assets / "scripts/build-bootimg.sh"),
    ("overlays/boot/abl-symbols-dtc-labels.patch",
     assets / "overlays/boot/abl-symbols-dtc-labels.patch"),
    ("overlays/boot/liuqin-bootargs.txt", assets / "liuqin-bootargs.txt"),
    ("initramfs/init", assets / "initramfs/init"),
    ("tools/build-root-contract.py", assets / "tools/build-root-contract.py"),
    ("tools/build-busybox.sh", assets / "tools/build-busybox.sh"),
    ("tools/examples/fedora-root.manifest.example",
     assets / "tools/examples/fedora-root.manifest.example"),
    ("cache/upstream-v0.6.0/mkbootimg/mkbootimg.py", assets / "mkbootimg/mkbootimg.py"),
    ("cache/upstream-v0.6.0/mkbootimg/unpack_bootimg.py",
     assets / "mkbootimg/unpack_bootimg.py"),
    ("upstream/xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh",
     assets / "upstream/xiaomipad-6pro-mainline/tools/lib/build-bootimg.sh"),
    ("upstream/xiaomipad-6pro-mainline/initramfs/init",
     assets / "upstream/xiaomipad-6pro-mainline/initramfs/init"),
    ("upstream/xiaomipad-6pro-mainline/device/native-bootargs.txt",
     assets / "upstream/xiaomipad-6pro-mainline/device/native-bootargs.txt"),
    ("upstream/xiaomipad-6pro-mainline/device/liuqin-abl-boot-overlay.dts",
     assets / "upstream/xiaomipad-6pro-mainline/device/liuqin-abl-boot-overlay.dts"),
    ("packaging/boot-tools/bin/build-initramfs.sh", assets / "bin/build-initramfs.sh"),
    ("packaging/boot-tools/bin/build-bootimg.sh", assets / "bin/build-bootimg.sh"),
    ("packaging/boot-tools/bin/cc-prebuilt", assets / "bin/cc-prebuilt"),
    ("packaging/boot-tools/bin/liuqin-boot-tools", assets / "bin/liuqin-boot-tools"),
    ("packaging/boot-tools/bootimg.conf.default",
     boot_tools / "etc/liuqin/bootimg.conf"),
    # kernel-liuqin: hook, refresh, apply, schema v2 metadata, kernel pair tool
    ("kernel/fedora/99-liuqin-android-boot.install",
     kernel / "usr/lib/kernel/install.d/99-liuqin-android-boot.install"),
    ("kernel/fedora/liuqin-apply-boot", kernel / "usr/sbin/liuqin-apply-boot"),
    ("kernel/fedora/bootimg-builder", kernel / "usr/libexec/liuqin/bootimg-builder"),
    ("kernel/fedora/liuqin-bootimg-refresh",
     kernel / "usr/libexec/liuqin/liuqin-bootimg-refresh"),
    ("kernel/fedora/liuqin_boot_metadata.py",
     kernel / "usr/lib/liuqin/liuqin_boot_metadata.py"),
    ("kernel/fedora/liuqin-kernel-pair", kernel / "usr/sbin/liuqin-kernel-pair"),
    ("kernel/fedora/bootimg.conf.example",
     kernel / "usr/share/liuqin/bootimg.conf.example"),
]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


lines, failures = [], 0
for repo_rel, packaged in PAIRS:
    repo = project / repo_rel
    if not repo.is_file():
        lines.append(f"FAIL  missing repository file: {repo_rel}")
        failures += 1
        continue
    if not packaged.is_file():
        lines.append(f"FAIL  missing packaged file for {repo_rel}: {packaged}")
        failures += 1
        continue
    repo_sha, packaged_sha = sha256(repo), sha256(packaged)
    if repo_sha != packaged_sha:
        lines.append(f"FAIL  {repo_rel}: repo {repo_sha} != packaged {packaged_sha}")
        failures += 1
    else:
        lines.append(f"PASS  {repo_rel}  {repo_sha}")
lines.append(f"SUMMARY  pairs={len(PAIRS)} failures={failures}")
report_path.write_text("\n".join(lines) + "\n")
print("\n".join(lines[-3:]))
sys.exit(1 if failures else 0)
PY
then
	export REPO_CONSISTENCY=pass
	log "repo consistency: PASS (packaged tools == repository)"
else
	REPO_CONSISTENCY=fail
	die "repo consistency FAILED: a packaged tool differs from the repository (see $OUT_DIR/verification/repo-consistency.txt)"
fi

# ---------------------------------------------------------------- offline validation (host)
log "running offline validation on the installed tree"
chmod +x "$BOOT_TOOLS_DIR/tests/offline-validation.sh"
STOCK_ROM_ARGS=()
[ -z "$STOCK_ROM_DIR" ] || STOCK_ROM_ARGS=(--stock-rom-dir "$STOCK_ROM_DIR")
if "$BOOT_TOOLS_DIR/tests/offline-validation.sh" \
	"${STOCK_ROM_ARGS[@]}" \
	--boot-tools-root "$WORK_ROOT/roots/boot-tools" \
	--kernel-root "$WORK_ROOT/roots/kernel" \
	--firmware-root "$WORK_ROOT/roots/firmware/usr/lib/firmware" \
	--firmware-rpm-root "$WORK_ROOT/roots/firmware" \
	--audio-root "$WORK_ROOT/roots/audio" \
	--kernel-dist "$KERNEL_OUT/dist" \
	--published-bootimg "$PUBLISHED_BOOTIMG" \
	--work "$WORK_ROOT/validation" \
	>"$OUT_DIR/verification/offline-validation.txt" 2>&1; then
	VALIDATION=pass
else
	VALIDATION=fail
fi
tail -n 30 "$OUT_DIR/verification/offline-validation.txt" | sed 's/^/[validate] /'

# ---------------------------------------------------------------- build-info + sums
VALIDATION_TSV="$OUT_DIR/verification/offline-validation.txt"
python3 - "$OUT_DIR" "$WORK_ROOT" "$CONTAINER_IMAGE" "$CONTAINER_ID" "$STARTED_AT" "$FINISHED_AT" "$DURATION" "$VALIDATION" \
	"$KERNEL_OUT" "$KERNEL_RPM_DIR" "$STOCK_ROM_DIR" <<'PY'
import hashlib, json, os, sys
out_dir, work_root, image, image_id, started, finished, duration, validation, kernel_out, kernel_rpm_dir, stock_rom_dir = sys.argv[1:12]

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

rpms = {}
for name in sorted(os.listdir(os.path.join(out_dir, "rpm"))):
    path = os.path.join(out_dir, "rpm", name)
    rpms[name] = {"sha256": sha256(path), "size": os.path.getsize(path)}
meta = {}
for name in ("rpm-nevra.txt", "rpm-contents.txt", "rpm-provides.txt", "rpm-requires.txt"):
    path = os.path.join(out_dir, "verification", name)
    if os.path.isfile(path):
        meta[name] = open(path).read().strip()
info = {
    "schema_version": 1,
    "package": {"name": "liuqin-boot-tools", "version": "0.6.0", "rpms": rpms, "metadata": meta},
    "contents": {
        "summary": "on-device boot assets: static BusyBox, prebuilt static helpers, "
                   "build-initramfs/build-bootimg wrappers, project scripts, contract generator, "
                   "initramfs/init, AOSP mkbootimg, default /etc/liuqin/bootimg.conf, stage tool",
        "asset_tree": "%{_libexecdir}/liuqin/boot-assets",
        "busybox_sha256": sha256(os.path.join(work_root, "assets/bin/busybox")),
        "assets_manifest_entries": sum(1 for line in open(os.path.join(work_root, "assets/assets.manifest")) if line.strip()),
    },
    "dependencies": {
        "requires": ["/bin/sh", "python3", "dtc", "patch", "cpio", "gzip", "coreutils", "findutils", "tar",
                     "liuqin-firmware", "liuqin-audio"],
        "recommends": ["kernel-liuqin"],
        "dependency_direction": "one-way: liuqin-boot-tools -> liuqin-firmware/liuqin-audio; "
                                "kernel-liuqin has no dependency on boot-tools (hook fail-closed if absent); "
                                "no cycle, independent upgrade order.",
    },
    "build": {
        "container_image": image, "container_image_id": image_id,
        "started_at": started, "finished_at": finished, "duration_seconds": int(duration),
        "host": {"kernel": os.uname().release, "machine": os.uname().machine},
        "helpers": "compiled on host with aarch64-linux-gnu-gcc -static, packaged as prebuilt",
    },
    "kernel_inputs": {
        "kernel_out": kernel_out,
        "kernel_image_sha256": sha256(os.path.join(kernel_out, "dist/Image")),
        "kernel_rpm": kernel_rpm_dir,
        "stock_rom_dir": stock_rom_dir or None,
        "note": "offline tests intentionally use the Fedora-fragment kernel from kernel-liuqin RPM, not the "
                "task-5 baseline out/kernel, so release/config stay consistent.",
    },
    "verification": {
        "offline_validation": validation,
        "repo_consistency": os.environ.get("REPO_CONSISTENCY", "unknown"),
        "repo_consistency_detail": "verification/repo-consistency.txt (packaged hook/refresh/"
                                   "apply/schema/kernel-pair/boot-assets tools sha256 vs repository)",
        "fail_closed_cases": "missing stock ROM / missing firmware pool / missing rootfs manifest / "
                             "canonical stock-rom boot.img without ROM -> all exit non-zero, no staging",
        "component_success_cases": "initramfs build (no firmware, allow-missing) + contract without kernel "
                                   "identity pins; boot.img assembly via "
                                   + ("canonical stock-ROM DTB" if stock_rom_dir else "published-DTB dev fallback")
                                   + " with the real Fedora-fragment kernel Image -> header v2 verified by unpack_bootimg.py",
        "not_validated": [
            "full refresh success with complete vendor firmware remains unverified; canonical DTB component assembly "
            + ("passed with supplied 44+14 ROM inputs" if stock_rom_dir else "needs user stock ROM 44+14 inputs"),
            "on-device runtime/duration under dnf (qemu-user host run only)",
        ],
    },
    "notes": [
        "No vendor firmware is redistributed; `liuqin-boot-tools stage` copies it from the device's own "
        "liuqin-firmware/liuqin-audio packages and the user's stock ROM tree.",
        "The contract generator copy currently follows the P0-1 policy landed by boot-builder (kernel identity "
        "not pinned; init warns on running-vs-rootfs release mismatch).",
        "kernel-liuqin spec already requires python3 (apply-boot is Python); recorded in task-11 RESULT.",
    ],
    "safety": {"boot_partition_written": False, "qbootctl_used": False, "gpt_attributes_modified": False},
}
with open(os.path.join(out_dir, "build-info.json"), "w") as handle:
    json.dump(info, handle, indent=2)
    handle.write("\n")
print("build-info.json written")
PY
(
	cd "$OUT_DIR"
	find rpm repo verification logs -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
	sha256sum build-info.json
) >"$OUT_DIR/SHA256SUMS"
OUT_REL=$(realpath --relative-to="$PROJECT_ROOT" "$OUT_DIR")
log "outputs under $OUT_DIR"
log "  RPM       $OUT_REL/rpm/$RPM_BASENAME"
log "  repo      $OUT_REL/repo"
log "  validation=$VALIDATION (verification/offline-validation.txt)"
log "done in ${DURATION}s"
[ "$VALIDATION" = pass ] || die "offline validation failed (see $OUT_REL/verification/offline-validation.txt)"
