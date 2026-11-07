#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# export-kernel-patches.sh — export the liuqin private kernel patch stack as a
# maintainable, grouped patch queue with a machine-readable manifest.
#
# Source of truth:
#   repo   : upstream/linux-sm8450-liuqin (read-only shallow clone; never modified)
#   base   : kernel/source.json "upstream_base" (sm8450-mainline baseline commit)
#   head   : kernel/source.json "commit" / tag product-lock (device-tested product tree)
#
# The local clone is shallow (only the product commit + branch tip objects).
# If the base commit is not present locally, this script builds a *temporary*
# shared clone under $WORK_ROOT/repo (alternates into the read-only clone) and
# fetches history from the GitHub origin with `git fetch --deepen`; the
# read-only clone and its worktree are not touched or deepened. The method and
# its limitations are recorded in kernel/patches/manifest.json
# ("history_method").
#
# Outputs (default kernel/patches/):
#   series                               ordered list of queue patches (git am -3 / git apply)
#   queue/<group-prefix>/<NNNN>-<slug>.patch
#   manifest.json                        per-group commits/files/+-/risk/deps + history method
#   README.md                            how to apply/revert, format, grouping, licence
#   SHA256SUMS                           patch hashes
# plus a machine report under out/kernel-rebase/export-report.{txt,json}.
#
# Merge duplicates: the export uses `git rev-list --no-merges base..head` (merge
# commits themselves are not exported because `git format-patch` of a merge would
# duplicate first/second-parent content). The head tree is then reconstructed
# locally from the queue; if the merge required conflict resolutions, a final
# 9999-merge-resolution.patch is emitted so that apply-all reproduces the exact
# product tree.
#
# Usage: scripts/export-kernel-patches.sh [options]
#   --repo DIR         kernel git repo (default upstream/linux-sm8450-liuqin)
#   --spec FILE        kernel/source.json (default upstream/xiaomipad-6pro-mainline/kernel/source.json)
#   --out DIR          queue output dir (default <project>/kernel/patches)
#   --work-root DIR    scratch root for temporary clone/tree verification
#                      (default /var/tmp/liuqin-patch-export)
#   --no-fetch         never fetch network history (fail if base missing)
#   --max-depth N      maximum deepen budget for network fetch (default 1600)
#   -h, --help         this help
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

REPO="$PROJECT_ROOT/upstream/linux-sm8450-liuqin"
SPEC="$PROJECT_ROOT/upstream/xiaomipad-6pro-mainline/kernel/source.json"
OUT_DIR="$PROJECT_ROOT/kernel/patches"
WORK_ROOT="${LIUQIN_PATCH_EXPORT_WORK:-/var/tmp/liuqin-patch-export}"
REPORT_DIR="$PROJECT_ROOT/out/kernel-rebase"
NO_FETCH=0
MAX_DEPTH=1600

log() { printf '[export-kernel-patches] %s\n' "$*"; }
die() { printf '[export-kernel-patches] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--repo) REPO=${2:?}; shift 2 ;;
	--spec) SPEC=${2:?}; shift 2 ;;
	--out) OUT_DIR=${2:?}; shift 2 ;;
	--work-root) WORK_ROOT=${2:?}; shift 2 ;;
	--no-fetch) NO_FETCH=1; shift ;;
	--max-depth) MAX_DEPTH=${2:?}; shift 2 ;;
	-h|--help)
		sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -d "$REPO" ] || die "kernel repo not found: $REPO"
[ -f "$SPEC" ] || die "kernel spec not found: $SPEC"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"

BASE_FROM_SPEC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["upstream_base"])' "$SPEC")
HEAD_FROM_SPEC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$SPEC")
HEAD_REF=${HEAD_FROM_SPEC:-product-lock}

