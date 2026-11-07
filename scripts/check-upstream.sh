#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-upstream.sh — read-only upstream-drift detector for the liuqin Fedora port.
#
# It never updates locks and never writes into upstream/; it only snapshots the
# facts the kernel/boot-chain decisions depend on and flags drift:
#
#   * yzddmr6/linux-sm8450-liuqin  — does a >6.17 liuqin branch exist? how far is
#                                    the branch head from the product-lock commit?
#   * Seeker0472/liuqin-nixos      — current Linux / U-Boot port versions (raw
#                                    default.nix), main-branch head;
#   * sm8450-mainline/linux        — branch heads (is the base still next-new?);
#   * mainline Linux               — do sm8450 / sm8475 / sm8475p / liuqin DTS
#                                    files exist in torvalds master and linux-next?
#   * kernel.org                   — latest mainline + latest stable in the 7.x line;
#   * u-boot/u-boot + sm8450-mainline/u-boot — latest release tag vs the
#                                    liuqin U-Boot port baseline;
#   * pipa-family kernel repos     — how sibling devices track newer kernels.
#
# Output: out/upstream-check/<UTC-stamp>/{refs,mainline-dts,kernel-releases.json,
#         summary.json,summary.md}. exit 0 = snapshot written (drift is reported
#         in the summary, not via exit code); exit 2 = missing tool/network for a
#         required check; exit 1 = unexpected internal error.
#
# Usage:
#   scripts/check-upstream.sh                 # snapshot + human summary
#   scripts/check-upstream.sh --out DIR       # explicit evidence directory
#   scripts/check-upstream.sh --quiet         # only the summary path on stdout
#
# This is a skeleton by design: adding a check = add one probe_* function and
# one line in main(). Do not make it modify docs/ or upstream/.
set -euo pipefail
umask 022

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT=${UPSTREAM_CHECK_OUT:-"$ROOT/out/upstream-check/$STAMP"}
QUIET=0
PROXY=${UPSTREAM_CHECK_PROXY:-}   # optional: e.g. http://127.0.0.1:7890

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case $1 in
	--out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 2; }; OUT=$2; shift 2 ;;
	--quiet) QUIET=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done
mkdir -p "$OUT"

CURL=(curl -sS --max-time 45 --retry 2 --retry-delay 1)
[ -n "$PROXY" ] && CURL+=(-x "$PROXY")
GIT_ENV=(env GIT_TERMINAL_PROMPT=0)
[ -n "$PROXY" ] && GIT_ENV+=(http_proxy="$PROXY" https_proxy="$PROXY")
have() { command -v "$1" >/dev/null 2>&1; }
for tool in curl git; do
	have "$tool" || { echo "missing required tool: $tool" >&2; exit 2; }
done

CHECKS_JSON="$OUT/checks.jsonl"
: >"$CHECKS_JSON"
record() { # id status detail evidence
	printf '{"id":"%s","status":"%s","detail":"%s","evidence":"%s"}\n' \
		"$(json_escape "$1")" "$2" "$(json_escape "$3")" "$(json_escape "$4")" >>"$CHECKS_JSON"
}
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# ---------------------------------------------------------------- repo refs --
ls_remote_heads() { # outfile url
	"${GIT_ENV[@]}" timeout 90 git ls-remote --heads "$2" >"$1" 2>"$1.err" || {
		record "$(basename "$1")" ERROR "git ls-remote failed" "$(tail -1 "$1.err" 2>/dev/null)"
		return 1
	}
}

probe_kernel_fork() {
	local f="$OUT/yzddmr6-kernel.heads"
	if ! ls_remote_heads "$f" https://github.com/yzddmr6/linux-sm8450-liuqin; then return; fi
	local head lock newer
	head=$(awk '$2=="refs/heads/liuqin-6.17"{print $1}' "$f" | head -1)
	lock=$(sed -n 's/.*`liuqin-6\.17` @ `\([0-9a-f]\{40\}\)`.*/\1/p' \
		"$ROOT/docs/maintenance/upstream-tracking.md" | head -1)
	newer=$(grep -E 'refs/heads/liuqin-(6\.(1[89]|[2-9][0-9])|7\.)' "$f" | head -3 || true)
	local status=OK detail
	if [ -n "$newer" ]; then
		status=CHANGED
		detail="newer-kernel liuqin branch present: $(echo "$newer" | awk '{print $2}' | tr '\n' ' ')"
	elif [ -n "$head" ] && [ -n "$lock" ] && [ "$head" != "$lock" ]; then
		status=CHANGED
		detail="liuqin-6.17 head moved: $head (lock $lock)"
	else
		detail="no >6.17 branch; liuqin-6.17 @ ${head:-?} (lock ${lock:-?})"
	fi
	record "yzddmr6.kernel" "$status" "$detail" "$(basename "$f")"
	say "[$status] kernel fork: $detail"
}

