#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# build-kernel.sh — reproducible AArch64 cross-build of the liuqin kernel
# (Xiaomi Pad 6 Pro, SM8475) for the Fedora ARM64 + KDE port.
#
# What it does (mirrors upstream xiaomipad-6pro-mainline/tools/build-liuqin-kernel.py,
# but without its Ubuntu-GCC-13 config_sha256 gate):
#   1. extract the pinned commit from the read-only git clone with `git archive`
#      (upstream/ is never modified, no .git directory is copied), then apply
#      the device-verified project patches in kernel/project-patches/series;
#   2. arm64 defconfig -> merge_config.sh of the 10 upstream product fragments
#      -> olddefconfig, then audit the merged .config;
#   3. cross-build Image + the liuqin DTB + modules, install modules and write
#      deterministic build-info.json / SHA256SUMS / config audit / DTB report
#      into the project out/kernel directory.
#
# IMPORTANT — why the scratch tree is not under the project directory:
#   The kernel top-level Makefile rejects a source tree whose path contains a
#   space or a colon ("source directory cannot contain spaces or colons",
#   Makefile:217). This project may live under a path containing spaces, so the
#   kernel source and the O= output directory must live in a space-free scratch
#   root (default: /var/tmp/liuqin-kbuild). Only the final artifacts are copied
#   into out/kernel/. Use --build-root to relocate the scratch tree.
#
# Defaults are for this project; every path can be overridden.
#
# Usage: scripts/build-kernel.sh --help

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

SOURCE_REPO="$PROJECT_ROOT/upstream/linux-sm8450-liuqin"
SPEC_FILE="$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/kernel/source.json"
AUDIT_TSV="$PROJECT_ROOT/kernel/config/audit-symbols.tsv"
PROJECT_PATCH_DIR="$PROJECT_ROOT/kernel/project-patches"
OUT_DIR="$PROJECT_ROOT/out/kernel"
BUILD_ROOT="${LIUQIN_KBUILD_ROOT:-/var/tmp/liuqin-kbuild}"
REFERENCE_CONFIG="$PROJECT_ROOT/cache/upstream-v0.6.0/kernel-proof/.config"
CHECKOUT="product-lock"
JOBS=12
TOOLCHAIN="gcc"
LOCALVERSION="auto"
CONFIGURE_ONLY=0
REFRESH_SOURCE=0
RECONFIGURE=0
EXTRA_FRAGMENTS=()
REPRO_CHECK_DIR=""
KEEP_LOGS=1

usage() {
	cat <<'EOF'
liuqin kernel cross-build (Fedora ARM64 port, Phase 2)

Usage: scripts/build-kernel.sh [options]

Source selection:
  --source DIR            git repository of the liuqin kernel
                          (default: <project>/upstream/linux-sm8450-liuqin)
  --spec FILE             build spec JSON, supplies commit/fragments/dtb/reference sha
                          (default: <project>/upstream/xiaomipad-6pro-mainline/kernel/source.json)
  --checkout REF          git ref to build (default: product-lock)
  --refresh-source        re-extract the source tree even if it already exists

Build layout:
  --build-root DIR        space-free scratch root for source/O=/modules/logs
                          (default: $LIUQIN_KBUILD_ROOT or /var/tmp/liuqin-kbuild)
                          Must NOT contain spaces or ':' (kernel Makefile restriction).
  --out DIR               artifact output directory (default: <project>/out/kernel)
  --jobs N                parallel make jobs (default: 12)
  --toolchain gcc|clang   compiler family (default: gcc -> aarch64-linux-gnu-gcc)
  --localversion VALUE    localversion string appended to the kernel release;
                          'auto' = -g<commit12> (default, reproduces upstream
                          6.17.0-rc1-gfe81794b5e1b), 'none' = no suffix.
  --extra-fragment FILE   extra kconfig fragment appended after the upstream
                          product fragments (repeatable). Example:
                          kernel/config/liuqin-fedora.config
  --reconfigure           force a fresh defconfig+merge of .config (otherwise the
                          existing O=/.config is regenerated anyway from the spec)
  --configure-only        stop after config generation + audit (no compile)

Reporting:
  --reference-config FILE upstream product .config used for the semantic diff
                          (default: <project>/cache/upstream-v0.6.0/kernel-proof/.config,
                          pass 'none' to skip)
  --repro-check DIR       directory holding a previous build's dist/ artifacts
                          (Image, DTB, config, System.map, modules manifest);
                          result written to <out>/repro-check.txt
  --help                  show this help

Output layout (under --out):
  dist/Image                    uncompressed arm64 kernel image
  dist/<liuqin>.dtb             sm8475-xiaomi-liuqin.dtb
  dist/config                   final merged .config
  dist/System.map               symbol map of the same build
  dist/Module.symvers           symbol versions (for out-of-tree modules)
  dist/modules/lib/modules/<release>/...  installed modules (INSTALL_MOD_STRIP=1)
  dist/modules.sha256           deterministic manifest over the module tree
  dist/modules.tar.gz           deterministic tarball of dist/modules (rootfs input)
  config-audit.tsv              every audited symbol: expected/actual/status/note
  config-audit.json             machine-readable audit summary
  config-diff-vs-reference.log  semantic diff against the upstream product .config
  dtb-report.txt                decompiled-DTB compatible-string / feature report
  build-info.json               full provenance of this build
  SHA256SUMS                    hashes of the public artifacts above
  logs/                         configuration/build logs (gzipped)
EOF
}

log() { printf '[build-kernel] %s\n' "$*"; }
die() { printf '[build-kernel] ERROR: %s\n' "$*" >&2; exit 1; }

run_logged() { # run_logged LOGFILE CMD...
	local logfile=$1
	shift
	if ! "$@" >"$logfile" 2>&1; then
		printf '[build-kernel] command failed (log: %s):\n' "$logfile" >&2
		tail -n 40 "$logfile" >&2 || true
		exit 1
	fi
}

