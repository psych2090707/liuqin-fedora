#!/usr/bin/env bash
# env-check.sh - idempotent build-environment verification for the
# Xiaomi Pad 6 Pro (liuqin, SM8475) Fedora ARM64 + KDE project.
#
# Verifies that an x86_64 host can (a) build/run an aarch64 Fedora rootfs through
# qemu-user binfmt + mkosi/podman, and (b) cross-compile the arm64 liuqin kernel.
# Prints a PASS/WARN/FAIL/SKIP table and exits non-zero when anything FAILs.
#
# Usage:
#   scripts/env-check.sh            # check only
#   scripts/env-check.sh --fix      # also apply safe, idempotent host fixes:
#                                   #   - register qemu-aarch64 binfmt with systemd-binfmt
#                                   #   - create the space-free bind mount needed by kbuild
#   scripts/env-check.sh --quiet    # one line per failing check only
#
# --fix never installs packages and never changes project files; missing packages
# are reported with the exact pacman command instead.

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIX=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=1 ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
    esac
done

# Reference versions this project was validated against (2026-10, CachyOS).
# They are informational: newer versions pass as long as capabilities hold.
EXPECTED_PODMAN_MAJOR=6
EXPECTED_MKOSI_MAJOR=27
EXPECTED_GCC_MAJOR=16
FEDORA_IMAGE="quay.io/fedora/fedora:44"
BINFMT_CONF=/etc/binfmt.d/qemu-aarch64.conf
BINFMT_INTERP=/usr/bin/qemu-aarch64-static
# aarch64 ELF: magic + mask from qemu's scripts/qemu-binfmt-conf.sh.
BINFMT_MAGIC='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
BINFMT_MASK='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
BINFMT_LINE=":qemu-aarch64:M::${BINFMT_MAGIC}:${BINFMT_MASK}:${BINFMT_INTERP}:PF"
SPACE_MOUNT=/mnt/fedora-build
CHECK_DIR="$PROJECT_ROOT/out/env-smoke/check"

PASS=0; WARN=0; FAIL=0; SKIP=0
declare -a ROWS=()

# row <category> <check> <status> <detail>
row() {
    local cat="$1" check="$2" status="$3" detail="${4:-}"
    case "$status" in
        PASS) PASS=$((PASS+1)) ;;
        WARN) WARN=$((WARN+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        SKIP) SKIP=$((SKIP+1)) ;;
    esac
    ROWS+=("$cat|$check|$status|$detail")
}

