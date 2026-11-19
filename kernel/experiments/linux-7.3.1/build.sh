#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Isolated offline experiment. Never installs into the host or tablet.
set -euo pipefail
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd -- "$HERE/../../.." && pwd)
WORK=${LIUQIN_731_WORK:-/var/tmp/liuqin-linux-7.3.1-rebuild}
OUT=${LIUQIN_731_OUT:-$PROJECT/out/kernel-7.3.1/rebuild}
JOBS=${JOBS:-10}
PREPARE_ONLY=0
PROFILE=${LIUQIN_731_PROFILE:-}
ADDON=${LIUQIN_731_ADDON:-}
EXPECTED_RELEASE=7.3.1-liuqin-exp1
SOURCE=$HERE/source.json
SERIES=("$HERE/patches/series")
ARCHIVE_DEFAULT=$PROJECT/out/kernel-7.3.1/downloads/linux-7.3.1.tar.xz
if [[ -n $PROFILE ]]; then
  PROFILE=$(realpath -- "$PROFILE")
  [[ -f $PROFILE/patches/series && -f $PROFILE/experiment.config && -f $PROFILE/release ]] || exit 2
  EXPECTED_RELEASE=$(cat "$PROFILE/release")
  if [[ -f $PROFILE/source.json ]]; then
    SOURCE=$PROFILE/source.json
    SERIES=()
    ARCHIVE_DEFAULT=
  fi
  SERIES+=("$PROFILE/patches/series")
fi
if [[ -n $ADDON ]]; then
  ADDON=$(realpath -- "$ADDON")
  [[ -n $PROFILE && $SOURCE != "$HERE/source.json" ]] || exit 2
  [[ -f $ADDON/patches/series && -f $ADDON/experiment.config && -f $ADDON/release ]] || exit 2
  EXPECTED_RELEASE=$(cat "$ADDON/release")
  SERIES+=("$ADDON/patches/series")
fi
ARCHIVE=${LIUQIN_731_ARCHIVE:-$ARCHIVE_DEFAULT}
case ${1:-} in
  --prepare-only) PREPARE_ONLY=1 ;;
  '') ;;
  *) echo "Usage: $0 [--prepare-only]; configure LIUQIN_731_WORK/OUT/ARCHIVE and JOBS in the environment" >&2; exit 2 ;;
