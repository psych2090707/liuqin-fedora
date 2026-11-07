#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# ci.sh — one entry point for the liuqin (Xiaomi Pad 6 Pro) Fedora ARM64 build
# pipeline, for local use and GitHub Actions.
#
# Stages (in order):
#   env         host build-environment capability check      (scripts/env-check.sh)
#   kernel      AArch64 liuqin kernel cross-build           (scripts/build-kernel.sh)
#   kernel-rpm  kernel-liuqin RPM packaging                 (scripts/build-kernel-rpm.sh)
#   device-rpms device/mobile layer RPMs                    (scripts/build-device-rpms.sh,
#                                                            scripts/build-mobile-rpms.sh)
#   rootfs      mkosi cross-arch Fedora KDE rootfs          (scripts/build-rootfs.sh, needs root)
#   assembly    installer runtime + initramfs + boot.img
#               (scripts/build-installer.sh, build-initramfs.sh, build-bootimg.sh;
#                root.img is produced by the image stage)
#   image       assembled image bundle (scripts/build-image.sh; release mode with
#               --release-gate, partial/dev assembly otherwise)
#   validate    offline artifact verification               (scripts/verify-bundle.sh,
#                                                            image structure only)
#   docs        docs / version-lock / git-dirty checks
#
# Design rules:
#   * Every stage reports PASS / FAIL / WARN / SKIP and writes its own log under
#     out/ci/<run-id>/. Failures exit non-zero by default (fail fast), and the
#     failure message includes a copy-pasteable reproduction command.
#   * Missing builder scripts are SKIP with a "pending" reason, so parallel work
#     never blocks the pipeline. Present scripts are called only through their
#     documented CLI.
#   * NOTHING in this script writes a device, boots the tablet, calls fastboot or
#     touches real device partitions. VM simulation was retired in TN0065.
#   * Fedora release stays at 44. Other release parameters remain available;
#     changing the target requires a separate user request (ADR-0005).
#   * --skip-build runs env/validate/docs only (fast, safe during parallel work);
#     --advisory reports failures without failing the run (used while artifacts
#     are known-incomplete).
#
# Usage: scripts/ci.sh [options]
#   --list                list stages, their scripts and pending interfaces
#   --only LIST           run only these stages (comma/space separated; aliases allowed)
#   --skip-build          skip build stages (env + validate + docs only)
#   --release N           Fedora release (default 44; 45 supported after GA)
#   --profile P           mkosi rootfs profile (default plasma; tty for minimal)
#   --jobs N              parallelism for build stages (default: min(nproc,8))
#   --out DIR             run directory (default: out/ci/<UTC-timestamp>)
#   --fix-env             allow env-check --fix (default: check only, never modify host)
#   --release-gate        enforce the release gate: verify-bundle --release-gate,
#                         docs sha must pass, image assembly must be canonical
#                         (dev artifacts are expected to FAIL the gate)
#   --advisory            non-zero stage results do not fail the run (report only)
#   --keep-going          continue to later stages after a failure (default: fail fast)
#   --require-clean       git-dirty is a FAIL in the docs stage (default: WARN)
#   --no-color            disable ANSI colours
#   -h, --help
#
# Exit codes: 0 = all executed stages PASS/WARN/SKIP; 1 = at least one FAIL;
#             2 = usage error.

set -uo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$PROJECT_ROOT" || exit 2

RELEASE=44
PROFILE=plasma
JOBS=$(( $(nproc 2>/dev/null || echo 4) ))
[ "$JOBS" -gt 8 ] && JOBS=8
SKIP_BUILD=0
ADVISORY=0
KEEP_GOING=0
FIX_ENV=0
REQUIRE_CLEAN=0
RELEASE_GATE=0
COLOR=1
ONLY=()
LIST=0
RUN_DIR=""
RUN_ID=""

ALL_STAGES=(env kernel kernel-rpm device-rpms rootfs assembly image validate docs)
STAGE_DESC=(
    "host build-environment capability check (scripts/env-check.sh)"
    "AArch64 liuqin kernel cross-build (scripts/build-kernel.sh)"
    "kernel-liuqin RPM packaging (scripts/build-kernel-rpm.sh)"
    "device/mobile userspace RPMs (scripts/build-device-rpms.sh, scripts/build-mobile-rpms.sh)"
    "mkosi cross-arch Fedora rootfs build (build-rootfs.sh — needs root)"
    "installer runtime + initramfs + boot.img assembly"
    "assembled image bundle (scripts/build-image.sh; canonical in release mode)"
    "offline artifact verification (verify-bundle.sh)"
    "docs, upstream version pins and git-dirty checks"
)
# stage -> scripts it drives (existence is checked at run time)
declare -A STAGE_SCRIPTS=(
    [env]="scripts/env-check.sh"
    [kernel]="scripts/build-kernel.sh"
    [kernel-rpm]="scripts/build-kernel-rpm.sh"
    [device-rpms]="scripts/build-device-rpms.sh scripts/build-mobile-rpms.sh"
    [rootfs]="scripts/build-rootfs.sh"
    [assembly]="scripts/build-installer.sh scripts/build-initramfs.sh scripts/build-bootimg.sh"
    [image]="scripts/build-image.sh"
    [validate]="scripts/verify-bundle.sh"
    [docs]="scripts/ci.sh"
)