have() { command -v "$1" >/dev/null 2>&1; }
first_line() { head -n1 | tr -d '\r'; }
# version_major <tool> : first number in --version output
version_major() { "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1; }

say_fix() { printf '[fix] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Host facts
# ---------------------------------------------------------------------------
HOST_ARCH="$(uname -m)"
HOST_KERNEL="$(uname -r)"
HOST_DISTRO="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${NAME:-unknown}" "${VERSION_ID:-rolling}")"
HOST_CPUS="$(nproc 2>/dev/null || echo '?')"
HOST_RAM_GB="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
FREE_GB="$(df -BG --output=avail "$PROJECT_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')"

if [ "$HOST_ARCH" = "x86_64" ]; then
    row host "architecture x86_64" PASS "$HOST_DISTRO, kernel $HOST_KERNEL, ${HOST_CPUS}C/${HOST_RAM_GB}G RAM"
else
    row host "architecture x86_64" FAIL "host is $HOST_ARCH; this project assumes an x86_64 cross-build host"
fi

if [ "${FREE_GB:-0}" -ge 80 ]; then
    row host "free disk >= 80 GiB" PASS "${FREE_GB} GiB free on project filesystem"
elif [ "${FREE_GB:-0}" -ge 40 ]; then
    row host "free disk >= 80 GiB" WARN "${FREE_GB} GiB free; mkosi + kernel builds expect >= 80 GiB headroom"
else
    row host "free disk >= 80 GiB" FAIL "${FREE_GB} GiB free; move caches/out to a bigger filesystem"
fi

if sudo -n true 2>/dev/null; then
    row host "sudo NOPASSWD" PASS "sudo -n works (needed for rootful podman/mkosi and binfmt)"
else
    row host "sudo NOPASSWD" FAIL "sudo -n fails; rootful podman/mkosi and binfmt registration are blocked"
fi

# Running kernel must have a matching /lib/modules tree, otherwise podman bridge
# networking fails (netavark: create bridge: Operation not supported).
if [ -d "/lib/modules/$HOST_KERNEL" ]; then
    row host "kernel $HOST_KERNEL modules present" PASS
else
    ROW_INSTALLED="$(ls -1 /lib/modules 2>/dev/null | tr '\n' ' ')"
    row host "kernel $HOST_KERNEL modules present" WARN "running kernel has no module tree (installed: ${ROW_INSTALLED:-none}); podman bridge networking fails until reboot into the installed kernel"
fi

# ---------------------------------------------------------------------------
# 1. Required tools and versions
# ---------------------------------------------------------------------------
check_tool() { # <cmd> <label> <pass-detail-expression...>
    local cmd="$1" label="$2"
    if ! have "$cmd"; then
        row tool "$label" FAIL "missing from PATH (pacman: $3)"
        return 1
    fi
    local ver
    ver="$( ( "$cmd" --version 2>/dev/null || "$cmd" version 2>/dev/null || true ) | first_line)"
    row tool "$label" PASS "$ver"
}
check_tool podman      podman      "$(printf '%s' 'podman')"
check_tool mkosi       mkosi       "$(printf '%s' 'mkosi')"
check_tool qemu-aarch64-static "qemu-aarch64-static" "$(printf '%s' 'qemu-user-static')"
check_tool aarch64-linux-gnu-gcc "aarch64-linux-gnu-gcc" "$(printf '%s' 'aarch64-linux-gnu-gcc')"
check_tool dtc         dtc         "$(printf '%s' 'dtc')"
check_tool clang       clang       "$(printf '%s' 'clang')"
check_tool ld.lld      ld.lld      "$(printf '%s' 'lld')"
check_tool pahole      pahole      "$(printf '%s' 'pahole')"
check_tool bc          bc          "$(printf '%s' 'bc')"
check_tool bison       bison       "$(printf '%s' 'bison')"
check_tool flex        flex        "$(printf '%s' 'flex')"
check_tool python3     python3     "$(printf '%s' 'python3')"
check_tool /usr/bin/time "/usr/bin/time" "$(printf '%s' 'time')"

for hdr in /usr/include/libelf.h /usr/include/openssl/ssl.h; do
    if [ -f "$hdr" ]; then
        row tool "header $hdr" PASS
    else
        row tool "header $hdr" FAIL "install elfutils / openssl dev headers (pacman: elfutils openssl)"
    fi
done

PAHOLE_VER="$(pahole --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [ -n "${PAHOLE_VER:-}" ] && awk -v v="$PAHOLE_VER" 'BEGIN { exit !(v + 0 >= 1.16) }'; then
    row tool "pahole >= 1.16 (BTF)" PASS "pahole $PAHOLE_VER"
else
    row tool "pahole >= 1.16 (BTF)" WARN "pahole too old or unknown; CONFIG_DEBUG_INFO_BTF may fail"
fi

if have podman; then
    PM="$(version_major podman)"
    if [ -n "$PM" ] && [ "$PM" -ge "$EXPECTED_PODMAN_MAJOR" ]; then
        row tool "podman major >= $EXPECTED_PODMAN_MAJOR" PASS "podman $PM"
    else
        row tool "podman major >= $EXPECTED_PODMAN_MAJOR" WARN "podman $PM may predate tested behaviour"
    fi
fi
if have mkosi; then
    MM="$(version_major mkosi)"
    if [ -n "$MM" ] && [ "$MM" -ge "$EXPECTED_MKOSI_MAJOR" ]; then
        row tool "mkosi major >= $EXPECTED_MKOSI_MAJOR" PASS "mkosi $MM"
    else
        row tool "mkosi major >= $EXPECTED_MKOSI_MAJOR" WARN "mkosi $MM may not support cross-arch ToolsTree=yes"
    fi
fi
if have aarch64-linux-gnu-gcc; then
    GM="$(version_major aarch64-linux-gnu-gcc)"
    if [ -n "$GM" ] && [ "$GM" -ge "$EXPECTED_GCC_MAJOR" ]; then
        row tool "cross gcc major >= $EXPECTED_GCC_MAJOR" PASS "gcc $GM"
    else
        row tool "cross gcc major >= $EXPECTED_GCC_MAJOR" WARN "gcc $GM; kernel 6.17 tree was validated with gcc 16"
    fi
fi

# ---------------------------------------------------------------------------
# 2. binfmt_misc: qemu-aarch64 registration (host side)
# ---------------------------------------------------------------------------
binfmt_registered() {
    local f=/proc/sys/fs/binfmt_misc/qemu-aarch64
    [ -f "$f" ] && grep -q '^enabled' "$f" 2>/dev/null && grep -qx "interpreter $BINFMT_INTERP" "$f" 2>/dev/null
}

register_binfmt() {
    local target="$1" needs_restart=0
    if [ ! -f "$BINFMT_CONF" ] || ! grep -qxF "$BINFMT_LINE" "$BINFMT_CONF" 2>/dev/null; then
        say_fix "writing $BINFMT_CONF"
        printf '%s\n' "$BINFMT_LINE" | sudo -n tee "$BINFMT_CONF" >/dev/null || return 1
        needs_restart=1
    fi
    if [ ! -f /proc/sys/fs/binfmt_misc/register ] || ! binfmt_registered; then
        needs_restart=1
    fi
    if [ "$needs_restart" = 1 ]; then
        say_fix "systemctl restart systemd-binfmt"
        sudo -n systemctl restart systemd-binfmt || return 1
    fi
    binfmt_registered
}

if binfmt_registered; then
    row binfmt "qemu-aarch64 registered" PASS "$BINFMT_INTERP (flags PF)"
elif [ "$FIX" = 1 ] && register_binfmt; then
    row binfmt "qemu-aarch64 registered" PASS "registered now via $BINFMT_CONF"
else
    row binfmt "qemu-aarch64 registered" FAIL "not registered; run: scripts/env-check.sh --fix  (systemd-binfmt + $BINFMT_CONF)"
fi

if [ -f "$BINFMT_CONF" ]; then
    row binfmt "persistent config $BINFMT_CONF" PASS
elif binfmt_registered; then
    row binfmt "persistent config $BINFMT_CONF" WARN "registered but not persistent across reboot; --fix writes it"
else
    row binfmt "persistent config $BINFMT_CONF" FAIL "missing; --fix writes it"
fi

# ---------------------------------------------------------------------------
# 3. qemu-user end-to-end: compile and execute a static aarch64 ELF
# ---------------------------------------------------------------------------
mkdir -p "$CHECK_DIR" 2>/dev/null
ARM64_OK=0
if have aarch64-linux-gnu-gcc; then
    cat > "$CHECK_DIR/hello.c" <<'EOF'
#include <stdio.h>
#include <sys/utsname.h>
int main(void) { struct utsname u; uname(&u); printf("%s\n", u.machine); return 0; }
EOF
    if aarch64-linux-gnu-gcc -static -O2 -o "$CHECK_DIR/hello-aarch64" "$CHECK_DIR/hello.c" 2>"$CHECK_DIR/gcc.err"; then
        row qemu-user "static aarch64 ELF cross-compiles" PASS "$CHECK_DIR/hello-aarch64"
        OUT="$(timeout 30 "$CHECK_DIR/hello-aarch64" 2>"$CHECK_DIR/run.err" | head -1)"
        if [ "$OUT" = "aarch64" ]; then
            row qemu-user "static aarch64 ELF executes" PASS "binfmt/qemu-user returns 'aarch64'"
            ARM64_OK=1
        else
            row qemu-user "static aarch64 ELF executes" FAIL "exec failed (${OUT:-no output}); run --fix to register binfmt"
        fi
    else
        row qemu-user "static aarch64 ELF cross-compiles" FAIL "cross gcc cannot link static binary; install aarch64-linux-gnu-glibc"
    fi
else
    row qemu-user "static aarch64 ELF cross-compiles" SKIP "no aarch64-linux-gnu-gcc"
fi

# ---------------------------------------------------------------------------
# 4. podman: rootful storage + arm64 container execution
# ---------------------------------------------------------------------------
PODMAN_OK=0
DRV=""
IMAGE_EXISTS=0
if have podman; then
    if PODMAN_INFO="$(sudo -n podman info --format '{{.Store.GraphDriverName}} rootless={{.Host.Security.Rootless}}' 2>"$CHECK_DIR/podman-info.err")"; then
        row podman "rootful storage initialises" PASS "$PODMAN_INFO"
        PODMAN_OK=1
    else
        DRV="$(sudo -n podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || true)"
        if [ -z "$DRV" ] && grep -qi 'overlay.*btrfs' "$CHECK_DIR/podman-info.err" 2>/dev/null; then
            row podman "rootful storage initialises" FAIL "overlay-on-btrfs unavailable: install fuse-overlayfs (pacman -S fuse-overlayfs) or set driver=btrfs"
        else
            row podman "rootful storage initialises" FAIL "$(head -1 "$CHECK_DIR/podman-info.err" 2>/dev/null)"
        fi
    fi

    if [ "$PODMAN_OK" = 1 ]; then
        if sudo -n podman image exists "$FEDORA_IMAGE" 2>/dev/null; then
            IMAGE_EXISTS=1
            row podman "arm64 image $FEDORA_IMAGE" PASS "present locally"
            if [ "$ARM64_OK" = 1 ]; then
                RUN_OUT="$(timeout 180 sudo -n podman run --rm --network=none --platform linux/arm64 "$FEDORA_IMAGE" uname -m 2>"$CHECK_DIR/podman-run.err" | head -1)"
                if [ "$RUN_OUT" = "aarch64" ]; then
                    row podman "arm64 ELF inside container" PASS "uname -m = aarch64 (no --privileged needed)"
                else
                    row podman "arm64 ELF inside container" FAIL "uname -m = '${RUN_OUT:-empty}'; see $CHECK_DIR/podman-run.err"
                fi
            else
                row podman "arm64 ELF inside container" SKIP "host qemu-user binfmt is not working yet"
            fi
        else
            row podman "arm64 image $FEDORA_IMAGE" SKIP "pull with: sudo podman pull --platform linux/arm64 $FEDORA_IMAGE"
            row podman "arm64 ELF inside container" SKIP "image not pulled yet"
        fi
        # Bridge networking needs kernel modules matching the running kernel.
        NET_OUT=""
        if [ "$IMAGE_EXISTS" = 1 ]; then
        NET_OUT="$(timeout 120 sudo -n podman run --rm --platform linux/arm64 "$FEDORA_IMAGE" true 2>&1 | tail -1)"
        case "$NET_OUT" in
            ''|*'Operation not supported'*)
                if [ -d "/lib/modules/$HOST_KERNEL" ]; then
                    row podman "default bridge networking" WARN "bridge unavailable: $NET_OUT (use --network=host/none, or reboot)"
                else
                    row podman "default bridge networking" WARN "running kernel lacks its module tree; use --network=host/none or reboot to $(ls -1 /lib/modules 2>/dev/null | tail -1)"
                fi
                ;;
            *) row podman "default bridge networking" PASS ;;
        esac
        fi
        if have fuse-overlayfs; then
            row podman "fuse-overlayfs installed" PASS "overlay works on btrfs"
        elif [ "$DRV" = "btrfs" ]; then
            row podman "fuse-overlayfs installed" PASS "not needed: storage driver is btrfs"
        else
            row podman "fuse-overlayfs installed" WARN "not installed; btrfs hosts need it for the overlay driver"
        fi
    fi