require_exec() {
	command -v "$1" >/dev/null 2>&1 || die "required executable not found: $1"
}

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
	case $1 in
	--source) SOURCE_REPO=${2:?}; shift 2 ;;
	--spec) SPEC_FILE=${2:?}; shift 2 ;;
	--checkout) CHECKOUT=${2:?}; shift 2 ;;
	--refresh-source) REFRESH_SOURCE=1; shift ;;
	--build-root) BUILD_ROOT=${2:?}; shift 2 ;;
	--out) OUT_DIR=${2:?}; shift 2 ;;
	--jobs) JOBS=${2:?}; shift 2 ;;
	--toolchain) TOOLCHAIN=${2:?}; shift 2 ;;
	--localversion) LOCALVERSION=${2:?}; shift 2 ;;
	--extra-fragment) EXTRA_FRAGMENTS+=("${2:?}"); shift 2 ;;
	--reconfigure) RECONFIGURE=1; shift ;;
	--configure-only) CONFIGURE_ONLY=1; shift ;;
	--reference-config) REFERENCE_CONFIG=${2:?}; shift 2 ;;
	--repro-check) REPRO_CHECK_DIR=${2:?}; shift 2 ;;
	--help|-h) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

case $TOOLCHAIN in gcc|clang) ;; *) die "--toolchain must be gcc or clang" ;; esac
case $JOBS in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be a positive integer"

# ---------------------------------------------------------------- preflight
require_exec git
require_exec make
require_exec tar
require_exec gzip
require_exec python3
require_exec sha256sum
require_exec dtc