usage() { sed -n '2,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'ci: error: %s\n' "$*" >&2; exit 2; }
color() { # color STATUS
    [ "$COLOR" -eq 0 ] && return 0
    case "$1" in
        PASS) printf '\033[32m%s\033[0m' "$2" ;;
        FAIL) printf '\033[31m%s\033[0m' "$2" ;;
        WARN) printf '\033[33m%s\033[0m' "$2" ;;
        SKIP) printf '\033[90m%s\033[0m' "$2" ;;
        *) printf '%s' "$2" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1; shift ;;
        --only) IFS=', ' read -r -a _only <<< "${2:?--only needs a stage list}"; ONLY+=("${_only[@]}"); shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --release) RELEASE=${2:?--release needs a value}; shift 2 ;;
        --profile) PROFILE=${2:?--profile needs a value}; shift 2 ;;
        --jobs) JOBS=${2:?--jobs needs a value}; shift 2 ;;
        --out) RUN_DIR=${2:?--out needs a directory}; shift 2 ;;
        --with-qemu) die "QEMU simulation was retired (ADR-0005); remove --with-qemu" ;;
        --fix-env) FIX_ENV=1; shift ;;
        --advisory) ADVISORY=1; shift ;;
        --keep-going) KEEP_GOING=1; shift ;;
        --require-clean) REQUIRE_CLEAN=1; shift ;;
        --release-gate) RELEASE_GATE=1; shift ;;
        --no-color) COLOR=0; shift ;;
        --color) COLOR=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

case "$RELEASE" in 44|45) ;; *) die "--release must be 44 or 45 (parameterised; see docs/maintenance/ci.md)" ;; esac
case "$PROFILE" in plasma|tty) ;; *) die "--profile must be plasma or tty" ;; esac
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac

resolve_stage() {
    case "$1" in
        env|env-check) echo env ;;
        kernel|kernel-build) echo kernel ;;
        kernel-rpm|kernelrpm) echo kernel-rpm ;;
        device-rpms|device|rpms|mobile-rpms) echo device-rpms ;;
        rootfs|rootfs-build) echo rootfs ;;
        assembly|bootimg|assemble) echo assembly ;;
        image|image-build|bundle) echo image ;;
        validate|validation|verify) echo validate ;;
        docs|doc|status) echo docs ;;
        all) echo all ;;
        *) echo "" ;;
    esac
}

SELECTED=()
if [ "${#ONLY[@]}" -gt 0 ]; then
    for item in "${ONLY[@]}"; do
        r=$(resolve_stage "$item")
        [ -n "$r" ] || die "unknown stage: $item (see --list)"
        [ "$r" = all ] && { SELECTED=("${ALL_STAGES[@]}"); break; }
        SELECTED+=("$r")
    done
else
    SELECTED=("${ALL_STAGES[@]}")
fi
# de-duplicate while keeping order
declare -A _seen=()
DEDUP=()
for s in "${SELECTED[@]}"; do [ -n "${_seen[$s]:-}" ] || { _seen[$s]=1; DEDUP+=("$s"); }; done
SELECTED=("${DEDUP[@]}")

if [ "$LIST" -eq 1 ]; then
    declare -A DESC=()
    local_i=0
    for s in "${ALL_STAGES[@]}"; do DESC[$s]="${STAGE_DESC[$local_i]}"; local_i=$((local_i + 1)); done
    printf '%-12s %-10s %s\n' "STAGE" "SCRIPTS" "DESCRIPTION"
    for s in "${ALL_STAGES[@]}"; do
        state=""
        for f in ${STAGE_SCRIPTS[$s]}; do
            if [ -e "$PROJECT_ROOT/$f" ]; then state+="ok "; else state+="missing "; fi
        done
        printf '%-12s %-10s %s\n' "$s" "${state% }" "${DESC[$s]}"
    done
    printf '\nFedora release: %s (default 44; --release 45 after GA — see docs/maintenance/ci.md)\n' "$RELEASE"
    printf 'Scripts present: '; for s in "${ALL_STAGES[@]}"; do for f in ${STAGE_SCRIPTS[$s]}; do
        [ -e "$PROJECT_ROOT/$f" ] && printf '%s ' "$f"; done; done; printf '\n'
    printf 'Missing/pending: '; for s in "${ALL_STAGES[@]}"; do for f in ${STAGE_SCRIPTS[$s]}; do
        [ -e "$PROJECT_ROOT/$f" ] || printf '%s ' "$f"; done; done; printf '\n'
    exit 0
