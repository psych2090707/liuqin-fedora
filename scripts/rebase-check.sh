#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# rebase-check.sh — dry-run the exported liuqin private kernel patch queue
# against an arbitrary target kernel tree and produce a per-patch
# APPLIED / CONFLICT / SKIPPED report.
#
# Safety: the target tree is always copied into a scratch directory under
# --work-root (/var/tmp by default). No source repository or tree is modified
# and no build/device action is performed.
#
# Target selection (exactly one):
#   --target-tree DIR            use an existing extracted Linux tree (7.x tarball, etc.)
#   --target-repo DIR --target-ref REF
#                                export a git ref to the scratch tree
#   (neither)                    self-test: use the queue's own base commit from the
#                                queue manifest (expects all patches APPLIED and the
#                                final tree to reproduce the product tree)
#
# Reports (default out/kernel-rebase/):
#   rebase-report-<target>.txt / .json
#     per patch: status, files, conflict files/lines, first error lines
#     summary: target identity (detected kernel version/ref), counts, self-test verdict
#
# Usage:
#   scripts/rebase-check.sh                          # self-test vs queue base
#   scripts/rebase-check.sh --target-tree /var/tmp/linux-7.2.11
#   scripts/rebase-check.sh --target-repo <repo> --target-ref <sha|tag>
#
# Options:
#   --queue DIR          patch queue (default <project>/kernel/patches)
#   --source-repo DIR    repo used for self-test base/product trees
#                        (default upstream/linux-sm8450-liuqin, with fallback to the
#                        export tool's temporary history clone)
#   --work-root DIR      scratch root (default /var/tmp/liuqin-rebase-check)
#   --report-dir DIR     report directory (default <project>/out/kernel-rebase)
#   --stop-on-conflict   stop at the first CONFLICT (default: continue)
#   --keep-work          keep the scratch tree (otherwise removed on success)
#   -h, --help           this help
set -euo pipefail
# Keep tool output parseable regardless of the host locale (conflict files/lines).
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

QUEUE="$PROJECT_ROOT/kernel/patches"
SOURCE_REPO="$PROJECT_ROOT/upstream/linux-sm8450-liuqin"
WORK_ROOT="${LIUQIN_REBASE_CHECK_WORK:-/var/tmp/liuqin-rebase-check}"
REPORT_DIR="$PROJECT_ROOT/out/kernel-rebase"
TARGET_TREE=""
TARGET_REPO=""
TARGET_REF=""
STOP_ON_CONFLICT=0
KEEP_WORK=0

log() { printf '[rebase-check] %s\n' "$*"; }
die() { printf '[rebase-check] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--queue) QUEUE=${2:?}; shift 2 ;;
	--source-repo) SOURCE_REPO=${2:?}; shift 2 ;;
	--work-root) WORK_ROOT=${2:?}; shift 2 ;;
	--report-dir) REPORT_DIR=${2:?}; shift 2 ;;
	--target-tree) TARGET_TREE=${2:?}; shift 2 ;;
	--target-repo) TARGET_REPO=${2:?}; shift 2 ;;
	--target-ref) TARGET_REF=${2:?}; shift 2 ;;
	--stop-on-conflict) STOP_ON_CONFLICT=1; shift ;;
	--keep-work) KEEP_WORK=1; shift ;;
	-h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -d "$QUEUE" ] || die "queue dir not found: $QUEUE"
[ -f "$QUEUE/series" ] || die "queue series not found: $QUEUE/series"
[ -f "$QUEUE/manifest.json" ] || die "queue manifest not found: $QUEUE/manifest.json"
mkdir -p "$REPORT_DIR"

BASE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"]["base"]["commit"])' "$QUEUE/manifest.json")
HEAD=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"]["head"]["commit"])' "$QUEUE/manifest.json")

# Resolve source repo: prefer the given one when it has the needed objects,
# otherwise fall back to the exporter's temporary history clone.
local_has() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; }
if [ "$TARGET_REPO" = "" ]; then
	if local_has "$SOURCE_REPO" "$BASE"; then
		: # fast path: complete history in the read-only clone
	elif [ -d "${LIUQIN_PATCH_EXPORT_WORK:-/var/tmp/liuqin-patch-export}/repo" ] &&
		local_has "${LIUQIN_PATCH_EXPORT_WORK:-/var/tmp/liuqin-patch-export}/repo" "$BASE"; then
		SOURCE_REPO="${LIUQIN_PATCH_EXPORT_WORK:-/var/tmp/liuqin-patch-export}/repo"
		log "using exporter history clone for base tree: $SOURCE_REPO"
	else
		die "base commit $BASE not available in $SOURCE_REPO and no exporter clone found; run scripts/export-kernel-patches.sh first"
	fi
