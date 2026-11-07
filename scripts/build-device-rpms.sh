#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the liuqin device-layer Fedora RPMs in a Fedora 45 container.
#
# Packages:
#   liuqin-firmware         vendor board firmware closure (LOCAL PRIVATE; not
#                           redistributable -- see docs/maintenance/device-packages.md)
#   liuqin-audio            AudioReach topology (built from source) + ALSA UCM2
#   liuqin-device-support   systemd/udev/polkit/chrony units + helpers
#
# The x86_64 host only orchestrates: it stages a space-free work tree under
# /var/tmp, builds two static aarch64 helper binaries with the host cross
# toolchain (the Fedora container's cross-gcc has no target libc -- see
# docs/maintenance/device-packages.md), and runs rpmbuild --target aarch64 inside
# Fedora 45.  A persistent builder image is created once and reused.
#
# Usage:
#   scripts/build-device-rpms.sh [options]
#     --out DIR            output dir (default: out/rpms)
#     --stage DIR          staging tree (default: /var/tmp/liuqin-pack)
#     --jobs N             parallelism hint recorded in metadata (default: nproc)
#     --only LIST          comma list: firmware,audio,device-support
#     --rebuild-image      recreate the builder container image
#     --keep-stage         keep the staging tree after a successful build
#     --source-date-epoch  reproducibility epoch (default: upstream commit time)
#   Environment: BUILDER_IMAGE, BASE_IMAGE, BUILD_PLATFORM, CACHE_DIR, proxy vars.
#
set -euo pipefail

project_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
upstream=$project_root/upstream/xiaomipad-6pro-mainline
kernel_upstream=$project_root/upstream/linux-sm8450-liuqin
packaging=$project_root/packaging/device

out_dir=${OUT_DIR:-$project_root/out/rpms}
stage=${STAGE_DIR:-/var/tmp/liuqin-pack}
cache=${CACHE_DIR:-/var/tmp/liuqin-pack-cache}
builder_image=${BUILDER_IMAGE:-localhost/liuqin-rpmbuild:fc45}
base_image=${BASE_IMAGE:-registry.fedoraproject.org/fedora:45}
build_platform=${BUILD_PLATFORM:-linux/amd64}
jobs=${JOBS:-$(nproc 2>/dev/null || echo 4)}
only=${ONLY:-}
rebuild_image=0
keep_stage=0

die() { printf 'build-device-rpms: %s\n' "$*" >&2; exit 1; }
log() { printf 'build-device-rpms: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
	case $1 in
	--out) out_dir=$2; shift 2 ;;
	--stage) stage=$2; shift 2 ;;
	--jobs) jobs=$2; shift 2 ;;
	--only) only=$2; shift 2 ;;
	--rebuild-image) rebuild_image=1; shift ;;
	--keep-stage) keep_stage=1; shift ;;
	--source-date-epoch) SOURCE_DATE_EPOCH=$2; shift 2 ;;
	-h | --help) sed -n '2,30p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

case " ${only:-} " in
"  ") only="firmware,audio,device-support" ;;
esac
for item in ${only//,/ }; do
	case $item in
	firmware | audio | device-support) ;;
	*) die "unknown --only item: $item (firmware,audio,device-support)" ;;
	esac
done

# --- preconditions -----------------------------------------------------------
log 'checking host prerequisites'
command -v podman >/dev/null || die 'podman is required'
command -v git >/dev/null || die 'git is required'
command -v tar >/dev/null || die 'tar is required'
command -v python3 >/dev/null || die 'python3 is required'
command -v aarch64-linux-gnu-gcc >/dev/null || die 'aarch64-linux-gnu-gcc is required (host cross compiler for helpers)'
[ -d "$upstream/device/firmware" ] || die "upstream device tree is missing: $upstream"
[ -d "$packaging" ] || die "packaging/device is missing: $packaging"
sudo -n true 2>/dev/null || die 'rootful podman requires passwordless sudo'
[ -n "${http_proxy:-}" ] || log "warning: http_proxy is unset; container dnf may fail"
mkdir -p "$out_dir" "$cache"
out_dir=$(cd "$out_dir" && pwd)

podman() { sudo podman "$@"; }
podman_run_image() { podman run --platform "$build_platform" --network=host \
	-e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
	-e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
	"$@"; }

# --- identity ----------------------------------------------------------------
upstream_commit=$(git -C "$upstream" rev-parse HEAD)
upstream_time=$(git -C "$upstream" show -s --format=%ct HEAD)
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$upstream_time}
kernel_commit=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' \
	"$upstream/kernel/source.json")
log "upstream project commit=$upstream_commit kernel=$kernel_commit epoch=$SOURCE_DATE_EPOCH"