probe_sm8450_base() {
	local f="$OUT/sm8450-mainline.heads"
	if ! ls_remote_heads "$f" https://github.com/sm8450-mainline/linux; then return; fi
	local lines
	lines=$(grep -E 'refs/heads/(master|next|next-new|tyalie)$' "$f" | awk '{print $2"@"substr($1,1,10)}' | tr '\n' ' ')
	record "sm8450.base" INFO "sm8450-mainline/linux heads: ${lines:-none}" "$(basename "$f")"
	say "[INFO] sm8450-mainline/linux: ${lines:-no matching heads}"
}

probe_nixos() {
	local f="$OUT/liuqin-nixos.heads" kd ub kver uver
	if ! ls_remote_heads "$f" https://github.com/Seeker0472/liuqin-nixos; then return; fi
	local head
	head=$(awk '$2=="refs/heads/main"{print $1}' "$f" | head -1)
	kd="$OUT/liuqin-nixos-kernel-default.nix"
	ub="$OUT/liuqin-nixos-uboot-default.nix"
	"${CURL[@]}" -o "$kd" "https://raw.githubusercontent.com/Seeker0472/liuqin-nixos/main/pkgs/kernel/default.nix" || kd=
	"${CURL[@]}" -o "$ub" "https://raw.githubusercontent.com/Seeker0472/liuqin-nixos/main/pkgs/u-boot/default.nix" || ub=
	kver=$([ -n "$kd" ] && sed -n 's/^  version = "\([0-9][^"]*\)";/\1/p' "$kd" | head -1)
	uver=$([ -n "$ub" ] && sed -n 's/^    version = "\(2024\.[^"]*\)";/\1/p' "$ub" | head -1)
	local status=OK detail="main @ ${head:-?}; kernel ${kver:-?}; u-boot ${uver:-?}"
	[ -n "$kver" ] && [ "$kver" != "7.2.5" ] && { status=CHANGED; detail="kernel version changed: $kver (baseline 7.2.5); $detail"; }
	[ -n "$uver" ] && [ "$uver" != "2024.10+a4f9d7fc" ] && { status=CHANGED; detail="u-boot port version changed: $uver (baseline 2024.10+a4f9d7fc); $detail"; }
	record "liuqin-nixos" "$status" "$detail" "$(basename "$f")"
	say "[$status] liuqin-nixos: $detail"
}

probe_mainline_dts() {
	local f="$OUT/mainline-dts.txt"
	: >"$f"
	local probe base label
	for probe in \
		"torvalds https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/arch/arm64/boot/dts/qcom" \
		"linux-next https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/plain/arch/arm64/boot/dts/qcom"; do
		label=${probe%% *}; base=${probe#* }
		for dts in sm8450.dtsi sm8475.dtsi sm8475p.dtsi sm8475-xiaomi-liuqin.dts; do
			code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$base/$dts" || echo ERR)
			printf '%s %s %s\n' "$label" "$code" "$dts" >>"$f"
		done
	done
	local present
	present=$(awk '$2=="200"{print $1":"$3}' "$f" | tr '\n' ' ')
	record "mainline.dts" INFO "present: ${present:-none}" "$(basename "$f")"
	say "[INFO] mainline DTS: ${present:-none}"
}

probe_kernel_org() {
	local f="$OUT/kernel-releases.json"
	"${CURL[@]}" -o "$f" https://www.kernel.org/releases.json || {
		record "kernel.org" ERROR "releases.json fetch failed" "$(basename "$f")"
		return
	}
	if ! have python3; then record "kernel.org" INFO "releases.json saved (python3 missing)" "$(basename "$f")"; return; fi
	local latest
	latest=$(python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
def v(r): return tuple(int(x) for x in r['version'].split('.')[:2])
main=max((r for r in d['releases'] if r['moniker']=='mainline'), key=v)
stable=max((r for r in d['releases'] if r['moniker']=='stable'), key=v)
series=[r for r in d['releases'] if r['moniker']=='stable' and r['version'].startswith('7.')]
print(f"mainline={main['version']} ({main['released']['isodate']}); latest-stable={stable['version']} ({stable['released']['isodate']}); 7.x-stable={max((r['version'] for r in series), key=lambda s: tuple(map(int,s.split('.'))) if s.count('.')==2 else (0,))}")
PY
)
	record "kernel.org" INFO "$latest" "$(basename "$f")"
	say "[INFO] kernel.org: $latest"
}