[ -d "$SOURCE_REPO" ] || die "source repo not found: $SOURCE_REPO"
git -C "$SOURCE_REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $SOURCE_REPO"
[ -f "$SPEC_FILE" ] || die "spec file not found: $SPEC_FILE"
[ -f "$AUDIT_TSV" ] || die "audit table not found: $AUDIT_TSV"
if [ -f "$BUILD_ROOT/Makefile" ]; then die "build root $BUILD_ROOT looks like a kernel tree; use a scratch directory"; fi
case $BUILD_ROOT in
*' '*) die "build root contains a space, which the kernel Makefile rejects: $BUILD_ROOT" ;;
*:*) die "build root contains ':', which the kernel Makefile rejects: $BUILD_ROOT" ;;
esac
case $BUILD_ROOT in /*) ;; *) die "build root must be an absolute path: $BUILD_ROOT" ;; esac

# Cross compiler / LLVM toolchain detection.
CC_BIN=""
case $TOOLCHAIN in
gcc)
	CROSS_COMPILE=aarch64-linux-gnu-
	CC_BIN=$(command -v "${CROSS_COMPILE}gcc" || true)
	[ -n "$CC_BIN" ] || die "aarch64-linux-gnu-gcc not found (use --toolchain clang or install the cross compiler)"
	require_exec "${CROSS_COMPILE}ld"
	MAKE_TOOLCHAIN=("ARCH=arm64" "CROSS_COMPILE=$CROSS_COMPILE")
	KERNEL_CC=${CC_BIN}
	LD_BIN=${CROSS_COMPILE}ld
	AR_BIN=${CROSS_COMPILE}ar
	;;
clang)
	CC_BIN=$(command -v clang || true)
	[ -n "$CC_BIN" ] || die "clang not found"
	require_exec ld.lld
	require_exec llvm-ar
	CROSS_COMPILE=aarch64-linux-gnu-
	MAKE_TOOLCHAIN=("ARCH=arm64" "LLVM=1" "CROSS_COMPILE=$CROSS_COMPILE")
	KERNEL_CC=$CC_BIN
	LD_BIN=ld.lld
	AR_BIN=llvm-ar
	;;
esac
require_exec file
require_exec readelf

# ---------------------------------------------------------------- spec/commit
SPEC_PROJECT=$(dirname -- "$(dirname -- "$SPEC_FILE")")
mapfile -t SPEC_VALUES < <(python3 - "$SPEC_FILE" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
print(spec["commit"])
print(spec["dtb"])
print(spec.get("config_sha256", ""))
print(spec.get("upstream_base", ""))
print(spec.get("branch", ""))
for fragment in spec["config_fragments"]:
    print("fragment=" + fragment)
PY
)
SPEC_COMMIT=${SPEC_VALUES[0]}
DTB_REL=${SPEC_VALUES[1]}
SPEC_CONFIG_SHA=${SPEC_VALUES[2]}
SPEC_UPSTREAM_BASE=${SPEC_VALUES[3]}
SPEC_BRANCH=${SPEC_VALUES[4]}
SPEC_FRAGMENTS=()
for value in "${SPEC_VALUES[@]:5}"; do SPEC_FRAGMENTS+=("${value#fragment=}"); done
[ "${#SPEC_FRAGMENTS[@]}" -gt 0 ] || die "spec has no config_fragments: $SPEC_FILE"

COMMIT=$(git -C "$SOURCE_REPO" rev-parse --verify "$CHECKOUT^{commit}" 2>/dev/null) ||
	die "cannot resolve '$CHECKOUT' in $SOURCE_REPO"
[ "$(git -C "$SOURCE_REPO" cat-file -t "$COMMIT")" = "commit" ] || die "not a commit: $CHECKOUT"
if [ "$COMMIT" != "$SPEC_COMMIT" ]; then
	die "checkout '$CHECKOUT' resolves to $COMMIT but spec expects $SPEC_COMMIT; update the tag/spec together or pass an explicit spec"
fi
TREE=$(git -C "$SOURCE_REPO" rev-parse "$COMMIT^{tree}")
SHORT12=$(printf '%s' "$COMMIT" | cut -c1-12)
COMMIT_DATE=$(git -C "$SOURCE_REPO" show -s --format=%cI "$COMMIT")
COMMIT_EPOCH=$(git -C "$SOURCE_REPO" show -s --format=%ct "$COMMIT")
case $LOCALVERSION in
auto) LOCALVERSION_VALUE="-g$SHORT12" ;;
none) LOCALVERSION_VALUE="" ;;
*) LOCALVERSION_VALUE=$LOCALVERSION ;;
esac
LV_ARGS=()
if [ -n "$LOCALVERSION_VALUE" ]; then LV_ARGS=("LOCALVERSION=$LOCALVERSION_VALUE"); fi

mkdir -p "$BUILD_ROOT" "$OUT_DIR" "$OUT_DIR/logs"
SRC_DIR="$BUILD_ROOT/src"
OBJ_DIR="$BUILD_ROOT/build"
FRAGMENT_DIR="$BUILD_ROOT/fragments"
MODULE_ROOT="$BUILD_ROOT/modules-root"
WORK_LOG_DIR="$BUILD_ROOT/logs"
mkdir -p "$WORK_LOG_DIR"
STARTED_AT=$(date -Is)
START_EPOCH=$(date +%s)
log "scratch root : $BUILD_ROOT"
log "source       : $SOURCE_REPO @ $CHECKOUT ($COMMIT)"
log "kernel tree  : $TREE (commit date $COMMIT_DATE)"

# `git -C ... show -s` of a shallow clone is enough; never checkout in the clone.
if [ "$REFRESH_SOURCE" -eq 1 ] || [ ! -f "$SRC_DIR/Makefile" ] || [ ! -d "$SRC_DIR/arch/arm64" ]; then
	log "extracting source tree with git archive (upstream clone stays untouched)"
	rm -rf "$SRC_DIR"
	mkdir -p "$SRC_DIR"
	git -C "$SOURCE_REPO" archive --format=tar "$COMMIT" | tar -x -p --no-same-owner -C "$SRC_DIR"
	[ -f "$SRC_DIR/Makefile" ] || die "source extraction failed"
	EXTRACTED=1
else
	log "reusing existing source tree: $SRC_DIR"
	EXTRACTED=0
fi

# ---------------------------------------------------------------- project patches
# Device-verified fixes owned by this project (kernel/project-patches/series),
# applied to the scratch tree only; the upstream clone is never modified.
declare -a PROJECT_PATCHES=()
if [ -f "$PROJECT_PATCH_DIR/series" ]; then
	while read -r patch_name; do
		case $patch_name in ''|'#'*) continue ;; esac
		patch_file="$PROJECT_PATCH_DIR/$patch_name"
		[ -f "$patch_file" ] || die "project patch missing: $patch_file"
		if (cd "$SRC_DIR" && git apply --check --reverse "$patch_file" >/dev/null 2>&1); then
			log "project patch already applied: $patch_name"
		else
			(cd "$SRC_DIR" && git apply "$patch_file") || die "project patch does not apply: $patch_name"
			log "applied project patch: $patch_name"
		fi
		PROJECT_PATCHES+=("$patch_file")
	done <"$PROJECT_PATCH_DIR/series"
fi

# ---------------------------------------------------------------- fragments
log "preparing config fragments (${#SPEC_FRAGMENTS[@]} upstream + ${#EXTRA_FRAGMENTS[@]} extra)"
rm -rf "$FRAGMENT_DIR"
mkdir -p "$FRAGMENT_DIR"
fragment_index=0
declare -a FRAGMENT_FILES=()
for rel in "${SPEC_FRAGMENTS[@]}"; do
	fragment_index=$((fragment_index + 1))
	src_fragment="$SPEC_PROJECT/$rel"
	[ -f "$src_fragment" ] || die "fragment missing: $src_fragment"
	dst_fragment=$(printf '%s/%02d-%s' "$FRAGMENT_DIR" "$fragment_index" "$(basename -- "$rel")")
	cp -- "$src_fragment" "$dst_fragment"
	FRAGMENT_FILES+=("$dst_fragment")
done
if [ "${#EXTRA_FRAGMENTS[@]}" -gt 0 ]; then
	for extra in "${EXTRA_FRAGMENTS[@]}"; do
		[ -f "$extra" ] || die "extra fragment missing: $extra"
		fragment_index=$((fragment_index + 1))
		dst_fragment=$(printf '%s/%02d-extra-%s' "$FRAGMENT_DIR" "$fragment_index" "$(basename -- "$extra")")
		cp -- "$extra" "$dst_fragment"
		FRAGMENT_FILES+=("$dst_fragment")
	done
fi
log "fragment order:"
for fragment in "${FRAGMENT_FILES[@]}"; do log "  $(basename -- "$fragment")"; done

# ---------------------------------------------------------------- configure
if [ "$RECONFIGURE" -eq 1 ]; then
	rm -rf "$OBJ_DIR"
fi
mkdir -p "$OBJ_DIR"
log "generating configuration (defconfig -> merge_config.sh -> olddefconfig)"
run_logged "$WORK_LOG_DIR/01-defconfig.log" \
	make -C "$SRC_DIR" O="$OBJ_DIR" "${MAKE_TOOLCHAIN[@]}" defconfig
run_logged "$WORK_LOG_DIR/02-merge-config.log" \
	sh "$SRC_DIR/scripts/kconfig/merge_config.sh" -m -O "$OBJ_DIR" "$OBJ_DIR/.config" "${FRAGMENT_FILES[@]}"
run_logged "$WORK_LOG_DIR/03-olddefconfig.log" \
	make -C "$SRC_DIR" O="$OBJ_DIR" "${MAKE_TOOLCHAIN[@]}" olddefconfig
[ -f "$OBJ_DIR/.config" ] || die "configuration step produced no .config"
CONFIG_SHA=$(sha256sum "$OBJ_DIR/.config" | cut -d' ' -f1)
log "merged .config sha256: $CONFIG_SHA"
if [ "$CONFIG_SHA" = "$SPEC_CONFIG_SHA" ]; then
	log "config sha256 matches the upstream recorded product config"
else
	log "config sha256 differs from the upstream recorded config ($SPEC_CONFIG_SHA);"
	log "expected — that hash pins the Ubuntu GCC 13 toolchain identity; see the semantic diff below"
fi
if [ -s "$WORK_LOG_DIR/02-merge-config.log" ] &&
	grep -qiE 'requested .* not in final|not in final .config' "$WORK_LOG_DIR/02-merge-config.log"; then
	log "WARNING: merge_config reported fragment values that did not survive olddefconfig:"
	grep -iE 'requested .* not in final|not in final .config' "$WORK_LOG_DIR/02-merge-config.log" | head -20 >&2 || true
fi

# ---------------------------------------------------------------- toolchain metadata
compiler_version=$("$CC_BIN" --version 2>/dev/null | head -n 1 || true)
compiler_sha256=$(sha256sum "$(command -v "$CC_BIN")" | cut -d' ' -f1)
ld_version=$("$LD_BIN" --version 2>/dev/null | head -n 1 || true)
ld_sha256=$(sha256sum "$(command -v "$LD_BIN")" | cut -d' ' -f1)
ar_version=$("$AR_BIN" --version 2>/dev/null | head -n 1 || true)
HOST_KERNEL=$(uname -srm)
HOST_CPU_COUNT=$(nproc)

# ---------------------------------------------------------------- config report
CONFIG_AUDIT_TSV="$OUT_DIR/config-audit.tsv"
CONFIG_AUDIT_JSON="$OUT_DIR/config-audit.json"
CONFIG_DIFF_LOG="$OUT_DIR/config-diff-vs-reference.log"
CONFIG_DIFF_JSON="$OUT_DIR/config-diff-vs-reference.json"
if [ "$REFERENCE_CONFIG" = "none" ]; then REFERENCE_CONFIG=""; fi
python3 - "$AUDIT_TSV" "$OBJ_DIR/.config" "$CONFIG_AUDIT_TSV" "$CONFIG_AUDIT_JSON" <<'PY'
import json, re, sys

audit_tsv, config_path, out_tsv, out_json = sys.argv[1:5]

def parse_config(path):
    config = {}
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = re.match(r"CONFIG_([A-Za-z0-9_]+)=(.*)$", line)
            if match:
                config[match.group(1)] = match.group(2)
                continue
            match = re.match(r"# CONFIG_([A-Za-z0-9_]+) is not set$", line)
            if match:
                config[match.group(1)] = "n"
    return config

config = parse_config(config_path)
rows = []
with open(audit_tsv, errors="replace") as handle:
    for line in handle:
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3:
            continue
        parts += [""] * (4 - len(parts))
        rows.append(parts)

results = []
counts = {"OK": 0, "MISSING": 0, "MISMATCH": 0, "UNEXPECTED": 0, "N/A": 0}
for symbol, cls, expected, note in rows:
    actual_raw = config.get(symbol)
    actual = "absent" if actual_raw is None else actual_raw
    status = "OK"
    if expected.startswith("contains:"):
        needle = expected.split(":", 1)[1]
        if actual_raw is not None and needle in actual_raw:
            status = "OK"
        else:
            status = "MISSING"
    elif expected == "absent":
        status = "OK" if actual_raw is None else "MISMATCH"
    elif expected == "n":
        status = "OK" if actual_raw in (None, "n") else "UNEXPECTED"
    elif expected in ("y", "m"):
        if actual_raw == expected:
            status = "OK"
        elif actual_raw in (None, "n"):
            status = "MISSING"
        else:
            status = "MISMATCH"
    elif expected == "any":
        status = "OK"
    else:
        status = "OK" if actual == expected else "MISMATCH"
    counts[status] = counts.get(status, 0) + 1
    results.append(dict(symbol=symbol, cls=cls, expected=expected, actual=actual,
                        status=status, note=note))

with open(out_tsv, "w") as handle:
    handle.write("# symbol\tclass\texpected\tactual\tstatus\tnote\n")
    for row in results:
        handle.write("\t".join([row["symbol"], row["cls"], row["expected"],
                                row["actual"], row["status"], row["note"]]) + "\n")

missing = [row for row in results if row["status"] == "MISSING"]
missing_fedora = [row for row in missing if row["cls"] == "fedora"]
missing_other = [row for row in missing if row["cls"] != "fedora"]
summary = dict(config_sha256=None, counts=counts,
               missing=[row["symbol"] for row in missing],
               missing_fedora=[row["symbol"] for row in missing_fedora],
               missing_other=[row["symbol"] for row in missing_other],
               unexpected=[row["symbol"] for row in results if row["status"] == "UNEXPECTED"],
               fedora_ready=not missing_fedora)
with open(out_json, "w") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("config audit: %d symbols, %d ok, %d missing (%d Fedora)" % (
    len(results), counts["OK"], len(missing), len(missing_fedora)))
for row in missing:
    print("  MISSING  %-28s expected %-9s (%s)" % (row["symbol"], row["expected"], row["cls"]))
PY
python3 - "$OBJ_DIR/.config" "$CONFIG_AUDIT_JSON" <<'PY'
import json, sys
config_path, audit_json = sys.argv[1:3]
summary = json.load(open(audit_json))
import hashlib
summary["config_sha256"] = hashlib.sha256(open(config_path, "rb").read()).hexdigest()
json.dump(summary, open(audit_json, "w"), indent=2, sort_keys=True)
open(audit_json, "a").write("\n")
PY

# Semantic diff against the upstream product config (if a reference exists).
if [ -n "$REFERENCE_CONFIG" ] && [ -f "$REFERENCE_CONFIG" ]; then
	python3 - "$REFERENCE_CONFIG" "$OBJ_DIR/.config" "$CONFIG_DIFF_LOG" "$CONFIG_DIFF_JSON" <<'PY'
import difflib, json, re, sys

reference_path, config_path, out_log, out_json = sys.argv[1:5]

def parse(path):
    values, order = {}, []
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = re.match(r"(?:CONFIG_([A-Za-z0-9_]+)=(.*)|# CONFIG_([A-Za-z0-9_]+) is not set)$", line)
            if not match:
                continue
            if match.group(1) is not None:
                symbol, value = match.group(1), match.group(2)
            else:
                symbol, value = match.group(3), "n"
            values[symbol] = value
            order.append(symbol)
    return values, order

reference, reference_order = parse(reference_path)
ours, ours_order = parse(config_path)

TOOLCHAIN_DERIVED = [
    r"^CC_VERSION_TEXT$", r"^(GCC|CLANG|AS|LD|LLD|RUSTC|RUSTC_LLVM|PAHOLE)_VERSION$",
    r"^CC_HAS_", r"^TOOLS_SUPPORT_", r"^PAHOLE_HAS_", r"^CC_IS_",
    r"^GCC_PLUGINS$", r"^GCC_PLUGIN_", r"^RANDSTRUCT_(FULL|PERFORMANCE)$",
    r"^RELR$", r"^KSTACK_ERASE$", r"^ARCH_HAS_RELR$",
]
toolchain_re = re.compile("|".join(TOOLCHAIN_DERIVED))

def boolish(value):
    return value is None or value in ("y", "m", "n")

toolchain_differences, semantic_differences = [], []
for symbol in dict.fromkeys(reference_order + ours_order):
    old = reference.get(symbol)
    new = ours.get(symbol)
    if old == new:
        continue
    # absent and "not set" are the same disabled state for bool/tristate symbols
    if boolish(old) and boolish(new):
        old_norm = "n" if old is None else old
        new_norm = "n" if new is None else new
        if old_norm == new_norm:
            continue
    entry = dict(symbol=symbol, reference=old, ours=new)
    if toolchain_re.search(symbol):
        toolchain_differences.append(entry)
    else:
        semantic_differences.append(entry)

with open(out_log, "w") as handle:
    handle.write("# semantic diff: merged config vs upstream product reference\n")
    handle.write("# reference: %s\n# ours     : %s\n" % (reference_path, config_path))
    handle.write("# The unified diff above is raw; the summary below folds absent/disabled\n"
                 "# states and classifies compiler/tool-capability symbols that necessarily differ.\n\n")
    diff = difflib.unified_diff(
        open(reference_path, errors="replace").read().splitlines(keepends=True),
        open(config_path, errors="replace").read().splitlines(keepends=True),
        fromfile="upstream-product.config", tofile="liuqin-merged.config", n=2)
    handle.writelines(diff)
    handle.write("\n\n# ---- semantic summary ----\n")
    handle.write("# toolchain/tool-capability derived differences: %d\n" % len(toolchain_differences))
    for entry in toolchain_differences:
        handle.write("#   %-32s reference=%s -> ours=%s\n" %
                     (entry["symbol"], entry["reference"], entry["ours"]))
    handle.write("# substantive differences: %d\n" % len(semantic_differences))
    for entry in semantic_differences:
        handle.write("#   %-32s reference=%s -> ours=%s\n" %
                     (entry["symbol"], entry["reference"], entry["ours"]))
    handle.write("\nverdict: %s\n" % ("IDENTICAL semantics (only toolchain-capability symbols differ)"
                                     if not semantic_differences else "SEMANTIC DIFFERENCES PRESENT"))

summary = dict(reference_path=reference_path,
               toolchain_derived_differences=toolchain_differences,
               semantic_differences=semantic_differences,
               verdict=("identical-semantics" if not semantic_differences else "semantic-differences"))
with open(out_json, "w") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
print("config semantic diff vs reference: %d substantive, %d toolchain-derived" %
      (len(semantic_differences), len(toolchain_differences)))
PY
else
	printf 'reference config not available: %s\n' "$REFERENCE_CONFIG" >"$CONFIG_DIFF_LOG"
	printf '{"verdict": "skipped", "reason": "no reference config"}\n' >"$CONFIG_DIFF_JSON"
fi

if [ "$CONFIGURE_ONLY" -eq 1 ]; then
	log "configuration complete (--configure-only): $OBJ_DIR/.config"
	log "audit: $CONFIG_AUDIT_TSV"
	exit 0
fi

# ---------------------------------------------------------------- build
KERNELRELEASE=$(make -s --no-print-directory -C "$SRC_DIR" O="$OBJ_DIR" "${MAKE_TOOLCHAIN[@]}" "${LV_ARGS[@]}" \
	kernelrelease 2>/dev/null | grep -E '^[0-9]+\.' | tail -n 1)
[ -n "$KERNELRELEASE" ] || die "could not determine kernel release string"
log "kernel release: $KERNELRELEASE"

KBUILD_ENV=(
	"KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-liuqin}"
	"KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-build}"
	"KBUILD_BUILD_VERSION=${KBUILD_BUILD_VERSION:-1}"
	"KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-$COMMIT_DATE}"
)
# Normalize compilation paths so two builds in different scratch roots are
# byte-identical (debug info / __FILE__ style paths only).
PATH_MAP=(
	"KCFLAGS=-ffile-prefix-map=$SRC_DIR=/build/linux -ffile-prefix-map=$OBJ_DIR=/build/kernel"
	"KAFLAGS=-ffile-prefix-map=$SRC_DIR=/build/linux -ffile-prefix-map=$OBJ_DIR=/build/kernel"
)
MAKE_BUILD=(
	make -C "$SRC_DIR" O="$OBJ_DIR" "${MAKE_TOOLCHAIN[@]}"
	-j"$JOBS" "${KBUILD_ENV[@]}" "${PATH_MAP[@]}"
)
if [ -n "$LOCALVERSION_VALUE" ]; then
	MAKE_BUILD+=("LOCALVERSION=$LOCALVERSION_VALUE")
fi
BUILD_TARGETS=(Image "$DTB_REL" modules)
log "building: ${BUILD_TARGETS[*]} -j$JOBS (TOOLCHAIN=$TOOLCHAIN)"
BUILD_LOG="$WORK_LOG_DIR/04-build.log"
BUILD_START_EPOCH=$(date +%s)
if ! /usr/bin/time -v "${MAKE_BUILD[@]}" "${BUILD_TARGETS[@]}" >"$BUILD_LOG" 2>&1; then
	printf '[build-kernel] build failed; last 60 log lines:\n' >&2
	tail -n 60 "$BUILD_LOG" >&2 || true
	exit 1
fi
BUILD_END_EPOCH=$(date +%s)
BUILD_SECONDS=$((BUILD_END_EPOCH - BUILD_START_EPOCH))
MAX_RSS_KB=$(grep -oE 'Maximum resident set size \(kbytes\): [0-9]+' "$BUILD_LOG" | grep -oE '[0-9]+' | tail -n 1 || true)
ELAPSED_WALL=$(grep -oE 'Elapsed \(wall clock\) time .*: .*' "$BUILD_LOG" | tail -n 1 || true)
log "build finished in ${BUILD_SECONDS}s (maxRSS ${MAX_RSS_KB:-?} kB)"

# ---------------------------------------------------------------- modules install
log "installing modules (INSTALL_MOD_STRIP=1) into $MODULE_ROOT"
rm -rf "$MODULE_ROOT"
mkdir -p "$MODULE_ROOT"
run_logged "$WORK_LOG_DIR/05-modules-install.log" \
	make -C "$SRC_DIR" O="$OBJ_DIR" "${MAKE_TOOLCHAIN[@]}" "${LV_ARGS[@]}" modules_install \
	INSTALL_MOD_PATH="$MODULE_ROOT" INSTALL_MOD_STRIP=1
MODULE_DIR="$MODULE_ROOT/lib/modules/$KERNELRELEASE"
[ -d "$MODULE_DIR" ] || die "modules_install produced no $MODULE_DIR"
# Drop the build/source symlinks: they point at the scratch tree and must not
# leak into the rootfs package.
rm -f "$MODULE_DIR/build" "$MODULE_DIR/source"
MODULE_COUNT=$(find "$MODULE_DIR" -name '*.ko' | wc -l)

# ---------------------------------------------------------------- artifacts
DIST_DIR="$OUT_DIR/dist"
log "collecting artifacts into $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/modules"
cp -f "$OBJ_DIR/arch/arm64/boot/Image" "$DIST_DIR/Image"
cp -f "$OBJ_DIR/arch/arm64/boot/dts/$DTB_REL" "$DIST_DIR/$(basename -- "$DTB_REL")"
cp -f "$OBJ_DIR/.config" "$DIST_DIR/config"
cp -f "$OBJ_DIR/System.map" "$DIST_DIR/System.map"
cp -f "$OBJ_DIR/Module.symvers" "$DIST_DIR/Module.symvers"
cp -a "$MODULE_ROOT/lib" "$DIST_DIR/modules/"
VMLINUX_SHA=""
if [ -f "$OBJ_DIR/vmlinux" ]; then
	VMLINUX_SHA=$(sha256sum "$OBJ_DIR/vmlinux" | cut -d' ' -f1)
fi

# Deterministic module manifest and tarball (rootfs / boot.img inputs).
python3 - "$DIST_DIR/modules" "$DIST_DIR/modules.sha256" <<'PY'
import hashlib, os, sys
root, out = sys.argv[1:3]
rows = []
for base, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root)
        if os.path.islink(path):
            rows.append(("L " + os.readlink(path), rel))
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        rows.append((digest.hexdigest(), rel))
with open(out, "w") as handle:
    handle.write("# sha256 / symlink target  path (relative to dist/modules)\n")
    for digest, rel in sorted(rows, key=lambda row: row[1]):
        handle.write("%s  %s\n" % (digest, rel))
print("modules manifest: %d entries" % len(rows))
PY
TAR_EPOCH=$COMMIT_EPOCH
tar --sort=name --mtime="@$TAR_EPOCH" --owner=0 --group=0 --numeric-owner \
	-C "$DIST_DIR/modules" -cf - lib | gzip -9 -n >"$DIST_DIR/modules.tar.gz"

# ---------------------------------------------------------------- DTB report
DTB_REPORT="$OUT_DIR/dtb-report.txt"
DTC_BIN="$OBJ_DIR/scripts/dtc/dtc"
[ -x "$DTC_BIN" ] || DTC_BIN=$(command -v dtc)
DTB_PATH="$DIST_DIR/$(basename -- "$DTB_REL")"
"$DTC_BIN" -I dtb -O dts -q "$DTB_PATH" >"$BUILD_ROOT/dtb-decompiled.dts"
python3 - "$BUILD_ROOT/dtb-decompiled.dts" "$DTB_PATH" "$DTB_REPORT" "$KERNELRELEASE" <<'PY'
import hashlib, re, sys

dts_path, dtb_path, out_path, kernel_release = sys.argv[1:5]
text = open(dts_path, errors="replace").read()
compatibles = []
for match in re.finditer(r'compatible\s*=\s*((?:"[^"]*"\s*,?\s*)+)', text):
    for item in re.findall(r'"([^"]*)"', match.group(1)):
        item = item.strip()
        if item and item not in compatibles:
            compatibles.append(item)

features = [
    ("display panel (Li-Po NT36532)", ["xiaomi,pipa-nt36532"]),
    ("display controller (MDSS/DPU)", ["qcom,sm8475-mdss", "qcom,sm8550-mdss", "qcom,sm8450-mdss"]),
    ("touchscreen NT36523/NT36532", ["novatek,NVT-ts-spi"]),
    ("magnetic keyboard (WN8030)", ["xiaomi,liuqin-keyboard", "nanosic,wn8030"]),
    ("speaker amps (CS35L41 x4)", ["cirrus,cs35l41"]),
    ("codec (WCD938x)", ["qcom,wcd9380-codec", "qcom,wcd9385-codec"]),
    ("sound card (SM8450)", ["qcom,sm8450-sndcard"]),
    ("Wi-Fi (WCN6855 PCIe)", ["pci17cb,1103"]),
    ("Bluetooth (WCN6855)", ["qcom,wcn6855-bt"]),
    ("fingerprint (FPC1264)", ["fpc,fpc1020"]),
    ("sensors DSP (SLPI remoteproc)", ["qcom,sm8450-slpi-pas", "qcom,sm8475-slpi-pas", "qcom,slpi-pas"]),
    ("fastrpc / SSC", ["qcom,fastrpc"]),
    ("backlight (KTZ8866)", ["kinetic,ktz8866"]),
    ("USB3+DP combo PHY", ["qcom,sm8475-qmp-usb3-dp-phy", "qcom,sm8450-qmp-usb3-dp-phy"]),
    ("PMIC GLINK (USB-C/charger)", ["qcom,sm8475-pmic-glink", "qcom,sm8450-pmic-glink"]),
    ("UFS storage", ["qcom,sm8450-ufshc", "qcom,ufshc"]),
    ("GPU (Adreno)", ["qcom,adreno-730.1", "qcom,adreno-730", "qcom,adreno"]),
]
with open(out_path, "w") as handle:
    handle.write("# liuqin DTB report\n")
    handle.write("kernel_release: %s\n" % kernel_release)
    handle.write("dtb: %s\n" % dtb_path)
    handle.write("dtb_sha256: %s\n" % hashlib.sha256(open(dtb_path, "rb").read()).hexdigest())
    handle.write("dtb_size: %d\n" % len(open(dtb_path, "rb").read()))
    handle.write("compatible_strings: %d\n\n" % len(compatibles))
    handle.write("## feature presence\n")
    missing = []
    for name, needles in features:
        found = next((needle for needle in needles if needle in compatibles), None)
        if found:
            handle.write("PASS  %-34s %s\n" % (name, found))
        else:
            handle.write("FAIL  %-34s (none of %s)\n" % (name, ", ".join(needles)))
            missing.append(name)
    handle.write("\n## all compatible strings (sorted)\n")
    for item in sorted(compatibles):
        handle.write("%s\n" % item)
    handle.write("\nmissing_features: %s\n" % (", ".join(missing) if missing else "none"))
print("DTB report: %d compatible strings, %d missing features" % (len(compatibles), len(missing)))
PY

# ---------------------------------------------------------------- reproducibility check
REPRO_REPORT="$OUT_DIR/repro-check.txt"
if [ -n "$REPRO_CHECK_DIR" ]; then
	python3 - "$REPRO_CHECK_DIR" "$DIST_DIR" "$REPRO_REPORT" "$KERNELRELEASE" <<'PY'
import hashlib, os, sys

previous, current, out_path, kernel_release = sys.argv[1:5]

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

checks = ["Image", "System.map", "config"]
dtbs = sorted(name for name in os.listdir(previous) if name.endswith(".dtb"))
checks += dtbs
mod_manifest = []
for base, dirs, files in os.walk(os.path.join(current, "modules")):
    dirs.sort()
    for name in sorted(files):
        if name.endswith(".ko"):
            path = os.path.join(base, name)
            mod_manifest.append((os.path.relpath(path, os.path.join(current, "modules")), sha256(path)))
lines = ["# reproducibility check", "kernel_release: %s" % kernel_release,
         "previous_build: %s" % previous, "current_build: %s" % current, ""]
ok = True
for name in checks:
    old_path = os.path.join(previous, name)
    new_path = os.path.join(current, name)
    if not (os.path.isfile(old_path) and os.path.isfile(new_path)):
        lines.append("SKIP  %-16s (missing on one side)" % name)
        continue
    if sha256(old_path) == sha256(new_path):
        lines.append("SAME  %-16s %s" % (name, sha256(new_path)))
    else:
        ok = False
        lines.append("DIFF  %-16s old=%s new=%s" % (name, sha256(old_path), sha256(new_path)))
old_manifest_path = os.path.join(previous, "modules.sha256")
new_manifest_path = os.path.join(current, "modules.sha256")
if os.path.isfile(old_manifest_path) and os.path.isfile(new_manifest_path):
    old_lines = [line for line in open(old_manifest_path) if line.strip() and not line.startswith("#")]
    new_lines = [line for line in open(new_manifest_path) if line.strip() and not line.startswith("#")]
    same = old_lines == new_lines
    ok = ok and same
    lines.append("%s  module-tree manifest (%d entries)" % ("SAME" if same else "DIFF", len(new_lines)))
lines.append("")
lines.append("verdict: %s" % ("BIT-IDENTICAL" if ok else "DIFFERENCES FOUND"))
open(out_path, "w").write("\n".join(lines) + "\n")
print("reproducibility check: %s" % ("BIT-IDENTICAL" if ok else "DIFFERENCES FOUND"))
PY
else
	printf 'not requested (use --repro-check <dir> after a second clean build)\n' >"$REPRO_REPORT"
fi

# ---------------------------------------------------------------- build-info.json
KV_FILE="$BUILD_ROOT/build-info.kv"
: >"$KV_FILE"
kv() { printf '%s\t%s\n' "$1" "$2" >>"$KV_FILE"; }
kv schema_version "2"
kv build_kind "cross-build-baseline-product-config"
kv kernel_version "$(make -s --no-print-directory -C "$SRC_DIR" O="$OBJ_DIR" "${MAKE_TOOLCHAIN[@]}" kernelversion 2>/dev/null | grep -E '^[0-9]+\.' | tail -n 1 || true)"
kv kernel_release "$KERNELRELEASE"
kv source_repo "$SOURCE_REPO"
kv source_checkout "$CHECKOUT"
kv source_commit "$COMMIT"
kv source_short "$SHORT12"
kv source_tree "$TREE"
kv source_commit_date "$COMMIT_DATE"
kv source_extracted "$EXTRACTED"
kv source_dir "$SRC_DIR"
kv spec_file "$SPEC_FILE"
kv spec_branch "$SPEC_BRANCH"
kv spec_upstream_base "$SPEC_UPSTREAM_BASE"
kv spec_config_sha256 "$SPEC_CONFIG_SHA"
kv config_sha256 "$CONFIG_SHA"
kv localversion "$LOCALVERSION_VALUE"
kv toolchain "$TOOLCHAIN"
kv compiler "$(command -v "$CC_BIN")"
kv compiler_version "$compiler_version"
kv compiler_sha256 "$compiler_sha256"
kv linker "$LD_BIN"
kv linker_version "$ld_version"
kv linker_sha256 "$ld_sha256"
kv archiver "$AR_BIN"
kv archiver_version "$ar_version"
kv host_kernel "$HOST_KERNEL"
kv host_cpus "$HOST_CPU_COUNT"
kv jobs "$JOBS"
kv started_at "$STARTED_AT"
kv finished_at "$(date -Is)"
kv build_seconds "$BUILD_SECONDS"
kv max_rss_kb "${MAX_RSS_KB:-}"
kv elapsed_wall "$ELAPSED_WALL"
kv kbuild_timestamp "${KBUILD_BUILD_TIMESTAMP:-$COMMIT_DATE}"
kv kbuild_user "${KBUILD_BUILD_USER:-liuqin}"
kv kbuild_host "${KBUILD_BUILD_HOST:-build}"
kv kbuild_version "${KBUILD_BUILD_VERSION:-1}"
kv kcflags "${PATH_MAP[0]#KCFLAGS=}"
kv module_count "$MODULE_COUNT"
kv module_dir "$MODULE_DIR"
kv vmlinux_sha256 "$VMLINUX_SHA"
kv repro_check_dir "$REPRO_CHECK_DIR"
kv reference_config "$REFERENCE_CONFIG"
for fragment in "${FRAGMENT_FILES[@]}"; do
	printf 'fragment\t%s\t%s\n' "$(basename -- "$fragment")" "$(sha256sum "$fragment" | cut -d' ' -f1)" >>"$KV_FILE"
done
for patch_file in "${PROJECT_PATCHES[@]}"; do
	printf 'project_patch\t%s\t%s\n' "$(basename -- "$patch_file")" "$(sha256sum "$patch_file" | cut -d' ' -f1)" >>"$KV_FILE"
done
kv command "make -C $SRC_DIR O=$OBJ_DIR ${MAKE_TOOLCHAIN[*]} -j$JOBS ${KBUILD_ENV[*]} KCFLAGS=... KAFLAGS=... ${LOCALVERSION_VALUE:+LOCALVERSION=$LOCALVERSION_VALUE} ${BUILD_TARGETS[*]}"

python3 - "$KV_FILE" "$OUT_DIR" "$DIST_DIR" "$BUILD_ROOT" <<'PY'
import hashlib, json, os, re, sys

kv_path, out_dir, dist_dir, build_root = sys.argv[1:5]
data = {}
fragments = []
project_patches = []
with open(kv_path) as handle:
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0]:
            continue
        if parts[0] == "fragment" and len(parts) == 3:
            fragments.append({"name": parts[1], "sha256": parts[2]})
        elif parts[0] == "project_patch" and len(parts) == 3:
            project_patches.append({"name": parts[1], "sha256": parts[2]})
        else:
            data[parts[0]] = parts[1] if len(parts) > 1 else ""

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

artifacts = {}
for name in ("Image", "config", "System.map", "Module.symvers", "modules.tar.gz",
             "modules.sha256", "config-audit.tsv", "config-audit.json",
             "config-diff-vs-reference.log", "dtb-report.txt"):
    path = os.path.join(dist_dir, name)
    if os.path.isfile(path):
        artifacts["dist/" + name] = {
            "sha256": sha256(path),
            "size": os.path.getsize(path),
        }
for name in sorted(os.listdir(dist_dir)):
    if name.endswith(".dtb"):
        path = os.path.join(dist_dir, name)
        artifacts["dist/" + name] = {"sha256": sha256(path), "size": os.path.getsize(path)}

audit = {}
audit_json = os.path.join(out_dir, "config-audit.json")
if os.path.isfile(audit_json):
    audit = json.load(open(audit_json))
diff = {}
diff_json = os.path.join(out_dir, "config-diff-vs-reference.json")
if os.path.isfile(diff_json):
    diff = json.load(open(diff_json))

info = {
    "schema_version": int(data.get("schema_version", "2")),
    "build_kind": data.get("build_kind", ""),
    "kernel_version": data.get("kernel_version", ""),
    "kernel_release": data.get("kernel_release", ""),
    "source": {
        "repo": data.get("source_repo", ""),
        "checkout": data.get("source_checkout", ""),
        "commit": data.get("source_commit", ""),
        "tree": data.get("source_tree", ""),
        "commit_date": data.get("source_commit_date", ""),
        "extracted_with_git_archive": data.get("source_extracted", "") == "1",
        "scratch_source_dir": data.get("source_dir", ""),
        "upstream_worktree_modified": False,
        "project_patches": project_patches,
    },
    "spec": {
        "file": data.get("spec_file", ""),
        "branch": data.get("spec_branch", ""),
        "upstream_base": data.get("spec_upstream_base", ""),
        "recorded_config_sha256": data.get("spec_config_sha256", ""),
    },
    "config": {
        "sha256": data.get("config_sha256", ""),
        "matches_upstream_recorded_sha": data.get("config_sha256", "") == data.get("spec_config_sha256", ""),
        "fragments": fragments,
        "audit": audit,
        "reference_diff": diff,
    },
    "toolchain": {
        "kind": data.get("toolchain", ""),
        "compiler": data.get("compiler", ""),
        "compiler_version": data.get("compiler_version", ""),
        "compiler_sha256": data.get("compiler_sha256", ""),
        "linker": data.get("linker", ""),
        "linker_version": data.get("linker_version", ""),
        "linker_sha256": data.get("linker_sha256", ""),
        "archiver": data.get("archiver", ""),
        "archiver_version": data.get("archiver_version", ""),
    },
    "host": {
        "kernel": data.get("host_kernel", ""),
        "cpus": int(data.get("host_cpus") or 0),
    },
    "build": {
        "jobs": int(data.get("jobs") or 0),
        "started_at": data.get("started_at", ""),
        "finished_at": data.get("finished_at", ""),
        "duration_seconds": int(data.get("build_seconds") or 0),
        "maximum_rss_kb": int(data.get("max_rss_kb") or 0),
        "elapsed_wall_time": data.get("elapsed_wall", ""),
        "kbuild_build_timestamp": data.get("kbuild_timestamp", ""),
        "kbuild_build_user": data.get("kbuild_user", ""),
        "kbuild_build_host": data.get("kbuild_host", ""),
        "kbuild_build_version": data.get("kbuild_version", ""),
        "localversion": data.get("localversion", ""),
        "kcflags": data.get("kcflags", ""),
        "command": data.get("command", ""),
        "scratch_root": build_root,
    },
    "artifacts": artifacts,
    "modules": {
        "count": int(data.get("module_count") or 0),
        "installed_dir": data.get("module_dir", ""),
        "manifest": "dist/modules.sha256",
    },
    "vmlinux_sha256": data.get("vmlinux_sha256", ""),
    "reproducibility": {
        "previous_build_dir": data.get("repro_check_dir", ""),
        "report": "repro-check.txt",
        "bit_identical": ("BIT-IDENTICAL" in open(os.path.join(out_dir, "repro-check.txt")).read())
        if os.path.isfile(os.path.join(out_dir, "repro-check.txt")) else None,
    },
    "timestamps": {"finished_at": __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds")},
    "note": "Built with the upstream product config fragments; the Fedora-specific "
            "SELinux fragment is documented in kernel/config/liuqin-fedora.config and "
            "can be applied with --extra-fragment. Upstream clone is never modified.",
}
with open(os.path.join(out_dir, "build-info.json"), "w") as handle:
    json.dump(info, handle, indent=2, sort_keys=False)
    handle.write("\n")
print("build-info.json written")
PY

# ---------------------------------------------------------------- SHA256SUMS
SUMS_TMP="$BUILD_ROOT/SHA256SUMS.tmp"
(
	cd "$OUT_DIR"
	find dist -type f -print0 | sort -z | xargs -0 sha256sum
	for extra in config-audit.tsv config-audit.json config-diff-vs-reference.log \
		config-diff-vs-reference.json dtb-report.txt repro-check.txt build-info.json; do
		[ -f "$extra" ] && sha256sum "$extra"
	done
) >"$SUMS_TMP"
mv -f "$SUMS_TMP" "$OUT_DIR/SHA256SUMS"

# ---------------------------------------------------------------- logs
for logfile in 01-defconfig 02-merge-config 03-olddefconfig 04-build 05-modules-install; do
	[ -f "$WORK_LOG_DIR/$logfile.log" ] || continue
	gzip -9 -n -c "$WORK_LOG_DIR/$logfile.log" >"$OUT_DIR/logs/$logfile.log.gz"
done

# ---------------------------------------------------------------- summary
log "artifacts:"
log "  Image        $(sha256sum "$DIST_DIR/Image" | cut -d' ' -f1)"
log "  DTB          $(sha256sum "$DIST_DIR/$(basename -- "$DTB_REL")" | cut -d' ' -f1)"
log "  config       $CONFIG_SHA"
log "  modules      $MODULE_COUNT modules, $(du -sh --apparent-size "$DIST_DIR/modules" | cut -f1)"
log "  build-info   $OUT_DIR/build-info.json"
log "  sums         $OUT_DIR/SHA256SUMS"
log "done in $(( $(date +%s) - START_EPOCH ))s"