fi

# ------------------------------------------------------------------ run set-up --
if [ -z "$RUN_DIR" ]; then
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
    RUN_DIR="$PROJECT_ROOT/out/ci/$RUN_ID"
else
    RUN_ID=$(basename -- "$RUN_DIR")
fi
mkdir -p "$RUN_DIR" || die "cannot create run directory: $RUN_DIR"
printf '%s\n' "$RUN_DIR" > "$PROJECT_ROOT/out/ci/latest"
RUN_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
export FEDORA_RELEASE="$RELEASE"
export LIUQIN_CI_RELEASE_GATE="$RELEASE_GATE"
export LIUQIN_CI_RUN_DIR="$RUN_DIR"

declare -a STAGE_JSON=()
FAILED=0
EXECUTED=0
TMP_SUMMARY="$RUN_DIR/summary.json"
printf '{\n "run_id": "%s",\n "started_at": "%s",\n "release": "%s",\n "profile": "%s",\n "skip_build": %s,\n "stages": [\n' \
    "$RUN_ID" "$RUN_STARTED" "$RELEASE" "$PROFILE" "$([ "$SKIP_BUILD" -eq 1 ] && echo true || echo false)" > "$TMP_SUMMARY"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n'; }

record_stage() { # name status started duration_s steps_json log repro
    local name=$1 status=$2 started=$3 dur=$4 steps=$5 log=$6 repro=$7
    local entry="  {\"name\": \"$name\", \"status\": \"$status\", \"started_at\": \"$started\", \"duration_seconds\": $dur, \"steps\": $steps, \"log\": \"$(json_escape "$log")\", \"repro\": \"$(json_escape "$repro")\"}"
    STAGE_JSON+=("$entry")
    printf '%s\n' "$entry" >> "$RUN_DIR/stages.jsonl"
    [ "$status" = FAIL ] && FAILED=1
    return 0
}

show_step() { # status name detail [log]
    printf '  %s %-34s %s' "$(color "$1" "[$1]")" "$2" "$3"
    [ -n "${4:-}" ] && printf '  (log: %s)' "$4"
    printf '\n'
}

repro_for() {
    local stage=$1
    printf 'bash scripts/ci.sh --only %s --release %s --profile %s%s' \
        "$stage" "$RELEASE" "$PROFILE" "$([ "$SKIP_BUILD" -eq 1 ] && echo ' --skip-build')"
}

have() { [ -e "$PROJECT_ROOT/$1" ]; }

# run_step <stage> <step-name> <log-name> <required:0|1> <cmd...>
# Runs one step, captures stdout+stderr to the stage log, records PASS/FAIL/SKIP.
run_step() {
    local stage=$1 name=$2 logname=$3 required=$4
    shift 4
    local log="$RUN_DIR/$logname"
    local t0 rc
    t0=$(date +%s)
    {
        printf '===== %s / %s =====\n' "$stage" "$name"
        printf 'cwd: %s\ncmd: %s\n\n' "$PROJECT_ROOT" "$*"
    } >> "$log"
    "$@" >> "$log" 2>&1
    rc=$?
    local dur=$(( $(date +%s) - t0 ))
    if [ "$rc" -eq 0 ]; then
        show_step PASS "$name" "ok (${dur}s)" "$logname"
        STEPS_JSON+=("{\"name\": \"$(json_escape "$name")\", \"status\": \"PASS\", \"seconds\": $dur, \"log\": \"$(json_escape "$logname")\"}")
        return 0
    fi
    if [ "$required" -eq 1 ]; then
        show_step FAIL "$name" "exit $rc — see $logname; repro: $(repro_for "$stage")" "$logname"
        STEPS_JSON+=("{\"name\": \"$(json_escape "$name")\", \"status\": \"FAIL\", \"exit_code\": $rc, \"seconds\": $dur, \"log\": \"$(json_escape "$logname")\"}")
        return 1
    fi
    show_step SKIP "$name" "optional step failed (exit $rc) — see $logname"
    STEPS_JSON+=("{\"name\": \"$(json_escape "$name")\", \"status\": \"SKIP\", \"exit_code\": $rc, \"seconds\": $dur, \"log\": \"$(json_escape "$logname")\"}")
    return 0
}