else
    row podman "rootful storage initialises" SKIP "podman not installed"
fi

# ---------------------------------------------------------------------------
# 5. mkosi cross-arch readiness
# ---------------------------------------------------------------------------
if have mkosi; then
    mkdir -p "$CHECK_DIR/mkosi-probe"
    cat > "$CHECK_DIR/mkosi-probe/mkosi.conf" <<'EOF'
[Distribution]
Distribution=fedora
Release=44
Architecture=arm64
[Output]
Format=directory
[Content]
Packages=bash
EOF
    if SUMMARY="$(cd "$CHECK_DIR/mkosi-probe" && mkosi summary 2>"$CHECK_DIR/mkosi-summary.err")"; then
        if printf '%s' "$SUMMARY" | grep -qE 'Distribution:[[:space:]]*fedora' && printf '%s' "$SUMMARY" | grep -qiE 'Architecture:[[:space:]]*arm64'; then
            row mkosi "cross-arch config parses" PASS "fedora/44/arm64 directory image"
        else
            row mkosi "cross-arch config parses" WARN "summary lacks expected fedora/arm64 values"
        fi
        if grep -q '^ToolsTree=yes' "$PROJECT_ROOT/out/env-smoke/mkosi-smoke/mkosi.conf" 2>/dev/null; then
            row mkosi "ToolsTree=yes available" PASS "smoke config builds an Arch tools tree (contains dnf5) via pacman"
        else
            row mkosi "ToolsTree=yes available" WARN "out/env-smoke/mkosi-smoke/mkosi.conf does not set ToolsTree=yes"
        fi
    else
        row mkosi "cross-arch config parses" FAIL "mkosi summary failed; see $CHECK_DIR/mkosi-summary.err"
    fi
    rm -rf "$CHECK_DIR/mkosi-probe"
    if [ -f "$PROJECT_ROOT/out/env-smoke/mkosi-smoke/mkosi.conf" ]; then
        row mkosi "smoke config out/env-smoke/mkosi-smoke" PASS "sudo -n mkosi -f build (from that directory)"
    else
        row mkosi "smoke config out/env-smoke/mkosi-smoke" SKIP "smoke config not created yet"
    fi
    MKOSI_OUT="$PROJECT_ROOT/out/env-smoke/mkosi-smoke/out/image"
    if [ -f "$MKOSI_OUT/usr/bin/bash" ] && [ -d "$MKOSI_OUT/etc" ]; then
        MKOSI_SIZE="$(du -sh "$MKOSI_OUT" 2>/dev/null | cut -f1)"
        if "$(have file && echo file || echo true)" "$MKOSI_OUT/usr/bin/bash" 2>/dev/null | grep -q 'ARM aarch64'; then
            row mkosi "arm64 rootfs artifact" PASS "out/env-smoke/mkosi-smoke/out/image (${MKOSI_SIZE:-?}, /usr/bin/bash is ARM aarch64)"
        else
            row mkosi "arm64 rootfs artifact" WARN "out/image exists but /usr/bin/bash is not ARM aarch64"
        fi
    else
        row mkosi "arm64 rootfs artifact" SKIP "not built yet: cd out/env-smoke/mkosi-smoke && sudo -n mkosi -f build"
    fi