probe_uboot() {
	local f="$OUT/u-boot.heads"
	if ls_remote_heads "$f" https://github.com/u-boot/u-boot; then
		"${GIT_ENV[@]}" timeout 120 git ls-remote --tags --refs https://github.com/u-boot/u-boot \
			>"$OUT/u-boot.tags" 2>/dev/null || true
		local latest
		latest=$(awk '{print $2}' "$OUT/u-boot.tags" | grep -E '^refs/tags/v20[0-9]{2}\.[0-9]{2}$' | sort -V | tail -1)
		record "u-boot.upstream" INFO "latest release tag: ${latest:-unknown}" "$(basename "$OUT/u-boot.tags")"
		say "[INFO] u-boot upstream: latest ${latest:-unknown}"
	fi
	local bf="$OUT/sm8450-uboot.heads"
	if ls_remote_heads "$bf" https://github.com/sm8450-mainline/u-boot; then
		local b
		b=$(awk '{print $2"@"substr($1,1,10)}' "$bf" | tr '\n' ' ')
		record "u-boot.baseline" INFO "sm8450-mainline/u-boot: ${b:-none}" "$(basename "$bf")"
		say "[INFO] u-boot baseline fork: ${b:-no heads}"
	fi
}

probe_pipa_family() {
	local f="$OUT/pipa-family.heads"
	: >"$f"
	local name url
	for spec in "pipa-mainline/linux https://github.com/pipa-mainline/linux" \
		"PipaDB/linux https://github.com/PipaDB/linux" \
		"rr1111/linux-pipa https://github.com/rr1111/linux-pipa"; do
		name=${spec%% *}; url=${spec#* }
		timeout 90 "${GIT_ENV[@]}" git ls-remote --heads "$url" >>"$f" 2>/dev/null || true
	done
	local newest
	newest=$(awk '{print $2}' "$f" | grep -oE 'refs/heads/pipa/[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | sort -V | tail -3 | tr '\n' ' ')
	record "pipa.family" INFO "highest pipa/* kernel branches: ${newest:-unknown}" "$(basename "$f")"
	say "[INFO] pipa-family kernel branches: ${newest:-unknown}"
}

# ---------------------------------------------------------------- summary ---
write_summary() {
	local changed
	changed=$(grep -c '"status":"CHANGED"' "$CHECKS_JSON" 2>/dev/null || true)
	local errors
	errors=$(grep -c '"status":"ERROR"' "$CHECKS_JSON" 2>/dev/null || true)
	[ -n "$changed" ] || changed=0
	[ -n "$errors" ] || errors=0
	if have python3 && [ -f "$OUT/kernel-releases.json" ]; then
		python3 - "$CHECKS_JSON" "$OUT/summary.json" "$OUT/summary.md" "$ROOT/docs/maintenance/upstream-tracking.md" "$changed" "$errors" <<'PY'
import json,sys,datetime
checks=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
out,md,tracking=sys.argv[2],sys.argv[3],sys.argv[4]
changed,errors=int(sys.argv[5]),int(sys.argv[6])
summary={"format":"liuqin-upstream-check/v1","generated_at":datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
         "changed":changed,"errors":errors,"checks":checks}
json.dump(summary,open(out,"w"),indent=2); open(out,"a").write("\n")
lines=["# Upstream drift snapshot","",f"Generated: {summary['generated_at']}",f"CHANGED: {changed}  ERROR: {errors}","",
       "| check | status | detail |","|---|---|---|"]
for c in checks:
    lines.append(f"| {c['id']} | {c['status']} | {c['detail'].replace('|','/')} |")
lines+=["","Locks are **not** modified by this script. Update docs/maintenance/upstream-tracking.md",
        "and scripts/fetch-upstream.sh together, then re-run CI, only after a reviewed decision.",""]
open(md,"w").write("\n".join(lines))
print(md)
PY
	else
		echo "summary: ${OUT}/checks.jsonl"
	fi
	local drift=0
	grep -q '"status":"CHANGED"' "$CHECKS_JSON" 2>/dev/null && drift=1
	if [ "$drift" -eq 1 ]; then
		say ""
		say "DRIFT DETECTED — review the CHANGED rows in $OUT/summary.md before touching locks."
	else
		say ""
		say "No CHANGED rows: current locks/baselines still match the public upstream state."
	fi
}

probe_kernel_fork
probe_sm8450_base
probe_nixos
probe_mainline_dts
probe_kernel_org
probe_uboot
probe_pipa_family
write_summary
say "evidence: $OUT"