# ------------------------------------------------------------------ history
HISTORY_METHOD="local clone already contains base commit"
TEMP_CLONE=""
if ! git -C "$REPO" cat-file -e "$BASE_FROM_SPEC^{commit}" 2>/dev/null; then
	log "base commit $BASE_FROM_SPEC is missing from the shallow clone; preparing temporary history clone"
	[ "$NO_FETCH" -eq 1 ] && die "base commit missing and --no-fetch requested"
	mkdir -p "$WORK_ROOT"
	TEMP_CLONE="$WORK_ROOT/repo"
	if ! git -C "$TEMP_CLONE" cat-file -e "$BASE_FROM_SPEC^{commit}" 2>/dev/null; then
		rm -rf "$TEMP_CLONE"
		# --shared keeps the 1.9 GB object store shared read-only; only new
		# history objects land in the temporary clone.
		git clone --shared --no-checkout --quiet "$REPO" "$TEMP_CLONE" ||
			die "cannot create temporary shared clone"
		git -C "$TEMP_CLONE" remote set-url origin \
			"$(git -C "$REPO" remote get-url origin 2>/dev/null || echo https://github.com/yzddmr6/linux-sm8450-liuqin)"
		depth=100
		while [ "$depth" -le "$MAX_DEPTH" ]; do
			if git -C "$TEMP_CLONE" cat-file -e "$BASE_FROM_SPEC^{commit}" 2>/dev/null; then break; fi
			log "git fetch --deepen=$depth (network; proxy env is honoured by git)"
			git -C "$TEMP_CLONE" fetch --deepen="$depth" --no-tags origin \
				'+refs/heads/liuqin-6.17:refs/remotes/origin/liuqin-6.17' >/dev/null 2>&1 || {
				log "deepen=$depth failed; trying next budget"
			}
			depth=$((depth * 2))
		done
	fi
	git -C "$TEMP_CLONE" cat-file -e "$BASE_FROM_SPEC^{commit}" 2>/dev/null ||
		die "base commit $BASE_FROM_SPEC still missing after fetching; cannot export an honest queue"
	REPO_FOR_HISTORY="$TEMP_CLONE"
	HISTORY_METHOD="temporary shared clone ($TEMP_CLONE) + git fetch --deepen from upstream origin"
else
	REPO_FOR_HISTORY="$REPO"
fi
export REPO_FOR_HISTORY

BASE=$(git -C "$REPO_FOR_HISTORY" rev-parse "$BASE_FROM_SPEC^{commit}")
HEAD=$(git -C "$REPO_FOR_HISTORY" rev-parse "$HEAD_REF^{commit}")
[ "$BASE" = "$BASE_FROM_SPEC" ] || die "resolved base $BASE != spec base $BASE_FROM_SPEC"
[ "$HEAD" = "$HEAD_FROM_SPEC" ] || die "resolved head $HEAD != spec commit $HEAD_FROM_SPEC"
log "base: $BASE"
log "head: $HEAD ($HEAD_REF)"
log "history: $HISTORY_METHOD"

MERGE_COUNT=$(git -C "$REPO_FOR_HISTORY" rev-list --count --merges "$BASE..$HEAD")
TOTAL_COUNT=$(git -C "$REPO_FOR_HISTORY" rev-list --count "$BASE..$HEAD")
mapfile -t COMMITS < <(git -C "$REPO_FOR_HISTORY" rev-list --reverse --no-merges "$BASE..$HEAD")
[ "${#COMMITS[@]}" -gt 0 ] || die "no non-merge commits between base and head"
log "commits in range: $TOTAL_COUNT (non-merge ${#COMMITS[@]}, merges $MERGE_COUNT)"
mapfile -t MERGE_SHAS < <(git -C "$REPO_FOR_HISTORY" rev-list --merges "$BASE..$HEAD")

