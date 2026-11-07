#!/bin/bash
# Assemble the liuqin firmware *pool* that `scripts/build-initramfs.sh
# --firmware-pool` consumes, straight from the pinned read-only upstream tree
# (upstream/xiaomipad-6pro-mainline/device/firmware).
#
# Why this exists:
#   * The upstream repository tracks the whole firmware closure (197 files) with
#     per-file sha256 in device/firmware/firmware.manifest, and every category
#     our builder pins matches it byte for byte.  No user/ROM extraction step is
#     needed for the *generic* pool.
#   * Per-device objects (CS35L41 *-calr.bin, WLAN/BT MAC, sensor registry) still
#     come from the unit's own persist partition at install time and never enter
#     this pool.
#
# Nothing is redistributed: files are copied from the pinned upstream clone into
# a git-ignored out/ tree and every digest is re-verified here and again by the
# initramfs builder.
#
# usage: scripts/assemble-firmware-pool.sh [options]
#   --out DIR            output directory (default: out/firmware-pool);
#                        the pool itself is written to DIR/pool, metadata to
#                        DIR/pool.manifest and DIR/pool.json
#   --topology FILE      AudioReach topology to validate and stage under
#                        DIR/audio-topology (must match an accepted sha256)
#   --verify-only        only verify the upstream tree against its manifest
#   --quiet              one summary line per step
#   -h, --help           this text
#
# Exit: 0 success, 1 verification/build failure, 2 usage/environment error.
set -euo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
upstream_fw=$project_root/upstream/xiaomipad-6pro-mainline/device/firmware
manifest=$upstream_fw/firmware.manifest
src=$upstream_fw/usr/lib/firmware

# AudioReach topology baselines.  The project pin is the one built from the
# pinned AudioReach sources and verified audible on liuqin; the
# upstream tree ships a different binary.  Release builds use the project pin.
TOPOLOGY_PROJECT_SHA=9c9f8bfcffde1f52c143d58cba821c5f6b3899553370ab92a88b90d81fef9ee9
TOPOLOGY_UPSTREAM_SHA=dff0c8af945c66d542a004931af66435966cee12c6c430d0fa0610c6d3d5d126

out_dir=$project_root/out/firmware-pool
topology=
verify_only=0
quiet=0

die() { echo "error: $*" >&2; exit 1; }
usage_die() { echo "error: $*" >&2; echo "run --help for usage" >&2; exit 2; }
say() { [ "$quiet" = 1 ] || echo "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

while [ $# -gt 0 ]; do
	case $1 in
	--out) [ $# -ge 2 ] && [ -n "$2" ] || usage_die "--out needs a value"; out_dir=$2; shift ;;
	--topology) [ $# -ge 2 ] && [ -n "$2" ] || usage_die "--topology needs a value"; topology=$2; shift ;;
	--verify-only) verify_only=1 ;;
	--quiet) quiet=1 ;;
	-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) usage_die "unknown argument: $1" ;;
	esac
	shift
done

case $out_dir in /*) ;; *) out_dir="$project_root/$out_dir" ;; esac
out_dir=$(realpath -m -- "$out_dir") || usage_die "cannot resolve --out"
out_pool=$out_dir/pool

[ -d "$src" ] || usage_die "upstream firmware tree missing: $src (run scripts/fetch-upstream.sh)"
[ -f "$manifest" ] || usage_die "upstream firmware manifest missing: $manifest"

say "== 1. verify the upstream firmware tree against firmware.manifest =="
tmp=$(mktemp -d "${TMPDIR:-/tmp}/liuqin-fw-manifest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sed "s|  /usr/lib/firmware/|  $src/|" "$manifest" >"$tmp/manifest"
entries=$(wc -l <"$tmp/manifest")
(cd / && sha256sum -c "$tmp/manifest" --quiet) ||
	die "upstream firmware tree does not match firmware.manifest"
manifest_sha=$(sha "$manifest")
say "   $entries files verified against $manifest_sha"

if [ "$verify_only" = 1 ]; then
	say "== done (verify-only): upstream tree is complete and matches its manifest =="
	exit 0
fi

if [ -n "$topology" ]; then
	[ -f "$topology" ] && [ ! -L "$topology" ] || usage_die "topology is not a regular file: $topology"
	topology_sha=$(sha "$topology")
	case $topology_sha in
	"$TOPOLOGY_PROJECT_SHA") topology_baseline=project ;;
	"$TOPOLOGY_UPSTREAM_SHA") topology_baseline=upstream ;;
	*) usage_die "topology sha256 $topology_sha is not an accepted baseline" ;;
	esac
fi

say "== 2. assemble the pool layout under $out_pool =="
rm -rf "$out_pool"
mkdir -p \
	"$out_pool/touch-nt36532/vendor/firmware" \
	"$out_pool/bt-qca6490/vendor/bt_firmware/image" \
	"$out_pool/wlan-qca6490/vendor/firmware_mnt/image/qca6490" \
	"$out_pool/wlan-qca6490/upstream/WCN6855/hw2.0" \
	"$out_pool/regulatory/upstream" \
	"$out_pool/gpu-adreno730/vendor" \
	"$out_pool/dsp-sm8475/vendor/qcom/sm8475/liuqin" \
	"$out_pool/wlan-hsp2/hw2.0" "$out_pool/wlan-hsp2/hw2.1"

# touch: both panel-vendor variants
cp -a "$src/novatek/liuqin/." "$out_pool/touch-nt36532/vendor/firmware/"

# bluetooth: the qca/ name set the btqca driver constructs
cp -a "$src/qca/." "$out_pool/bt-qca6490/vendor/bt_firmware/image/"

# WLAN: vendor board data (ELF) + the upstream WCN6855 runtime (kept as shipped)
cp -a "$src/ath11k/WCN6855/hw2.0/board.bin" \
	"$out_pool/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf"
cp -a "$src/ath11k/WCN6855/hw2.0/." "$out_pool/wlan-qca6490/upstream/WCN6855/hw2.0/"

# regulatory database (signed pair)
cp -a "$src/regulatory.db" "$src/regulatory.db.p7s" "$out_pool/regulatory/upstream/"

# GPU: zap from the DSP directory, sqe/gmu from the loader's updates tree
cp -a "$src/qcom/sm8475/liuqin/a730_zap.mbn" \
	"$src/updates/qcom/a730_sqe.fw" "$src/updates/qcom/gmu_gen70000.bin" \
	"$out_pool/gpu-adreno730/vendor/"

# DSP: the 68-file set (a730_zap.mbn is staged with the GPU category above)
for f in "$src/qcom/sm8475/liuqin"/*; do
	[ "${f##*/}" = a730_zap.mbn ] && continue
	cp -a "$f" "$out_pool/dsp-sm8475/vendor/qcom/sm8475/liuqin/"