# --- stage: clean and copy packaging ----------------------------------------
log "staging build tree under $stage"
if [ "$keep_stage" = 0 ] && [ -d "$stage" ]; then
	case $stage in
	/var/tmp/* | /tmp/*) sudo rm -rf "$stage" ;;
	*) die "refusing to remove staging dir outside /var/tmp: $stage" ;;
	esac
fi
sudo mkdir -p "$stage"/{SPECS,SOURCES,SOURCES/bin,scripts,out/rpms,src}
sudo chown -R "$(id -u):$(id -g)" "$stage"
mkdir -p "$stage/src"

cp "$packaging"/*.spec "$stage/SPECS/"
cp "$packaging/relocate-device-support.sh" "$stage/SOURCES/"
cp "$packaging/elf-check.py" "$stage/SOURCES/"
cp "$packaging/helpers/liuqin-power-key-action" "$stage/SOURCES/"
cp "$project_root/tools/afk/daily-log/sample.py" "$stage/SOURCES/liuqin-daily-log.py"
cp "$project_root/tools/afk/daily-log/liuqin-daily-log.service" "$stage/SOURCES/"
cp "$project_root/tools/afk/daily-log/liuqin-daily-log.timer" "$stage/SOURCES/"
cp "$project_root/tools/afk/gpu-hang/gpu-hang-watch.py" "$stage/SOURCES/liuqin-gpu-hang-watch.py"
cp "$project_root/tools/afk/gpu-hang/liuqin-gpu-hang-watch.service" "$stage/SOURCES/"
cp "$packaging/container/build-inner.sh" "$stage/scripts/"
cp "$packaging/container/postprocess.py" "$stage/scripts/"
cp "$packaging/container/verify-install.py" "$stage/scripts/"
cp "$upstream/LICENSE" "$upstream/NOTICE" "$stage/SOURCES/"
cp "$upstream/device/firmware/README.md" "$stage/SOURCES/firmware-README.md"

TAR_OPTS=(--sort=name "--mtime=@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner)

# documented provenance files shipped as %doc
cat >"$stage/SOURCES/audio-topology-README.md" <<EOF
# liuqin AudioReach topology provenance

- Board topology source: device/audio-topology/liuqin-speakers.m4
  (xiaomipad-6pro-mainline v0.6.0 @ ${upstream_commit:0:12})
- Framework: linux-msm/audioreach-topology @ 2af1f1ebb8d4fd03b5f53891467ddde2e208a8a0
- Builder: tools/build-liuqin-audio-topology.sh (m4 + alsatplg, legacy TDM sink rewrite)
- Expected binary sha256 (device-validated): 9c9f8bfcffde1f52c143d58cba821c5f6b3899553370ab92a88b90d81fef9ee9
- License: BSD-3-Clause (topology), MIT (UCM2 project files)
EOF
cat >"$stage/SOURCES/device-support-README.md" <<EOF
# liuqin device-support provenance

Source: yzddmr6/xiaomipad-6pro-mainline @ ${upstream_commit}
License: MIT (project) unless a file states otherwise; liuqin-mipps-auth is
GPL-2.0-only and is derived from xiaomi-mipps-auth (see NOTICE).

Path relocation to Fedora FHS is done at package time by
relocate-device-support.sh; the upstream checkout is never modified.
The power-key action helper is a Fedora/KDE replacement for the upstream
GNOME/Mutter implementation.  See docs/maintenance/device-packages.md for the full mapping.
The daily-use sampler and its service/timer are project sources in
tools/afk/daily-log; they never wake the tablet or change sleep policy.
The package ships the timer without enabling it automatically.
EOF

# --- sources: firmware -------------------------------------------------------
log 'packing firmware tree'
tar "${TAR_OPTS[@]}" -C "$upstream/device/firmware" -cf "$stage/SOURCES/firmware-tree.tar" usr
cp "$upstream/device/firmware/firmware.manifest" "$stage/SOURCES/firmware.manifest"

# --- sources: audio ----------------------------------------------------------
log 'packing audio topology and UCM2 sources'
cp "$upstream/device/audio-topology/liuqin-speakers.m4" "$stage/SOURCES/"
cp "$upstream/tools/build-liuqin-audio-topology.sh" "$stage/SOURCES/"
tar "${TAR_OPTS[@]}" -C "$upstream/device/gnome-overlay/usr/share" -cf "$stage/SOURCES/ucm2.tar" alsa

topology_commit=2af1f1ebb8d4fd03b5f53891467ddde2e208a8a0
topology_repo=https://github.com/linux-msm/audioreach-topology.git
topology_cache=$cache/audioreach-topology-$topology_commit
topology_tar=$cache/audioreach-topology-$topology_commit.tar
# A cache entry from an older staging format (entries at "./") is rebuilt.
if [ -f "$topology_tar" ] &&
	! tar -tf "$topology_tar" 2>/dev/null | head -1 | grep -q '^audioreach-topology/$'; then
	rm -f "$topology_tar"
fi
if [ ! -f "$topology_tar" ]; then
	log "fetching audioreach-topology @ $topology_commit (cached under $cache)"
	rm -rf "$topology_cache"
	git init -q "$topology_cache"
	git -C "$topology_cache" remote add origin "$topology_repo"
	git -C "$topology_cache" fetch -q --depth 1 origin "$topology_commit"
	git -C "$topology_cache" checkout -q FETCH_HEAD
	[ "$(git -C "$topology_cache" rev-parse HEAD)" = "$topology_commit" ] ||
		die 'audioreach-topology commit verification failed'
	[ -z "$(git -C "$topology_cache" status --porcelain --untracked-files=no)" ] ||
		die 'audioreach-topology checkout is not clean'
	tar "${TAR_OPTS[@]}" --transform 's,^[^/]*,audioreach-topology,' \
	-C "$cache" -cf "$topology_tar" "$(basename "$topology_cache")"
fi
cp "$topology_tar" "$stage/SOURCES/audioreach-topology.tar"

# --- sources: device-support -------------------------------------------------
log 'packing device-support sources and cross-building helpers'
tar "${TAR_OPTS[@]}" -C "$upstream" -cf "$stage/SOURCES/device-support-tree.tar" \
	device/gnome-overlay device/power-key device/charger-mode

cross_cc=${CROSS_COMPILE:-aarch64-linux-gnu-}
cross_gcc=${cross_cc}gcc
cross_ld=${cross_cc}ld
[ -x "$(command -v "$cross_gcc")" ] || die "cross compiler not found: $cross_gcc"

power_keyd_src=$stage/src/liuqin-power-keyd.c
sed 's|/usr/local/libexec/liuqin-power-key-action|/usr/libexec/liuqin/liuqin-power-key-action|' \
	"$upstream/device/power-key/liuqin-power-keyd.c" >"$power_keyd_src"
grep -q '/usr/libexec/liuqin/liuqin-power-key-action' "$power_keyd_src" ||
	die 'power-keyd action-helper path rewrite did not apply'

# Static aarch64: the Fedora cross-gcc package has no target libc, so the
# helpers are linked statically with the host cross toolchain and are fully
# self-contained on the tablet (docs/maintenance/device-packages.md records the deviation).
"$cross_gcc" -std=c11 -O2 -pipe -static -s -Wall -Wextra -Wformat=2 \
	-fstack-protector-strong -D_FORTIFY_SOURCE=3 \
	"-ffile-prefix-map=$upstream=/build/upstream" \
	"$power_keyd_src" -o "$stage/SOURCES/liuqin-power-keyd"
"$cross_gcc" -Os -pipe -static -s -Wall -Wextra \
	"-ffile-prefix-map=$upstream=/build/upstream" \
	"$upstream/device/charger-mode/liuqin-charger-mode-exit.c" \
	-o "$stage/SOURCES/liuqin-reboot"
python3 "$packaging/elf-check.py" --static \
	"$stage/SOURCES/liuqin-power-keyd" "$stage/SOURCES/liuqin-reboot"

# --- per-package source checksum lists --------------------------------------
write_sums() { # <outfile> <files...>
	local out=$1
	shift
	(cd "$stage/SOURCES" && sha256sum "$@" | LC_ALL=C sort -k2) >"$out"
}
write_sums "$stage/SOURCES/source-sha256-firmware.txt" \
	firmware-tree.tar firmware.manifest NOTICE LICENSE firmware-README.md
write_sums "$stage/SOURCES/source-sha256-audio.txt" \
	audioreach-topology.tar liuqin-speakers.m4 build-liuqin-audio-topology.sh \
	ucm2.tar NOTICE LICENSE audio-topology-README.md
write_sums "$stage/SOURCES/source-sha256-device-support.txt" \
	device-support-tree.tar relocate-device-support.sh liuqin-power-key-action \
	liuqin-power-keyd liuqin-reboot elf-check.py \
	liuqin-daily-log.py liuqin-daily-log.service liuqin-daily-log.timer \
	liuqin-gpu-hang-watch.py liuqin-gpu-hang-watch.service \
	NOTICE LICENSE device-support-README.md

# --- host-side build inputs metadata ----------------------------------------
python3 - "$stage" "$upstream" "$upstream_commit" "$kernel_commit" "$SOURCE_DATE_EPOCH" \
	"$jobs" "$cross_gcc" "$cross_ld" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

stage, upstream, commit, kernel_commit, epoch, jobs, cc, ld = sys.argv[1:]
stage = Path(stage)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def version(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).splitlines()[0]
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"


sources = {}
for path in sorted((stage / "SOURCES").rglob("*")):
    if path.is_file() and path.name != "source-sha256-firmware.txt":
        rel = str(path.relative_to(stage / "SOURCES"))
        sources[rel] = sha(path)
for path in sorted((stage / "SPECS").glob("*.spec")):
    sources[f"SPECS/{path.name}"] = sha(path)

data = {
    "schema_version": 1,
    "kind": "liuqin-device-rpms-build-inputs",
    "package_version": "0.6.0",
    "source_date_epoch": int(epoch),
    "jobs": int(jobs),
    "upstream_project": {
        "commit": commit,
        "path": "upstream/xiaomipad-6pro-mainline",
        "release": "v0.6.0",
    },
    "upstream_kernel": {"commit": kernel_commit},
    "toolchain": {
        "host_cross_gcc": version(cc, "--version"),
        "host_cross_ld": version(ld, "--version"),
        "host_cross_gcc_sha256": sha(subprocess.check_output(["which", cc], text=True).strip()),
        "helper_linking": "static (Fedora container cross-gcc lacks aarch64 target libc)",
    },
    "sources": sources,
}
(stage / "build-inputs.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
print(f"build-inputs.json: {len(sources)} staged sources")
PY

# --- builder container image ------------------------------------------------
if [ "$rebuild_image" = 1 ] || ! podman image exists "$builder_image"; then
	log "creating builder image $builder_image (one-time; dnf over proxy)"
	podman rm -f liuqin-rpmbuild-prep >/dev/null 2>&1 || true
	podman_run_image --name liuqin-rpmbuild-prep "$base_image" bash -c '
set -e
dnf -y -q install rpm-build rpmdevtools createrepo_c systemd chrony m4 git \
    tar gzip cpio file python3 alsa-topology-utils findutils util-linux >/tmp/dnf.log 2>&1 ||
    { echo DNF_FAIL; tail -40 /tmp/dnf.log; exit 1; }
if ! command -v alsatplg >/dev/null 2>&1; then
    provider=$(dnf -q repoquery --whatprovides "/usr/bin/alsatplg" 2>/dev/null | head -1)
    [ -n "$provider" ] || { echo "no alsatplg provider found"; exit 1; }
    dnf -y -q install "$provider" >/dev/null 2>&1
fi
command -v alsatplg >/dev/null
rpmbuild --version
echo BUILDER_IMAGE_READY'
	podman commit -q liuqin-rpmbuild-prep "$builder_image" >/dev/null
	podman rm -f liuqin-rpmbuild-prep >/dev/null
	log "builder image ready: $builder_image"
else
	log "reusing builder image $builder_image (use --rebuild-image to refresh)"
fi

# --- build inside the container --------------------------------------------
log "running rpmbuild in Fedora 45 container (only: $only)"
set +e
podman_run_image --rm -v "$stage:/work" \
	-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e JOBS="$jobs" -e ONLY="$only" \
	"$builder_image" bash /work/scripts/build-inner.sh
build_rc=$?
set -e

# --- collect results (even on a validation failure, for inspection) ---------
if ! ls "$stage"/out/rpms/*.rpm >/dev/null 2>&1; then
	die "container build failed (rc=$build_rc) before producing any RPM; staging tree: $stage"
fi
[ -f "$stage/out/rpms/build-info.json" ] ||
	log "warning: build-info.json is missing; collecting the RPMs anyway"
log "collecting RPMs into $out_dir"
sudo rm -rf "$out_dir"
sudo mkdir -p "$out_dir"
sudo cp -a "$stage/out/rpms/." "$out_dir/"
sudo chown -R "$(id -u):$(id -g)" "$out_dir"

if [ "$keep_stage" = 0 ] && [ "$build_rc" = 0 ]; then
	log "removing staging tree $stage (use --keep-stage to keep it)"
	sudo rm -rf "$stage"
elif [ "$build_rc" != 0 ]; then
	log "build failed (rc=$build_rc); staging tree kept for inspection: $stage"
fi

python3 - "$out_dir" <<'PY'
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
info = json.loads((out / "build-info.json").read_text())
print("\nRPM build summary:")
for pkg in info["packages"]:
    print(f"  {pkg['rpm']:<52} {pkg['size_bytes']:>10} bytes  files={pkg['file_count']:<4} "
          f"install={'OK' if pkg['validation']['install_ok'] else 'FAIL'}")
print(f"\nvalidations: {json.dumps(info['validation_summary'])}")
print(f"local repo:  {out}/repodata")
print(f"metadata:    {out}/build-info.json {out}/SHA256SUMS")
PY

[ "$build_rc" = 0 ] ||
	die "container rpmbuild/validation failed (rc=$build_rc); inspect $out_dir/validation-report.json"