fi

if [ -e "$WORK_ROOT" ] && ! rm -rf "$WORK_ROOT" 2>/dev/null; then
	die "cannot clean work root: $WORK_ROOT"
fi
mkdir -p "$WORK_ROOT"
TREE="$WORK_ROOT/tree"

# ---------------------------------------------------------------- target setup
SELFTEST=0
if [ -n "$TARGET_TREE" ]; then
	[ -d "$TARGET_TREE" ] || die "target tree not found: $TARGET_TREE"
	cp -a "$TARGET_TREE/." "$TREE/"
	TARGET_LABEL=$(basename "$TARGET_TREE")
	TARGET_KIND=tree
elif [ -n "$TARGET_REPO" ]; then
	[ -n "$TARGET_REF" ] || die "--target-repo requires --target-ref"
	[ -d "$TARGET_REPO" ] || die "target repo not found: $TARGET_REPO"
	git -C "$TARGET_REPO" cat-file -e "$TARGET_REF^{commit}" 2>/dev/null ||
		die "cannot resolve $TARGET_REF in $TARGET_REPO"
	mkdir -p "$TREE"
	git -C "$TARGET_REPO" archive "$TARGET_REF" | tar -x -C "$TREE"
	TARGET_LABEL=$(echo "$TARGET_REF" | tr '/: ' '___')
	TARGET_KIND=git
else
	SELFTEST=1
	mkdir -p "$TREE"
	git -C "$SOURCE_REPO" archive "$BASE" | tar -x -C "$TREE"
	TARGET_LABEL="selftest-base-${BASE:0:12}"
	TARGET_KIND=git
fi