done

# reviewed HSP2 WLAN tuple (hw2.0 + hw2.1)
for rev in hw2.0 hw2.1; do
	cp -a "$src/updates/ath11k/WCN6855/$rev/." "$out_pool/wlan-hsp2/$rev/"
done

say "== 3. self-check the assembled pool =="
count_of() { find "$1" -maxdepth 1 -type f | wc -l; }
[ "$(count_of "$out_pool/dsp-sm8475/vendor/qcom/sm8475/liuqin")" -eq 68 ] ||
	die "DSP category must hold 68 files"
[ "$(count_of "$out_pool/bt-qca6490/vendor/bt_firmware/image")" -eq 106 ] ||
	die "Bluetooth category must hold 106 files"
[ "$(count_of "$out_pool/touch-nt36532/vendor/firmware")" -eq 2 ] ||
	die "touch category must hold 2 files"
[ "$(sha "$out_pool/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf")" = \
	aa8ae92d781e09db8cffa960b00c9606e4bb65d9c7a89f9b32df1bd24aee8573 ] ||
	die "WLAN board data is not the pinned bd_m81.elf"
for rev in hw2.0 hw2.1; do
	[ "$(count_of "$out_pool/wlan-hsp2/$rev")" -eq 4 ] ||
		die "HSP2 tuple $rev must hold 4 files"
done

say "== 4. record the pool manifest =="
pool_files=$(find "$out_pool" -type f | wc -l)
(cd "$out_pool" && find . -type f -printf '%P\n' | LC_ALL=C sort |
	while IFS= read -r rel; do printf '%s  %s\n' "$(sha "$out_pool/$rel")" "$rel"; done) \
	>"$out_dir/pool.manifest"
pool_manifest_sha=$(sha "$out_dir/pool.manifest")

python3 - "$out_dir/pool.json" "$out_dir/pool.manifest" "$pool_manifest_sha" \
	"$pool_files" "$manifest_sha" "$entries" "${topology_sha:-}" "${topology_baseline:-}" <<'PY'
import json
import sys
from pathlib import Path

(path, manifest, manifest_sha, files, upstream_manifest_sha, upstream_entries,
 topology_sha, topology_baseline) = sys.argv[1:9]
data = {
    "layout": "liuqin-firmware-pool/v1",
    "pool": "pool",
    "files": int(files),
    "pool_manifest": "pool.manifest",
    "pool_manifest_sha256": manifest_sha,
    "upstream_manifest_sha256": upstream_manifest_sha,
    "upstream_manifest_entries": int(upstream_entries),
    "audio_topology": None,
}
if topology_sha:
    data["audio_topology"] = {
        "sha256": topology_sha,
        "baseline": topology_baseline,
        "path": "audio-topology/Xiaomi-Pad-6-Pro-tplg.bin",
    }
Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

if [ -n "$topology" ]; then
	mkdir -p "$out_dir/audio-topology"
	cp -a "$topology" "$out_dir/audio-topology/Xiaomi-Pad-6-Pro-tplg.bin"
fi

say "== done =="
say "pool:              $out_pool"
say "files:             $pool_files"
say "pool manifest:     $out_dir/pool.manifest ($pool_manifest_sha)"
say "upstream manifest: $manifest_sha ($entries entries)"
if [ -n "$topology" ]; then
	say "audio topology:    $topology_sha ($topology_baseline baseline)"
fi