skip_step() { # stage name detail log
    local stage=$1 name=$2 detail=$3 logname=$4
    local log="$RUN_DIR/$logname"
    printf '===== %s / %s =====\nSKIPPED: %s\n' "$stage" "$name" "$detail" >> "$log"
    show_step SKIP "$name" "$detail" "$logname"
    STEPS_JSON+=("{\"name\": \"$(json_escape "$name")\", \"status\": \"SKIP\", \"detail\": \"$(json_escape "$detail")\", \"log\": \"$(json_escape "$logname")\"}")
}

warn_step() { # stage name detail log
    local stage=$1 name=$2 detail=$3 logname=$4
    local log="$RUN_DIR/$logname"
    printf '===== %s / %s =====\nWARN: %s\n' "$stage" "$name" "$detail" >> "$log"
    show_step WARN "$name" "$detail" "$logname"
    STEPS_JSON+=("{\"name\": \"$(json_escape "$name")\", \"status\": \"WARN\", \"detail\": \"$(json_escape "$detail")\", \"log\": \"$(json_escape "$logname")\"}")
}

stage_begin() { STEPS_JSON=(); STAGE_T0=$(date +%s); STAGE_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ); printf '\n=== stage: %s ===\n' "$1"; }
stage_end() { # name status
    local name=$1 status=$2 dur=$(( $(date +%s) - STAGE_T0 ))
    local steps_json
    steps_json="[$(IFS=,; echo "${STEPS_JSON[*]:-}")]"
    record_stage "$name" "$status" "$STAGE_STARTED" "$dur" "$steps_json" "stage-$name.log" "$(repro_for "$name")"
    if [ "$status" = FAIL ]; then
        printf '%s stage %s: FAIL (%ss)\n' "$(color FAIL '[FAIL]')" "$name" "$dur"
        if [ "$KEEP_GOING" -eq 0 ]; then
            printf 'ci: stopping after first failure (use --keep-going to continue). Repro: %s\n' "$(repro_for "$name")" >&2
            finalize 1
        fi
    elif [ "$status" = SKIP ]; then
        printf '%s stage %s: SKIP (%ss)\n' "$(color SKIP '[SKIP]')" "$name" "$dur"
    else
        printf '%s stage %s: %s (%ss)\n' "$(color PASS '[PASS]')" "$name" "$status" "$dur"
    fi
}