else
    row mkosi "cross-arch config parses" SKIP "mkosi not installed"
fi

# ---------------------------------------------------------------------------
# 6. Kernel cross-compile readiness + project source tree
# ---------------------------------------------------------------------------
KERNEL_DIR="$PROJECT_ROOT/upstream/linux-sm8450-liuqin"
if [ -d "$KERNEL_DIR/.git" ] && [ -f "$KERNEL_DIR/Makefile" ]; then
    KVER="$(sed -n 's/^VERSION = //p;' "$KERNEL_DIR/Makefile")"
    KPATCH="$(sed -n 's/^PATCHLEVEL = //p;' "$KERNEL_DIR/Makefile")"
    KHEAD="$(git -C "$KERNEL_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
    KBRANCH="$(git -C "$KERNEL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    row kernel "upstream kernel source" PASS "Linux ${KVER}.${KPATCH} $KBRANCH @ $KHEAD"
    if git -C "$KERNEL_DIR" status --porcelain 2>/dev/null | grep -q .; then
        row kernel "upstream tree clean (read-only rule)" WARN "working tree has local changes; upstream/ must stay unmodified"
    else
        row kernel "upstream tree clean (read-only rule)" PASS
    fi
else
    row kernel "upstream kernel source" FAIL "missing $KERNEL_DIR (run scripts/fetch-upstream.sh)"