# ------------------------------------------------------------------ layout
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/queue" "$REPORT_DIR"
WORK_TREES="$WORK_ROOT/trees"
rm -rf "$WORK_TREES"
mkdir -p "$WORK_TREES"
BASE_TREE="$WORK_TREES/base"
HEAD_TREE="$WORK_TREES/head"
mkdir -p "$BASE_TREE" "$HEAD_TREE"
git -C "$REPO_FOR_HISTORY" archive "$BASE" | tar -x -C "$BASE_TREE"
git -C "$REPO_FOR_HISTORY" archive "$HEAD" | tar -x -C "$HEAD_TREE"

python3 - "$REPO_FOR_HISTORY" "$BASE" "$HEAD" "$OUT_DIR" "$WORK_TREES" "$HISTORY_METHOD" \
	"$TOTAL_COUNT" "$MERGE_COUNT" "$SPEC" "$PROJECT_ROOT" <<'PY'
import hashlib, json, os, re, subprocess, sys, datetime

(repo, base, head, out_dir, work_trees, history_method,
 total_count, merge_count, spec_path, project_root) = sys.argv[1:11]
total_count, merge_count = int(total_count), int(merge_count)


def git(*args, check=True):
    return subprocess.run(["git", "-C", repo, *args], check=check,
                          capture_output=True, text=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def slugify(text):
    text = re.sub(r"[^A-Za-z0-9._-]+", "-", text.strip().lower())
    return text.strip("-")[:80] or "patch"


GROUP_ORDER = []
DEFS = {}
for line in """0010-dt-board|DT|arch/arm64/boot/dts/*
0100-boot-arch|arch/arm64 (non-DT) + boot chain earlycon|arch/arm64/*,drivers/tty/serial/*
0200-display|display/GPU/DRM|drivers/gpu/drm/*,drivers/video/*
0300-input-touch-hid|touchscreen + HID|drivers/input/*,drivers/hid/*
0400-audio|ASoC/AudioReach|sound/*,include/uapi/sound/*
0500-camera|CAMSS/S5KJN1/CAMCC|drivers/media/*,drivers/clk/qcom/*
0600-tee-fingerprint|TEE/QSEECOM/FPC|drivers/tee/*,drivers/firmware/qcom/*,drivers/misc/*
0700-usb-dp|USB/Type-C/DP PHY|drivers/usb/*,drivers/phy/*
0800-power-soc|battmgr/PON/reboot + soc/qcom|drivers/power/*,drivers/nvmem/*,drivers/soc/qcom/*
0900-net-bluetooth|net/wireless/bluetooth|net/*,drivers/net/*,drivers/bluetooth/*
0999-docs-bindings|Documentation/dt-bindings/CI|Documentation/*,include/dt-bindings/*,.github/*
9999-misc|other|*""".splitlines():
    prefix, desc, globs = line.split("|")
    GROUP_ORDER.append(prefix)
    DEFS[prefix] = {"prefix": prefix, "description": desc, "globs": globs.split(",")}

HIGH_RISK_RE = re.compile(
    r"touchscreen|hid|nanosic|nt36|qmp-combo|dwc3|ucsi|typec|cpufreq|topology|thermal|"
    r"arch_topology|qcom_battmgr|qcom-pon|msm-poweroff|nvmem-reboot",
    re.IGNORECASE)


def classify(path):
    for prefix in GROUP_ORDER:
        if prefix == "9999-misc":
            continue
        for glob in DEFS[prefix]["globs"]:
            if path == glob.rstrip("/") or path.startswith(glob.rstrip("*")) and glob.endswith("*"):
                return prefix
    return "9999-misc"


def classify_by_lines(paths):
    scores = {}
    for path, add, delete in paths:
        score = add + delete
        prefix = classify(path)
        scores[prefix] = scores.get(prefix, 0) + score
    if not scores:
        return "9999-misc"
    best = max(scores.items(), key=lambda item: item[1])
    return best[0]


def parse_numstat(text):
    rows = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        add, delete, path = parts
        try:
            rows.append((path, int(add), int(delete)))
        except ValueError:
            rows.append((path, 0, 0))
    return rows


commits = git("rev-list", "--reverse", "--no-merges", f"{base}..{head}").stdout.split()
merges = git("rev-list", "--merges", f"{base}..{head}").stdout.split()
series = []
groups = {prefix: {"prefix": prefix, "description": DEFS[prefix]["description"],
                   "commits": [], "paths": set(), "insertions": 0, "deletions": 0}
          for prefix in GROUP_ORDER}
risk_groups = {"0300-input-touch-hid", "0700-usb-dp", "0100-boot-arch",
               "0500-camera", "0600-tee-fingerprint"}
file_group_owner = {}
patch_meta = []

seen_patch_hash = {}
duplicates = []
export_index = 0
for commit_index, commit in enumerate(commits, start=1):
    meta = git("show", "-s", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%b", commit).stdout
    sha, short, author, date, subject, body = meta.split("\x00", 5)
    # Duplicate content: commits that were cherry-picked twice produce byte-identical
    # diffs; keep the first occurrence in the queue and record the duplicate.
    diff_text = git("show", "--format=", commit).stdout
    diff_hash = hashlib.sha256(diff_text.encode()).hexdigest()
    if diff_hash in seen_patch_hash:
        duplicates.append({"commit": sha, "short": short, "subject": subject,
                           "duplicate_of": seen_patch_hash[diff_hash]})
        continue
    seen_patch_hash[diff_hash] = sha
    export_index += 1
    numstat = git("show", "--numstat", "--format=", commit).stdout
    paths = parse_numstat(numstat)
    group = classify_by_lines(paths)
    files = [path for path, _, _ in paths]
    insertions = sum(add for _, add, _ in paths)
    deletions = sum(delete for _, _, delete in paths)
    high_risk = group in risk_groups or bool(HIGH_RISK_RE.search(" ".join(files))) or bool(
        HIGH_RISK_RE.search(subject))
    slug = slugify(subject)
    directory = os.path.join(out_dir, "queue", group)
    os.makedirs(directory, exist_ok=True)
    filename = "%04d-%s.patch" % (export_index, slug)
    patch_path = os.path.join(directory, filename)
    patch = git("format-patch", "-1", "--stdout", "--no-signature", "--zero-commit",
                "--no-stat", commit)
    with open(patch_path, "w") as handle:
        handle.write(patch.stdout)
    rel = os.path.relpath(patch_path, out_dir)
    series.append(rel)
    groups[group]["commits"].append({"sha": sha, "short": short, "subject": subject,
                                     "date": date, "files": len(files),
                                     "insertions": insertions, "deletions": deletions,
                                     "high_risk": high_risk, "patch": rel})
    groups[group]["insertions"] += insertions
    groups[group]["deletions"] += deletions
    groups[group]["paths"].update(files)
    for path in files:
        file_group_owner.setdefault(path, set()).add(group)
    patch_meta.append({"sha": sha, "group": group, "patch": rel, "files": files,
                       "insertions": insertions, "deletions": deletions,
                       "subject": subject, "high_risk": high_risk})

# dependencies between groups: ordered overlap of touched files (earlier group -> later group)
group_order_in_series = []
for entry in patch_meta:
    if entry["group"] not in group_order_in_series:
        group_order_in_series.append(entry["group"])
for prefix in groups:
    groups[prefix]["depends_on"] = []
seen = set()
for prefix in group_order_in_series:
    groups[prefix]["depends_on"] = [p for p in group_order_in_series
                                    if p != prefix and p in seen]
    seen.add(prefix)

with open(os.path.join(out_dir, "series"), "w") as handle:
    handle.write("".join(line + "\n" for line in series))

head_stat = git("diff", "--shortstat", f"{base}..{head}").stdout.strip()
base_meta = {
    "commit": base,
    "subject": git("show", "-s", "--format=%s", base).stdout.strip(),
    "date": git("show", "-s", "--format=%aI", base).stdout.strip(),
}
head_meta = {
    "commit": head,
    "subject": git("show", "-s", "--format=%s", head).stdout.strip(),
    "date": git("show", "-s", "--format=%aI", head).stdout.strip(),
}
merge_meta = []
for merge in merges:
    merge_meta.append({"commit": merge,
                       "subject": git("show", "-s", "--format=%s", merge).stdout.strip(),
                       "parents": git("show", "-s", "--format=%P", merge).stdout.split()})

for prefix in groups:
    groups[prefix]["paths"] = sorted(groups[prefix]["paths"])

manifest = {
    "schema_version": 1,
    "kind": "liuqin-kernel-private-patch-queue",
    "project": "Fedora ARM64 liuqin port",
    "source": {"repo": "upstream/linux-sm8450-liuqin (read-only shallow clone)",
               "spec": os.path.relpath(spec_path, project_root),
               "base": base_meta, "head": head_meta},
    "history_method": history_method,
    "history_limitations": [
        "The read-only upstream clone is shallow; it is NOT deepened or modified by this tool.",
        "When the base commit was missing, a temporary shared clone under /var/tmp was fetched "
        "with `git fetch --deepen` from the GitHub origin. The queue is therefore derived from "
        "network-fetched history on first export; re-exports can reuse the temporary clone.",
        "Patches are the non-merge commits in base..head plus (only if needed) a synthetic "
        "9999-merge-resolution.patch; merge commits themselves are not exported because "
        "format-patch of a merge would duplicate parent content.",
    ],
    "counts": {"commits_total": total_count, "non_merge_commits": len(commits),
               "non_merge_exported": len(patch_meta), "deduplicated_commits": len(duplicates),
               "merges": merge_count, "files": None, "insertions": None, "deletions": None},
    "deduplicated_commits": duplicates,
    "diffstat": head_stat,
    "series": series,
    "groups": [groups[prefix] for prefix in GROUP_ORDER if groups[prefix]["commits"]],
    # Forward-port hard groups (the forward-port grouping): touch/HID, USB Type-C/DP, and the
    # DP combo-PHY patches that the classifier splits between display and usb.
    "high_risk_groups": [prefix for prefix in GROUP_ORDER
                         if prefix in {"0200-display", "0300-input-touch-hid", "0700-usb-dp"}
                         and any(entry["group"] == prefix for entry in patch_meta)],
    "merge_commits": merge_meta,
    "patches": patch_meta,
    "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "tool": "scripts/export-kernel-patches.sh",
}
# diffstat numbers for the whole range
nums = git("diff", "--numstat", f"{base}..{head}").stdout.splitlines()
insertions = sum(int(line.split("\t")[0]) for line in nums if line.split("\t")[0].isdigit())
deletions = sum(int(line.split("\t")[1]) for line in nums if line.split("\t")[1].isdigit())
manifest["counts"].update({"files": len(nums), "insertions": insertions, "deletions": deletions})

with open(os.path.join(out_dir, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
print(json.dumps({"patches": len(patch_meta), "deduplicated": len(duplicates),
                  "groups": len(manifest["groups"]),
                  "files": len(nums), "insertions": insertions, "deletions": deletions,
                  "merges": merge_count}))
PY

# ---------------------------------------------------------------- reconstruction check
APPLIED_TREE="$WORK_TREES/applied"
mkdir -p "$APPLIED_TREE"
git -C "$REPO_FOR_HISTORY" archive "$BASE" | tar -x -C "$APPLIED_TREE"
apply_ok=0
apply_fail=0
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	if (cd "$APPLIED_TREE" && git apply --whitespace=nowarn "$OUT_DIR/$rel") 2>"$WORK_TREES/apply.err"; then
		apply_ok=$((apply_ok + 1))
	else
		apply_fail=$((apply_fail + 1))
		log "patch failed during reconstruction: $rel"
		cat "$WORK_TREES/apply.err" >&2
	fi
done <"$OUT_DIR/series"
log "reconstruction: $apply_ok applied, $apply_fail failed"

RESIDUAL=0
if [ "$apply_fail" -ne 0 ]; then
	die "queue reconstruction failed: $apply_fail patch(es) did not apply on the base tree (see log above); refusing to publish an inconsistent queue"
fi
if [ "$apply_fail" -eq 0 ]; then
	if diff -r -q --exclude=.git "$APPLIED_TREE" "$HEAD_TREE" >"$REPORT_DIR/reconstruction-diff.txt" 2>&1; then
		log "reconstruction is byte-identical to product tree"
	else
		RESIDUAL=1
		log "WARNING: non-merge queue does not reproduce the product tree exactly; emitting merge-resolution patch"
		(cd "$WORK_TREES" && diff -ruN --exclude=.git applied head >"$WORK_TREES/merge-resolution.diff" 2>/dev/null || true)
		# Convert "applied/... head/..." paths to a/... b/... style unified patch.
		python3 - "$WORK_TREES/merge-resolution.diff" "$OUT_DIR/queue/9999-misc/9999-merge-resolution.patch" <<'PYMERGE'
import os, sys
src, dst = sys.argv[1:3]
lines = []
for line in open(src, errors="replace"):
    if line.startswith("--- applied/"):
        lines.append("--- a/" + line[len("--- applied/"):])
    elif line.startswith("+++ head/"):
        lines.append("+++ b/" + line[len("+++ head/"):])
    elif line.startswith("diff -ruN"):
        continue
    elif line.startswith("Only in"):
        continue
    else:
        lines.append(line)
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, "w").writelines(lines)
PYMERGE
		printf 'queue/9999-misc/9999-merge-resolution.patch\n' >>"$OUT_DIR/series"
		# re-apply only the resolution patch on top of the applied tree
		(cd "$APPLIED_TREE" && git apply --whitespace=nowarn "$OUT_DIR/queue/9999-misc/9999-merge-resolution.patch") ||
			die "merge-resolution patch could not be applied"
		diff -r -q --exclude=.git "$APPLIED_TREE" "$HEAD_TREE" >/dev/null 2>&1 ||
			die "product tree still not reproduced after merge-resolution patch"
		log "merge-resolution patch added; product tree reproduced"
	fi
fi

# record reconstruction verdict + patch hashes in the manifest
RECON_OK=$([ "$RESIDUAL" -eq 0 ] && echo true || echo false)
python3 - "$OUT_DIR" "$RECON_OK" "$(wc -l <"$OUT_DIR/series")" <<'PYRECON'
import hashlib, json, sys
out_dir, recon_ok, patch_count = sys.argv[1:4]
manifest = json.load(open(out_dir + "/manifest.json"))
manifest["reconstruction"] = {"ok": recon_ok == "true", "result": "byte-identical product tree"
                              if recon_ok == "true" else "merge-resolution patch appended",
                              "series_patches": int(patch_count)}
json.dump(manifest, open(out_dir + "/manifest.json", "w"), indent=2)
open(out_dir + "/manifest.json", "a").write("\n")
PYRECON

# ---------------------------------------------------------------- sums + readme + report
(cd "$OUT_DIR" && find queue -type f -name '*.patch' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$OUT_DIR/SHA256SUMS.patches"
python3 - "$OUT_DIR" "$REPORT_DIR" "$BASE" "$HEAD" "$TOTAL_COUNT" "$MERGE_COUNT" "$HISTORY_METHOD" <<'PY'
import json, sys
out_dir, report_dir, base, head, total, merges, method = sys.argv[1:8]
manifest = json.load(open(out_dir + "/manifest.json"))
report = {"base": base, "head": head, "commits_total": int(total), "merges": int(merges),
          "non_merge_exported": manifest["counts"]["non_merge_exported"],
          "groups": len(manifest["groups"]), "series_patches": len(manifest["series"]),
          "files": manifest["counts"]["files"], "insertions": manifest["counts"]["insertions"],
          "deletions": manifest["counts"]["deletions"], "history_method": method,
          "high_risk_groups": manifest["high_risk_groups"],
          "reconstruction": (manifest.get("reconstruction") or {}).get("result", "unknown")}
json.dump(report, open(report_dir + "/export-report.json", "w"), indent=2)
print(json.dumps(report, indent=2))
PY

cat >"$OUT_DIR/README.md" <<'EOF'
# liuqin private kernel patch queue

Exported from the pinned device kernel:

- repo: `upstream/linux-sm8450-liuqin` (read-only shallow clone)
- base: `kernel/source.json` → `upstream_base` (sm8450-mainline baseline)
- head: tag `product-lock` / `kernel/source.json` → `commit` (device-tested product tree)

The queue is generated by `scripts/export-kernel-patches.sh`; **do not edit patches
by hand** — edit the pinned kernel commits upstream and re-export.

## Layout

```
series                                  ordered patch list (relative to this directory)
queue/<group>/<NNNN>-<slug>.patch       one patch per non-merge commit
manifest.json                           commits/groups/files/+-/risk/dependencies + history method
SHA256SUMS.patches                      patch file hashes
```

Groups are routing/organisation only (by subsystem, see `manifest.json`); the
**apply order is always `series`** (chronological, as committed upstream).

## Apply / revert

```sh
# dry-run apply onto a kernel tree (no tree modification):
git -C <linux-tree> apply --check --verbose --directory=. \
  $(sed 's#^#<queue>/#' series)          # or loop per patch for per-patch status

# apply in order (e.g. in a scratch clone/copy):
while read -r p; do git -C "$TREE" am -3 "<queue>/$p"; done < series
# revert (reverse order):
tac series | while read -r p; do git -C "$TREE" apply -R "<queue>/$p"; done
```

`scripts/rebase-check.sh` automates per-patch status (APPLIED/CONFLICT/SKIPPED)
against an arbitrary target tree and writes a JSON/text report under
`out/kernel-rebase/`.

## Merge commits

`manifest.json.counts.merges` lists merge commits in the range; they are **not**
exported as patches (that would duplicate parent content). If the merge required
conflict resolution, the exporter appends `9999-merge-resolution.patch` and
verifies that applying the whole series reproduces the product tree byte for byte.

## Licence / size

Patches are derived from GPL-2.0-only Linux kernel sources (same licence as the
kernel) and are stored as text under `kernel/patches/queue/`; size is a few MB.
They contain no vendor firmware or device data.
EOF

cat >"$REPORT_DIR/export-report.txt" <<EOF
# kernel patch queue export report
generated: $(date -Is)
base:       $BASE
head:       $HEAD
history:    $HISTORY_METHOD
commits:    $TOTAL_COUNT total ($MERGE_COUNT merges, ${#COMMITS[@]} non-merge exported)
merges listed in manifest: ${MERGE_SHAS[*]:-none}
reconstruction: $([ "$RESIDUAL" -eq 0 ] && echo "byte-identical product tree" || echo "merge-resolution patch added (see log)")
queue dir:  $OUT_DIR
EOF
python3 - "$OUT_DIR" "$REPORT_DIR" "$BASE" "$HEAD" "$HISTORY_METHOD" <<'PY'
import json, sys
out, report, base, head, method = sys.argv[1:6]
manifest = json.load(open(out + "/manifest.json"))
json.dump({"base": base, "head": head, "history_method": method,
           "counts": manifest["counts"], "groups": manifest["groups"],
           "high_risk_groups": manifest["high_risk_groups"],
           "merge_commits": manifest["merge_commits"]},
          open(report + "/export-report.json", "w"), indent=2)
PY
cp "$OUT_DIR/manifest.json" "$REPORT_DIR/manifest.json"
log "queue: $OUT_DIR ($(wc -l <"$OUT_DIR/series") patches, $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["groups"]))' "$OUT_DIR/manifest.json") groups)"
log "report: $REPORT_DIR/export-report.txt"