finalize() {
    local rc=${1:-0}
    local finished
    finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 - "$RUN_DIR" "$RUN_ID" "$RUN_STARTED" "$finished" "$RELEASE" "$PROFILE" \
        "$SKIP_BUILD" "$([ "$FAILED" -eq 1 ] && echo true || echo false)" >/dev/null 2>&1 <<'PY' || true
import json, sys
run_dir, run_id, started, finished, release, profile, skip_build, failed = sys.argv[1:9]
stages = []
try:
    for line in open(f"{run_dir}/stages.jsonl"):
        line = line.strip()
        if line:
            stages.append(json.loads(line))
except FileNotFoundError:
    pass
result = "FAIL" if failed == "true" else "PASS"
summary = {
    "format": "liuqin-ci-summary/v1",
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "release": release,
    "profile": profile,
    "skip_build": skip_build == "true",
    "result": result,
    "stages": stages,
}
json.dump(summary, open(f"{run_dir}/summary.json", "w"), indent=1, sort_keys=True)
open(f"{run_dir}/summary.json", "a").write("\n")
PY
    local vjson=""
    [ -f "$RUN_DIR/verify-bundle.json" ] && vjson="$RUN_DIR/verify-bundle.json"
    cat > "$RUN_DIR/summary.md" <<EOF
# CI run $RUN_ID

- release: Fedora $RELEASE
- profile: $PROFILE
- skip_build: $([ "$SKIP_BUILD" -eq 1 ] && echo yes || echo no)
- started: $RUN_STARTED
- finished: $finished
- result: $([ "$FAILED" -eq 1 ] && echo FAIL || echo PASS)
- report: \`$RUN_DIR/summary.json\`
$([ -n "$vjson" ] && echo "- structure verification: \`$vjson\`")

| stage | status | duration |
|---|---|---|
EOF
    for s in "${SELECTED[@]}"; do
        local st="SKIP" dur="0"
        local line
        line=$(printf '%s\n' "${STAGE_JSON[@]:-}" | grep -o "\"name\": \"$s\", \"status\": \"[A-Z]*\", \"started_at\": \"[^\"]*\", \"duration_seconds\": [0-9]*" | head -1)
        if [ -n "$line" ]; then
            st=$(printf '%s' "$line" | sed -E 's/.*"status": "([A-Z]+)".*/\1/')
            dur=$(printf '%s' "$line" | sed -E 's/.*"duration_seconds": ([0-9]+).*/\1/')
        fi
        printf '| %s | %s | %ss |\n' "$s" "$st" "$dur" >> "$RUN_DIR/summary.md"
    done
    printf '\nLogs: `%s`\n' "$RUN_DIR" >> "$RUN_DIR/summary.md"
    printf '%s\n' "$RUN_DIR" > "$PROJECT_ROOT/out/ci/latest"
    if [ "$FAILED" -eq 1 ] && [ "$ADVISORY" -eq 0 ]; then
        printf '\n%s run %s FAILED — see %s/summary.md and stage logs; repro: bash scripts/ci.sh --release %s%s\n' \
            "$(color FAIL 'RESULT:')" "$RUN_ID" "$RUN_DIR" "$RELEASE" "$([ "$SKIP_BUILD" -eq 1 ] && echo ' --skip-build')" >&2
        exit 1
    fi
    if [ "$FAILED" -eq 1 ] && [ "$ADVISORY" -eq 1 ]; then
        printf '\nRESULT: FAIL (advisory: exit code forced to 0) — see %s/summary.md\n' "$RUN_DIR"
    else
        printf '\nRESULT: PASS — %s/summary.md\n' "$RUN_DIR"
    fi
    exit 0
}

printf 'liuqin Fedora ARM64 CI — release=%s profile=%s jobs=%s skip_build=%s\n' "$RELEASE" "$PROFILE" "$JOBS" "$SKIP_BUILD"
printf 'run directory: %s\n' "$RUN_DIR"

# ---------------------------------------------------------------------- env --
run_env() {
    stage_begin env
    if ! have scripts/env-check.sh; then
        skip_step env env-check "scripts/env-check.sh not present" "stage-env.log"
        stage_end env SKIP
        return 0
    fi
    local args=(--quiet)
    [ "$FIX_ENV" -eq 1 ] && args=(--fix "${args[@]}")
    if run_step env env-check stage-env.log 1 bash scripts/env-check.sh "${args[@]}"; then
        stage_end env PASS
    else
        stage_end env FAIL
    fi
}

# ------------------------------------------------------------------- kernel --
run_kernel() {
    stage_begin kernel
    if [ "$SKIP_BUILD" -eq 1 ]; then
        skip_step kernel kernel-build "--skip-build" "stage-kernel.log"
        stage_end kernel SKIP
        return 0
    fi
    if ! have scripts/build-kernel.sh; then
        skip_step kernel kernel-build "scripts/build-kernel.sh not present (pending kernel-builder)" "stage-kernel.log"
        stage_end kernel SKIP
        return 0
    fi
    if run_step kernel kernel-build stage-kernel.log 1 \
        bash scripts/build-kernel.sh --jobs "$JOBS" --out "$PROJECT_ROOT/out/kernel"; then
        stage_end kernel PASS
    else
        stage_end kernel FAIL
    fi
}

# --------------------------------------------------------------- kernel-rpm --
run_kernel_rpm() {
    stage_begin kernel-rpm
    if [ "$SKIP_BUILD" -eq 1 ]; then
        skip_step kernel-rpm kernel-liuqin-rpm "--skip-build" "stage-kernel-rpm.log"
        stage_end kernel-rpm SKIP
        return 0
    fi
    if ! have scripts/build-kernel-rpm.sh; then
        skip_step kernel-rpm kernel-liuqin-rpm \
            "pending: scripts/build-kernel-rpm.sh (kernel-builder task) — interface documented in docs/maintenance/ci.md" \
            "stage-kernel-rpm.log"
        stage_end kernel-rpm SKIP
        return 0
    fi
    if run_step kernel-rpm kernel-liuqin-rpm stage-kernel-rpm.log 1 \
        bash scripts/build-kernel-rpm.sh; then
        stage_end kernel-rpm PASS
    else
        stage_end kernel-rpm FAIL
    fi
}

# -------------------------------------------------------------- device-rpms --
run_device_rpms() {
    stage_begin device-rpms
    if [ "$SKIP_BUILD" -eq 1 ]; then
        skip_step device-rpms device-rpm-set "--skip-build" "stage-device-rpms.log"
        stage_end device-rpms SKIP
        return 0
    fi
    local status=PASS
    if ! have scripts/build-device-rpms.sh; then
        skip_step device-rpms device-rpm-set \
            "pending: scripts/build-device-rpms.sh (device-packager task)" "stage-device-rpms.log"
    elif ! run_step device-rpms device-rpm-set stage-device-rpms.log 1 \
        bash scripts/build-device-rpms.sh; then
        status=FAIL
    fi
    if ! have scripts/build-mobile-rpms.sh; then
        skip_step device-rpms mobile-rpms "scripts/build-mobile-rpms.sh not present" "stage-device-rpms.log"
    elif ! run_step device-rpms mobile-rpms stage-device-rpms.log 1 \
        bash scripts/build-mobile-rpms.sh all; then
        status=FAIL
    fi
    stage_end device-rpms "$status"
}

# ------------------------------------------------------------------- rootfs --
run_rootfs() {
    stage_begin rootfs
    if [ "$SKIP_BUILD" -eq 1 ]; then
        skip_step rootfs mkosi-rootfs "--skip-build" "stage-rootfs.log"
        stage_end rootfs SKIP
        return 0
    fi
    if ! have scripts/build-rootfs.sh; then
        skip_step rootfs mkosi-rootfs "scripts/build-rootfs.sh not present" "stage-rootfs.log"
        stage_end rootfs SKIP
        return 0
    fi
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        skip_step rootfs mkosi-rootfs \
            "needs root (mkosi) and passwordless sudo is unavailable in this session" "stage-rootfs.log"
        stage_end rootfs SKIP
        return 0
    fi
    if run_step rootfs mkosi-rootfs stage-rootfs.log 1 \
        bash scripts/build-rootfs.sh --release "$RELEASE" --profile "$PROFILE" --jobs "$JOBS"; then
        stage_end rootfs PASS
    else
        stage_end rootfs FAIL
    fi
}

# ----------------------------------------------------------------- assembly --
run_assembly() {
    stage_begin assembly
    if [ "$SKIP_BUILD" -eq 1 ]; then
        skip_step assembly assembly "--skip-build" "stage-assembly.log"
        stage_end assembly SKIP
        return 0
    fi
    local status=PASS
    local rootfs_tree="$PROJECT_ROOT/out/rootfs/rootfs"

    # 1) installer runtime (optional; depends on rootfs tree or rpms)
    if ! have scripts/build-installer.sh; then
        skip_step assembly installer-runtime "pending: scripts/build-installer.sh" "stage-assembly.log"
    elif [ ! -d "$rootfs_tree" ]; then
        skip_step assembly installer-runtime \
            "out/rootfs/rootfs missing (rootfs stage not completed); run rootfs stage first" "stage-assembly.log"
    elif ! run_step assembly installer-runtime stage-assembly.log 0 \
        bash scripts/build-installer.sh --from-rootfs "$rootfs_tree"; then
        :
    fi

    # 2) initramfs (device-firmware free dev image; production passes a firmware pool)
    if ! have scripts/build-initramfs.sh; then
        skip_step assembly initramfs "pending: scripts/build-initramfs.sh" "stage-assembly.log"
    else
        local manifest="$PROJECT_ROOT/tools/examples/fedora-root.manifest.example"
        local manifest_args=(--allow-missing-firmware)
        if [ -f "$PROJECT_ROOT/out/rootfs/rootfs.hashes" ]; then
            manifest="$PROJECT_ROOT/out/rootfs/rootfs.hashes"
            manifest_args=()
        fi
        if ! run_step assembly initramfs stage-assembly.log 1 \
            bash scripts/build-initramfs.sh --out "$PROJECT_ROOT/out/boot" \
                --rootfs-manifest "$manifest" "${manifest_args[@]}"; then
            status=FAIL
        fi
    fi

    # 3) boot.img (Android boot image v2) — boot-builder already delivers this script.
    if ! have scripts/build-bootimg.sh; then
        skip_step assembly boot-img "pending: scripts/build-bootimg.sh" "stage-assembly.log"
    else
        if ! run_step assembly boot-img stage-assembly.log 1 \
            bash scripts/build-bootimg.sh --kernel-out "$PROJECT_ROOT/out/kernel" --out "$PROJECT_ROOT/out/boot"; then
            status=FAIL
        fi
    fi
    stage_end assembly "$status"
}

# -------------------------------------------------------------------- image --
run_image() {
    stage_begin image
    if [ "$SKIP_BUILD" -eq 1 ]; then
        skip_step image image-bundle "--skip-build" "stage-image.log"
        stage_end image SKIP
        return 0
    fi
    if ! have scripts/build-image.sh; then
        skip_step image image-bundle "scripts/build-image.sh not present (image-builder pending)" "stage-image.log"
        stage_end image SKIP
        return 0
    fi
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        skip_step image image-bundle \
            "needs root for rootfs staging (mkfs/mount/rpm --root); no passwordless sudo in this session" \
            "stage-image.log"
        stage_end image SKIP
        return 0
    fi
    local args=(--no-qemu --out "$RUN_DIR/images" --work "$RUN_DIR/image-build")
    if [ "$RELEASE_GATE" -eq 1 ]; then
        # canonical mode: forces --dtb-source stock-rom, kernel RPM payload, full
        # firmware pool, full root contract; fail-closed when the user's stock
        # ROM / firmware inputs are absent.
        args+=(--build-mode release)
        if run_step image image-bundle stage-image.log 1 bash scripts/build-image.sh "${args[@]}"; then
            stage_end image PASS
        else
            stage_end image FAIL
        fi
        return 0
    fi
    args+=(--partial)
    if run_step image image-bundle stage-image.log 0 bash scripts/build-image.sh "${args[@]}"; then
        stage_end image PASS
    else
        stage_end image FAIL
    fi
}

# ----------------------------------------------------------------- validate --
run_validate() {
    stage_begin validate
    local status=PASS
    if ! have scripts/verify-bundle.sh; then
        skip_step validate verify-bundle "scripts/verify-bundle.sh not present" "stage-validate.log"
        stage_end validate SKIP
        return 0
    fi
    local args=(--json "$RUN_DIR/verify-bundle.json" --expected-release "$RELEASE" --no-color)
    [ "$RELEASE_GATE" -eq 1 ] && args+=(--release-gate)
    if [ -d "$PROJECT_ROOT/out/rootfs/rootfs" ]; then
        args+=(--rootfs "$PROJECT_ROOT/out/rootfs/rootfs")
    fi
    if ! run_step validate verify-bundle stage-validate.log 1 bash scripts/verify-bundle.sh "${args[@]}"; then
        status=FAIL
    fi
    stage_end validate "$status"
}

# --------------------------------------------------------------------- docs --
run_docs() {
    stage_begin docs
    local status=PASS
    local missing=()
    for f in README.md AGENTS.md NOTICE LICENSE docs/STATUS.md docs/maintenance/upstream-tracking.md \
             docs/maintenance/build-pipeline.md docs/maintenance/build-environment.md docs/maintenance/kernel-build.md \
             docs/adr/0002-build-pipeline.md docs/maintenance/ci.md; do
        [ -e "$PROJECT_ROOT/$f" ] || missing+=("$f")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        show_step PASS docs.required "all required documents present" "stage-docs.log"
        STEPS_JSON+=("{\"name\": \"docs.required\", \"status\": \"PASS\"}")
    else
        show_step FAIL docs.required "missing: ${missing[*]}" "stage-docs.log"
        STEPS_JSON+=("{\"name\": \"docs.required\", \"status\": \"FAIL\", \"missing\": \"$(json_escape "${missing[*]}")\"}")
        status=FAIL
    fi
    {
        printf '===== docs / required =====\n'
        printf 'missing: %s\n' "${missing[*]:-none}"
    } >> "$RUN_DIR/stage-docs.log"

    # upstream version pins must be consistent across the three places that carry them
    local pin_ok=1 pin_detail=""
    if [ -f docs/maintenance/upstream-tracking.md ]; then
        grep -q 'f5a535f5c1c980f042b58cb77467ff8f02a5518e' docs/maintenance/upstream-tracking.md || { pin_ok=0; pin_detail+="device commit missing in docs/maintenance/upstream-tracking.md; "; }
        grep -q 'fe81794b5e1b8a3f11a165f3acbfdb8fa671dbb3' docs/maintenance/upstream-tracking.md || { pin_ok=0; pin_detail+="kernel commit missing in docs/maintenance/upstream-tracking.md; "; }
        grep -q '1c9cbd3983210a2c585311ee86b46ef8cb2c3c32' docs/maintenance/upstream-tracking.md || { pin_ok=0; pin_detail+="pipa commit missing in docs/maintenance/upstream-tracking.md (TODO left upstream); "; }
    else
        pin_ok=0; pin_detail+="docs/maintenance/upstream-tracking.md missing; "
    fi
    if [ -f scripts/fetch-upstream.sh ]; then
        grep -q 'f5a535f5c1c980f042b58cb77467ff8f02a5518e' scripts/fetch-upstream.sh || { pin_ok=0; pin_detail+="fetch-upstream.sh device pin differs; "; }
        grep -q 'fe81794b5e1b8a3f11a165f3acbfdb8fa671dbb3' scripts/fetch-upstream.sh || { pin_ok=0; pin_detail+="fetch-upstream.sh kernel pin differs; "; }
    fi
    if [ "$pin_ok" -eq 1 ]; then
        show_step PASS docs.upstream-pins "upstream pins consistent"
        STEPS_JSON+=("{\"name\": \"docs.upstream-pins\", \"status\": \"PASS\"}")
        printf 'PASS: upstream pins consistent\n' >> "$RUN_DIR/stage-docs.log"
    else
        show_step WARN docs.upstream-pins "$pin_detail" "stage-docs.log"
        STEPS_JSON+=("{\"name\": \"docs.upstream-pins\", \"status\": \"WARN\", \"detail\": \"$(json_escape "$pin_detail")\"}")
        printf 'WARN: %s\n' "$pin_detail" >> "$RUN_DIR/stage-docs.log"
    fi

    # target Fedora release consistency
    if [ -f docs/adr/0002-build-pipeline.md ]; then
        if grep -qE "目标 Fedora 版本[^0-9]*Fedora $RELEASE" docs/adr/0002-build-pipeline.md; then
            show_step PASS docs.release "ADR-0002 mentions Fedora $RELEASE" "stage-docs.log"
            STEPS_JSON+=("{\"name\": \"docs.release\", \"status\": \"PASS\"}")
        else
            show_step WARN docs.release "ADR-0002 does not mention Fedora $RELEASE; update ADR/STATUS before switching release" "stage-docs.log"
            STEPS_JSON+=("{\"name\": \"docs.release\", \"status\": \"WARN\"}")
        fi
    fi

    # git dirty state
    local dirty
    dirty=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l)
    if [ "$dirty" -eq 0 ]; then
        show_step PASS docs.git "working tree clean" "stage-docs.log"
        STEPS_JSON+=("{\"name\": \"docs.git\", \"status\": \"PASS\"}")
        printf 'PASS: git clean\n' >> "$RUN_DIR/stage-docs.log"
    else
        local dirty_list
        dirty_list=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | head -8 | tr '\n' ';')
        if [ "$REQUIRE_CLEAN" -eq 1 ]; then
            show_step FAIL docs.git "$dirty dirty entries (--require-clean); e.g. $dirty_list" "stage-docs.log"
            STEPS_JSON+=("{\"name\": \"docs.git\", \"status\": \"FAIL\", \"dirty\": $dirty}")
            status=FAIL
        else
            show_step WARN docs.git "$dirty dirty entries (parallel work expected; --require-clean to fail)" "stage-docs.log"
            STEPS_JSON+=("{\"name\": \"docs.git\", \"status\": \"WARN\", \"dirty\": $dirty}")
        fi
        printf 'git status (%s entries):\n%s\n' "$dirty" "$dirty_list" >> "$RUN_DIR/stage-docs.log"
    fi
    # docs <-> artifact sha256 consistency (release gate: FAIL; dev: WARN)
    if have scripts/verify-bundle.sh; then
        local docs_rc=0
        local docs_args=(--docs-sha --no-color --json "$RUN_DIR/docs-sha.json")
        [ "$RELEASE_GATE" -eq 1 ] && docs_args+=(--release-gate)
        bash scripts/verify-bundle.sh "${docs_args[@]}" > "$RUN_DIR/docs-sha.human" 2>&1 || docs_rc=$?
        local docs_result=""
        docs_result=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"]["result"])' \
            "$RUN_DIR/docs-sha.json" 2>/dev/null || true)
        if [ "$docs_rc" -eq 0 ] && [ "$docs_result" != "WARN" ]; then
            show_step PASS docs.sha-consistency "docs sha256 references match current artifacts" "stage-docs.log"
            STEPS_JSON+=("{\"name\": \"docs.sha-consistency\", \"status\": \"PASS\"}")
        elif [ "$RELEASE_GATE" -eq 1 ]; then
            show_step FAIL docs.sha-consistency \
                "stale/unresolvable sha256 in docs (see docs-sha.json); release gate requires docs to match artifacts" \
                "stage-docs.log"
            STEPS_JSON+=("{\"name\": \"docs.sha-consistency\", \"status\": \"FAIL\"}")
            status=FAIL
        else
            warn_step docs docs.sha-consistency \
                "dev mode: stale doc sha256 references (expected until release cleanup; see docs-sha.json)" \
                "stage-docs.log"
        fi
        printf 'docs-sha exit=%s result=%s\n' "$docs_rc" "$docs_result" >> "$RUN_DIR/stage-docs.log"
    fi
    stage_end docs "$status"
}

# ------------------------------------------------------------------- runner --
for stage in "${SELECTED[@]}"; do
    EXECUTED=$((EXECUTED + 1))
    case "$stage" in
        env) run_env ;;
        kernel) run_kernel ;;
        kernel-rpm) run_kernel_rpm ;;
        device-rpms) run_device_rpms ;;
        rootfs) run_rootfs ;;
        assembly) run_assembly ;;
        image) run_image ;;
        validate) run_validate ;;
        docs) run_docs ;;
        *) die "internal: unhandled stage $stage" ;;
    esac
    [ "$FAILED" -eq 1 ] && [ "$KEEP_GOING" -eq 0 ] && break
done

if [ "$EXECUTED" -eq 0 ]; then
    die "no stages selected"
fi
finalize 0