fi

# kbuild rejects spaces in paths (Makefile:213). A space-free bind mount is the
# supported workaround on this host.
if [[ "$PROJECT_ROOT" == *' '* ]]; then
    if mountpoint -q "$SPACE_MOUNT" 2>/dev/null; then
        row kernel "space-free build path" PASS "bind mount $SPACE_MOUNT -> $PROJECT_ROOT"
    elif [ "$FIX" = 1 ] && sudo -n mkdir -p "$SPACE_MOUNT" && sudo -n mount --bind "$PROJECT_ROOT" "$SPACE_MOUNT"; then
        say_fix "bind-mounted $PROJECT_ROOT -> $SPACE_MOUNT"
        row kernel "space-free build path" PASS "bind mount $SPACE_MOUNT created"
    else
        row kernel "space-free build path" FAIL "project path contains a space; kbuild fails at Makefile:213. Run --fix to create $SPACE_MOUNT bind mount"
    fi
else
    row kernel "space-free build path" PASS "project path has no spaces"
fi

if [ -f "$PROJECT_ROOT/out/env-smoke/run-kernel-smoke.sh" ]; then
    row kernel "kernel smoke script" PASS "out/env-smoke/run-kernel-smoke.sh (Image + liuqin DTB)"
fi
KSMOKE="$PROJECT_ROOT/out/env-smoke/kbuild-liuqin"
if [ -f "$KSMOKE/arch/arm64/boot/Image" ] && [ -f "$KSMOKE/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb" ]; then
    IMG_SHA="$(sha256sum "$KSMOKE/arch/arm64/boot/Image" 2>/dev/null | cut -c1-12)"
    DTB_SHA="$(sha256sum "$KSMOKE/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb" 2>/dev/null | cut -c1-12)"
    row kernel "smoke Image + liuqin DTB" PASS "Image sha256:${IMG_SHA}... dtb sha256:${DTB_SHA}..."