# Detect kernel version from the target tree (honest identity in the report).
detect_version() { # detect_version TREE
	[ -f "$1/Makefile" ] || {
		echo "unknown (no Makefile)"
		return
	}
	awk '
		/^VERSION =/ {v=$3}
		/^PATCHLEVEL =/ {p=$3}
		/^SUBLEVEL =/ {s=$3}
		/^EXTRAVERSION =/ {e=$3}
		END {printf "%s.%s.%s%s", v, p, s, e}
	' "$1/Makefile"
}
TARGET_VERSION=$(detect_version "$TREE")
TARGET_TREE_SHA=""
if [ -d "$TREE/.git" ]; then TARGET_TREE_SHA=$(git -C "$TREE" rev-parse HEAD 2>/dev/null || true); fi
TARGET_TREE_SHA=$(cd "$TREE" && find . -type f ! -path './.git/*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)

# Prepare the scratch tree as a git repo with a clean index so that
# `git apply --3way` can be used where patch preimage blobs exist.
( cd "$TREE"
  git init -q
  git config user.name "rebase-check"
  git config user.email "rebase-check@localhost"
  git add -A >/dev/null
  git commit -q -m "target: $TARGET_LABEL ($TARGET_VERSION)" >/dev/null 2>&1 || true
)

log "queue      : $QUEUE ($(wc -l <"$QUEUE/series") patches)"
log "target     : $TARGET_LABEL ($TARGET_KIND) Linux $TARGET_VERSION"
log "scratch    : $TREE"
log "self-test  : $SELFTEST"

# ---------------------------------------------------------------- apply loop
APPLIED=0
CONFLICT=0
SKIPPED=0
FAILED=0
: >"$WORK_ROOT/patch-results.tsv"
printf 'index\tstatus\tpatch\tfiles\tconflict_files\terror\n' >>"$WORK_ROOT/patch-results.tsv"

index=0
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	index=$((index + 1))
	patch="$QUEUE/$rel"
	[ -f "$patch" ] || { FAILED=$((FAILED + 1)); printf '%d\tMISSING\t%s\t0\t\tpatch file missing\n' "$index" "$rel" >>"$WORK_ROOT/patch-results.tsv"; continue; }
	files=$(grep -c '^diff --git ' "$patch" || true)
	error_text=""
	status=""
	conflict_files=""
	if (cd "$TREE" && git apply --check --whitespace=nowarn "$patch") 2>"$WORK_ROOT/apply.err"; then
		if (cd "$TREE" && git apply --whitespace=nowarn "$patch") 2>>"$WORK_ROOT/apply.err"; then
			status=APPLIED
			APPLIED=$((APPLIED + 1))
			# keep index roughly in sync for later --3way attempts
			( cd "$TREE" && git add -A >/dev/null 2>&1 || true )
		else
			status=FAILED
			FAILED=$((FAILED + 1))
			error_text=$(head -n 4 "$WORK_ROOT/apply.err" | tr '\n' ' ')
		fi
	elif (cd "$TREE" && git apply --check -R --whitespace=nowarn "$patch") 2>/dev/null; then
		status=SKIPPED
		SKIPPED=$((SKIPPED + 1))
		error_text="already applied in target tree"
	else
		status=CONFLICT
		CONFLICT=$((CONFLICT + 1))
		# richer hunk detail via patch --dry-run when available
		if command -v patch >/dev/null 2>&1; then
			(cd "$TREE" && patch --dry-run -p1 --forward --force -i "$patch" >"$WORK_ROOT/patch-dry.txt" 2>&1) || true
			conflict_files=$(grep -oE '^patching file [^[:space:]]+' "$WORK_ROOT/patch-dry.txt" 2>/dev/null | sed 's/^patching file //' | sort -u | paste -sd, - || true)
			hunk_lines=$(grep -cE '^Hunk #[0-9]+ FAILED' "$WORK_ROOT/patch-dry.txt" 2>/dev/null || true)
		fi
		if [ -z "$conflict_files" ]; then
			conflict_files=$(cd "$TREE" && git apply --check --verbose --whitespace=nowarn "$patch" 2>&1 |
				grep -oE 'patch failed: [^:]+' | sed 's/patch failed: //' | sort -u | paste -sd, - || true)
		fi
		hunks=""
		if command -v patch >/dev/null 2>&1; then
			hunks=$(grep -oE 'Hunk #[0-9]+ FAILED at [0-9]+' "$WORK_ROOT/patch-dry.txt" 2>/dev/null |
				head -n 3 | paste -sd';' - || true)
		fi
		error_text=$(cd "$TREE" && git apply --check --verbose --whitespace=nowarn "$patch" 2>&1 |
			grep -E '^error:' | head -n 3 | tr '\n' ' ' || true)
		[ -n "$hunks" ] && error_text="$error_text hunks=[$hunks]"
		[ -n "$error_text" ] || error_text="patch does not apply"
	fi
	printf '%d\t%s\t%s\t%s\t%s\t%s\n' "$index" "$status" "$rel" "$files" "$conflict_files" "${error_text//$'\t'/ }" >>"$WORK_ROOT/patch-results.tsv"
	if [ "$STOP_ON_CONFLICT" -eq 1 ] && [ "$status" = CONFLICT ]; then
		log "stopping on first conflict: $rel"
		break
	fi
done <"$QUEUE/series"

# ---------------------------------------------------------------- self-test verification
SELFTEST_VERDICT=""
if [ "$SELFTEST" -eq 1 ]; then
	PRODUCT_TREE="$WORK_ROOT/product-tree"
	mkdir -p "$PRODUCT_TREE"
	git -C "$SOURCE_REPO" archive "$HEAD" | tar -x -C "$PRODUCT_TREE"
	if diff -r -q --exclude=.git "$TREE" "$PRODUCT_TREE" >"$WORK_ROOT/selftest-diff.txt" 2>&1; then
		SELFTEST_VERDICT="PASS (all patches applied; final tree == product tree $HEAD)"
	else
		SELFTEST_VERDICT="FAIL (tree differs from product tree; see $(basename "$REPORT_DIR")/selftest-diff.txt)"
		cp "$WORK_ROOT/selftest-diff.txt" "$REPORT_DIR/selftest-diff.txt" 2>/dev/null || true
	fi
	if [ "$APPLIED" -ne "$(wc -l <"$QUEUE/series")" ]; then
		SELFTEST_VERDICT="FAIL ($APPLIED/$(wc -l <"$QUEUE/series") applied; expected all)"
	fi
	log "self-test: $SELFTEST_VERDICT"
fi

# ---------------------------------------------------------------- reports
SUMMARY_TSV="$REPORT_DIR/rebase-summary-$(echo "$TARGET_LABEL" | tr -c 'A-Za-z0-9._-' '_').tsv"
cp "$WORK_ROOT/patch-results.tsv" "$SUMMARY_TSV"
python3 - "$WORK_ROOT/patch-results.tsv" "$QUEUE/manifest.json" "$REPORT_DIR/rebase-report-$(echo "$TARGET_LABEL" | tr -c 'A-Za-z0-9._-' '_').json" \
	"$TARGET_LABEL" "$TARGET_KIND" "$TARGET_VERSION" "$TARGET_TREE_SHA" "$APPLIED" "$CONFLICT" "$SKIPPED" "$FAILED" \
	"$SELFTEST" "$SELFTEST_VERDICT" <<'PY'
import json, sys
(results_tsv, manifest_path, out_json, label, kind, version, tree_sha,
 applied, conflict, skipped, failed, selftest, verdict) = sys.argv[1:14]
manifest = json.load(open(manifest_path))
patches = []
with open(results_tsv) as handle:
    next(handle)
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 6:
            continue
        patches.append({"index": int(parts[0]), "status": parts[1], "patch": parts[2],
                        "files": int(parts[3] or 0),
                        "conflict_files": [f for f in parts[4].split(",") if f],
                        "error": parts[5]})
report = {
    "schema_version": 1,
    "queue": {"base": manifest["source"]["base"]["commit"],
              "head": manifest["source"]["head"]["commit"],
              "patches": len(manifest["series"]),
              "groups": [g["prefix"] for g in manifest["groups"]]},
    "target": {"label": label, "kind": kind, "detected_version": version,
               "tree_sha256": tree_sha},
    "summary": {"APPLIED": int(applied), "CONFLICT": int(conflict),
                "SKIPPED": int(skipped), "FAILED": int(failed),
                "total": len(patches)},
    "selftest": (bool(int(selftest))),
    "selftest_verdict": verdict,
    "patches": patches,
}
json.dump(report, open(out_json, "w"), indent=2)
print(json.dumps(report["summary"]))
PY
REPORT_JSON=$(ls "$REPORT_DIR"/rebase-report-*.json | tail -n 1)
REPORT_TXT="$REPORT_DIR/rebase-report-$(echo "$TARGET_LABEL" | tr -c 'A-Za-z0-9._-' '_').txt"
{
	printf '# kernel rebase-check report\n'
	printf 'date:        %s\n' "$(date -Is)"
	printf 'target:      %s (%s), detected Linux %s\n' "$TARGET_LABEL" "$TARGET_KIND" "$TARGET_VERSION"
	printf 'target sha:  %s\n' "$TARGET_TREE_SHA"
	printf 'queue:       base %s -> head %s (%s patches)\n' "${BASE:0:12}" "${HEAD:0:12}" "$(wc -l <"$QUEUE/series")"
	printf '\nsummary: APPLIED=%s CONFLICT=%s SKIPPED=%s FAILED=%s total=%s\n' "$APPLIED" "$CONFLICT" "$SKIPPED" "$FAILED" "$index"
	printf 'selftest: %s\n\n' "${SELFTEST_VERDICT:-n/a}"
	printf 'per-patch results:\n'
	awk -F'\t' 'NR>1 {printf "  %-7s %s%s\n", $2, $3, ($5 != "" ? "  [conflict files: " $5 "]" : "")}' "$WORK_ROOT/patch-results.tsv"
} >"$REPORT_TXT"
cp "$REPORT_JSON" "$REPORT_DIR/latest-rebase-report.json" 2>/dev/null || true
cp "$REPORT_TXT" "$REPORT_DIR/latest-rebase-report.txt" 2>/dev/null || true

if [ "$KEEP_WORK" -eq 0 ] && [ "$CONFLICT" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
	rm -rf "$WORK_ROOT"
fi
log "report: $REPORT_TXT"
log "APPLIED=$APPLIED CONFLICT=$CONFLICT SKIPPED=$SKIPPED FAILED=$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