esac
case $WORK in /*) ;; *) echo 'WORK must be absolute' >&2; exit 2 ;; esac
WORK=$(realpath -m -- "$WORK")
case $WORK in "$PROJECT/upstream"|"$PROJECT/upstream/"*) echo 'upstream/ is read-only' >&2; exit 2 ;; esac
case $WORK in *' '*|*:*) echo 'WORK must have no spaces or colons' >&2; exit 2 ;; esac
case $JOBS in ''|*[!0-9]*|0) echo 'JOBS must be positive' >&2; exit 2 ;; esac
for cmd in python3 make git tar aarch64-linux-gnu-gcc aarch64-linux-gnu-ld dtc depmod; do command -v "$cmd" >/dev/null; done
python3 - "$SOURCE" "$ARCHIVE" <<'PY'
import hashlib, json, pathlib, sys
spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
with open(sys.argv[2], 'rb') as f:
    actual = hashlib.file_digest(f, 'sha256').hexdigest()
assert actual == spec['target_sha256'], 'source archive checksum mismatch'
PY
PATCHES=()
for series in "${SERIES[@]}"; do
  while IFS= read -r name; do
    [[ -z $name || $name == \#* ]] && continue
    PATCHES+=("${series%/*}/$name")
  done < "$series"
done
if [[ $SOURCE == "$HERE/source.json" ]]; then
  # Preserve the preparation fingerprints used by existing 7.3.1 work trees.
  INPUTS=$(cd -- "$HERE"; sha256sum source.json seed.config experiment.config patches/series patches/*.patch modules/pon/* | sha256sum | cut -d' ' -f1)
  if [[ -n $PROFILE ]]; then
    EXTRA_INPUTS=$(cd -- "$PROFILE"; sha256sum release experiment.config patches/series patches/*.patch | sha256sum | cut -d' ' -f1)
    INPUTS=$(printf '%s\n%s\n' "$INPUTS" "$EXTRA_INPUTS" | sha256sum | cut -d' ' -f1)
  fi
else
  CONFIG_INPUTS=("$PROFILE/release" "$PROFILE/experiment.config")
  if [[ -n $ADDON ]]; then
    CONFIG_INPUTS+=("$ADDON/release" "$ADDON/experiment.config")
  fi
  INPUTS=$(sha256sum "$SOURCE" "$HERE/seed.config" "$HERE/experiment.config" "${CONFIG_INPUTS[@]}" \
    "${SERIES[@]}" "${PATCHES[@]}" "$HERE"/modules/pon/* | sha256sum | cut -d' ' -f1)
fi
mkdir -p "$WORK/logs"
if [[ -e $WORK/prepared.sha256 ]]; then
  [[ $(cat "$WORK/prepared.sha256") == "$INPUTS" ]] || { echo 'Inputs changed; use a fresh WORK directory.' >&2; exit 1; }
else
  [[ ! -e $WORK/src && ! -e $WORK/build ]] || { echo 'Unmarked existing source/build; choose a fresh WORK directory.' >&2; exit 1; }
  mkdir -p "$WORK/src" "$WORK/build"
  tar -xJf "$ARCHIVE" --strip-components=1 -C "$WORK/src"
  for patch in "${PATCHES[@]}"; do
    git -C "$WORK/src" apply --check "$patch"
    git -C "$WORK/src" apply "$patch"
  done
  printf '%s\n' "$INPUTS" > "$WORK/prepared.sha256"
fi
cp "$HERE/seed.config" "$WORK/build/.config"
cp "$HERE/experiment.config" "$WORK/experiment.config"
if [[ -n $PROFILE ]]; then cat "$PROFILE/experiment.config" >> "$WORK/experiment.config"; fi
if [[ -n $ADDON ]]; then cat "$ADDON/experiment.config" >> "$WORK/experiment.config"; fi
MAKE=(make -C "$WORK/src" O="$WORK/build" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=)
(cd -- "$WORK/src"; scripts/kconfig/merge_config.sh -m -O "$WORK/build" "$WORK/build/.config" "$WORK/experiment.config") > "$WORK/logs/config-merge.log" 2>&1
"${MAKE[@]}" olddefconfig > "$WORK/logs/olddefconfig.log" 2>&1
"${MAKE[@]}" prepare > "$WORK/logs/prepare.log" 2>&1
RELEASE=$("${MAKE[@]}" -s --no-print-directory kernelrelease)
[[ $RELEASE == "$EXPECTED_RELEASE" ]] || { echo "Unexpected release: $RELEASE" >&2; exit 1; }
echo "Prepared $RELEASE in $WORK"
[[ $PREPARE_ONLY == 0 ]] || exit 0
nice -n 10 "${MAKE[@]}" -j"$JOBS" Image qcom/sm8475-xiaomi-liuqin.dtb modules > "$WORK/logs/build.log" 2>&1
"${MAKE[@]}" INSTALL_MOD_PATH="$WORK/modules" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install > "$WORK/logs/modules-install.log" 2>&1
mkdir -p "$WORK/pon"
cp "$HERE/modules/pon/Makefile" "$HERE/modules/pon/afk_pon_snapshot.c" "$WORK/pon/"
"${MAKE[@]}" M="$WORK/pon" modules > "$WORK/logs/pon-build.log" 2>&1
mkdir -p "$WORK/modules/lib/modules/$RELEASE/extra"
cp "$WORK/pon/afk_pon_snapshot.ko" "$WORK/modules/lib/modules/$RELEASE/extra/"
aarch64-linux-gnu-strip --strip-debug "$WORK/modules/lib/modules/$RELEASE/extra/afk_pon_snapshot.ko"
for name in build source; do
  link="$WORK/modules/lib/modules/$RELEASE/$name"
  [[ ! -L $link ]] || rm -- "$link"
done
depmod -b "$WORK/modules" "$RELEASE" > "$WORK/logs/depmod.log" 2>&1
python3 "$HERE/collect.py" "$WORK" "$OUT"
echo "Offline build complete: $OUT"