else
    row kernel "smoke Image + liuqin DTB" SKIP "not built yet: out/env-smoke/run-kernel-smoke.sh"
fi
if [ -f "$KERNEL_DIR/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dts" ]; then
    row kernel "liuqin device tree sources" PASS "arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dts"
else
    row kernel "liuqin device tree sources" WARN "sm8475-xiaomi-liuqin.dts not found in the pinned branch"
fi

# ---------------------------------------------------------------------------
# 7. Network / proxy (informational; builds run through 127.0.0.1:7890)
# ---------------------------------------------------------------------------
if [ -n "${http_proxy:-}${HTTP_PROXY:-}" ]; then
    row net "HTTP proxy exported" PASS "${http_proxy:-${HTTP_PROXY:-}} (also inherited by sudo)"
else
    row net "HTTP proxy exported" WARN "no http_proxy; package downloads may fail behind the proxy"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [ "$QUIET" = 0 ]; then
    printf '\n%-10s %-34s %-5s %s\n' CATEGORY CHECK STATUS DETAIL
    printf '%s\n' '-----------------------------------------------------------------------------------------------'
    for r in "${ROWS[@]}"; do
        IFS='|' read -r c ch s d <<< "$r"
        printf '%-10s %-34s %-5s %s\n' "$c" "$ch" "$s" "$d"
    done
    printf '%s\n' '-----------------------------------------------------------------------------------------------'
else
    for r in "${ROWS[@]}"; do
        IFS='|' read -r c ch s d <<< "$r"
        [ "$s" = FAIL ] && printf 'FAIL %-34s %s\n' "$ch" "$d"
    done
fi
printf 'SUMMARY: %d PASS, %d WARN, %d FAIL, %d SKIP\n' "$PASS" "$WARN" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf 'RESULT: FAIL - %d blocking issue(s); see rows above (try --fix for binfmt/mount issues)\n' "$FAIL"
    exit 1
fi
printf 'RESULT: OK - minimal build environment is usable (warnings above are non-blocking)\n'
