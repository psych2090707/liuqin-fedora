#!/usr/bin/env bash
# ============================================================================
# build-rootfs.sh — liuqin (Xiaomi Pad 6 Pro) Fedora ARM64 desktop rootfs builder
#
# Wraps rootful cross-arch mkosi (x86_64 host -> aarch64 target), then validates
# the produced directory tree and emits reproducibility artifacts.  The default
# is Fedora Workstation / GNOME (Fedora 45); the historical KDE Plasma profile
# remains available with --profile plasma.
#
#   out/rootfs/rootfs/                 mkosi directory image (the rootfs tree)
#   out/rootfs/rootfs.manifest         machine-readable manifest (JSON)
#   out/rootfs/rootfs.packages.txt     `rpm -qa` plain text list
#   out/rootfs/rootfs.files.sha256     `<sha256>  </abs/path>` file digests
#   out/rootfs/rootfs.symlinks.txt     `/abs/path -> target` symlink table
#   out/rootfs/build-info.json         reproducible-build metadata (JSON)
#   out/rootfs/validation/             verification log + machine summary
#   out/rootfs/logs/                   mkosi build log + resolved mkosi summary
#
# Docs: mkosi/README.md. Device layer injection (kernel-liuqin,
# liuqin-firmware, ...) is documented in overlays/rootfs/README.md and is NOT
# part of this build.
#
# Usage:
#   scripts/build-rootfs.sh                     # build Fedora 45 + GNOME + verify
#   scripts/build-rootfs.sh --profile plasma    # retained KDE Plasma profile
#   scripts/build-rootfs.sh --skip-build        # re-run validation/manifests only
#   scripts/build-rootfs.sh --profile tty       # minimal rootfs, no desktop
#   scripts/build-rootfs.sh --help
#
# Must run as root (it re-executes itself through sudo -n when started as a
# regular user). Root is required for mkosi and for the offline chroot checks.
# ============================================================================

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MKOSI_DIR="$PROJECT_ROOT/mkosi"
OUT_DIR="$PROJECT_ROOT/out/rootfs"
ROOTFS_DIR="$OUT_DIR/rootfs"
LOG_DIR="$OUT_DIR/logs"
VALIDATION_DIR="$OUT_DIR/validation"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

RELEASE=45
PROFILE=gnome
DEV_USER="${LIUQIN_DEV_USER:-user}"
SKIP_BUILD=0
CLEAN=0
FILE_DIGESTS=1
LOCAL_MIRROR=""
MIRROR=""
JOBS="$(nproc)"
declare -a PACKAGE_DIRS=()
declare -a EXTRA_TREES=()
declare -a EXTRA_PACKAGES=()
declare -a MKOSI_ARGS=()

usage() {
    cat <<'EOF'
build-rootfs.sh — liuqin Fedora ARM64 KDE rootfs builder (rootful cross-arch mkosi)

Usage: scripts/build-rootfs.sh [options]

  --release, -r N     Fedora release (default: 45)
  --profile, -p P     mkosi profile (default: gnome; 'plasma' = historical KDE;
                      'tty' = no desktop)
  --out, -o DIR       output base directory (default: out/rootfs)
  --jobs, -j N        parallelism for host-side hashing/ELF scans (mkosi 27 has
                      no job control; the qemu-user package install is serial)
  --skip-build        reuse out/rootfs/rootfs, only validate + emit artifacts
  --verify-only       alias for --skip-build
  --clean             wipe mkosi incremental cache + tools tree before building
  --local-mirror URL  mkosi LocalMirror= (single flat repo). For Fedora 45
                      pre-GA: https://dl.fedoraproject.org/pub/fedora/linux/development/45/Everything/$basearch/os
  --mirror URL        mkosi Mirror= (mirror root, e.g. http://127.0.0.1:PORT/fedora/linux)
  --no-file-digests   skip rootfs.files.sha256 (large tree hash pass)
  --package-dir DIR   extra local RPM repo dir (device layer, repeatable)
  --extra-tree S[:D]  extra overlay tree for mkosi (device layer, repeatable)
  --extra-package P   extra package to install (repeatable)
  -h, --help          this help

Artifacts: out/rootfs/{rootfs/,rootfs.manifest,rootfs.packages.txt,
           rootfs.files.sha256,build-info.json,validation/,logs/}
Docs: mkosi/README.md   Device layer: overlays/rootfs/README.md
EOF
    exit 0
}

log()  { printf '\033[1;34m[build-rootfs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build-rootfs] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build-rootfs] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments --
ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --release|-r)     RELEASE="${2:?--release needs a value}"; shift 2 ;;
        --profile|-p)     PROFILE="${2:?--profile needs a value}"; shift 2 ;;
        --out|-o)         OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
        --jobs|-j)        JOBS="${2:?--jobs needs a value}"; shift 2 ;;
        --skip-build)     SKIP_BUILD=1; shift ;;
        --verify-only)    SKIP_BUILD=1; shift ;;
        --clean)          CLEAN=1; shift ;;
        --local-mirror)   LOCAL_MIRROR="${2:?--local-mirror needs a URL}"; shift 2 ;;
        --mirror)         MIRROR="${2:?--mirror needs a URL}"; shift 2 ;;
        --no-file-digests) FILE_DIGESTS=0; shift ;;
        --package-dir)    PACKAGE_DIRS+=("${2:?--package-dir needs a value}"); shift 2 ;;
        --extra-tree)     EXTRA_TREES+=("${2:?--extra-tree needs a value}"); shift 2 ;;
        --extra-package)  EXTRA_PACKAGES+=("${2:?--extra-package needs a value}"); shift 2 ;;
        -h|--help)        usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

case "$OUT_DIR" in
    /*) ;;
    *)  OUT_DIR="$PROJECT_ROOT/$OUT_DIR" ;;
esac
ROOTFS_DIR="$OUT_DIR/rootfs"
LOG_DIR="$OUT_DIR/logs"
VALIDATION_DIR="$OUT_DIR/validation"
[[ "$JOBS" =~ ^[0-9]+$ ]] || die "--jobs must be a number"
case "$PROFILE" in
    plasma) DESKTOP=plasma ;;
    gnome|tty|none) DESKTOP=gnome ;;
    *) DESKTOP=gnome ;;
esac

# ------------------------------------------------------------- root check ---
if [ "$(id -u)" -ne 0 ]; then
    log "re-executing through sudo -n (rootful mkosi + offline chroot checks)"
    exec sudo -n -- "$SCRIPT_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || die "sudo failed; run as root instead"
fi

mkdir -p "$LOG_DIR" "$VALIDATION_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="$LOG_DIR/build-$STAMP.log"
VERIFY_LOG="$VALIDATION_DIR/verify-$STAMP.log"
SUMMARY_JSON="$VALIDATION_DIR/verify-summary.json"
CHECKS_TSV="$VALIDATION_DIR/checks-$STAMP.tsv"
: > "$CHECKS_TSV"
: > "$VERIFY_LOG"

# When only re-validating (--skip-build), keep pointing build-info.json at the
# original build run instead of the verification timestamp.
BUILD_STAMP="$STAMP"
if [ "$SKIP_BUILD" -eq 1 ]; then
    latest_start="$(ls -t "$LOG_DIR"/build-start-*.epoch 2>/dev/null | head -1 || true)"
    if [ -n "$latest_start" ]; then
        BUILD_STAMP="$(basename "$latest_start" .epoch | sed 's/^build-start-//')"
    fi
fi

# ---------- check bookkeeping (PASS / WARN / FAIL, machine-readable) --------
check() { # check <id> <PASS|WARN|FAIL> <detail>
    local id="$1" status="$2"; shift 2
    local detail="$*"
    local line
    line="$(printf '%-34s %-4s %s' "$id" "$status" "$detail")"
    printf '%s\n' "$line" | tee -a "$VERIFY_LOG"
    printf '%s\t%s\t%s\n' "$id" "$status" "$detail" >> "$CHECKS_TSV"
}
ok()   { check "$1" PASS "${2:-}"; }
warnc(){ check "$1" WARN "${2:-}"; }
bad()  { check "$1" FAIL "${2:-}"; }

# Run a command inside the target rootfs (aarch64 ELF via binfmt/qemu-user).
chroot_run() {
    chroot "$ROOTFS_DIR" "$@"
}

# ------------------------------------------------------------------ build ---
build_rootfs() {
    command -v mkosi >/dev/null || die "mkosi not found on the host"
    local mkosi_version
    mkosi_version="$(mkosi --version)"

    log "mkosi: $mkosi_version"
    log "target: Fedora $RELEASE / $PROFILE / arm64 (directory image, Bootable=no)"

    MKOSI_ARGS=(
        --directory "$MKOSI_DIR"
        --release "$RELEASE"
        --output-dir "$OUT_DIR"
        --output rootfs
    )
    [ "$PROFILE" != "none" ] && [ "$PROFILE" != "tty" ] && MKOSI_ARGS+=(--profile "$PROFILE")

    local d
    for d in ${PACKAGE_DIRS[@]+"${PACKAGE_DIRS[@]}"}; do
        [[ -d "$d" ]] || die "--package-dir does not exist: $d"
        MKOSI_ARGS+=(--package-directory "$(readlink -f "$d")")
    done
    local t
    for t in ${EXTRA_TREES[@]+"${EXTRA_TREES[@]}"}; do
        MKOSI_ARGS+=(--extra-tree "$t")
    done
    local p
    for p in ${EXTRA_PACKAGES[@]+"${EXTRA_PACKAGES[@]}"}; do
        MKOSI_ARGS+=(--package "$p")
    done

    # Resolved configuration snapshot (for reproducible-build records).
    local -a summary_args=(--directory "$MKOSI_DIR" --release "$RELEASE" summary)
    if [ "$PROFILE" != "none" ] && [ "$PROFILE" != "tty" ]; then
        summary_args=(--directory "$MKOSI_DIR" --release "$RELEASE" --profile "$PROFILE" summary)
    fi
    # Mirror overrides also affect the resolved-config snapshot
    if [ -n "$LOCAL_MIRROR" ] || [ -n "$MIRROR" ]; then
        local -a with_mirror=("${summary_args[@]}")
        unset "with_mirror[$(( ${#with_mirror[@]} - 1 ))]"
        [ -n "$LOCAL_MIRROR" ] && with_mirror+=(--local-mirror "$LOCAL_MIRROR")
        [ -n "$MIRROR" ] && with_mirror+=(--mirror "$MIRROR")
        with_mirror+=(summary)
        summary_args=("${with_mirror[@]}")
    fi
    if mkosi "${summary_args[@]}" >"$LOG_DIR/mkosi-summary-$STAMP.txt" 2>&1; then
        log "resolved config: out/rootfs/logs/mkosi-summary-$STAMP.txt"
    else
        warn "mkosi summary failed (details in logs), continuing with the build"
    fi

    if [ "$CLEAN" -eq 1 ]; then
        log "cleaning mkosi caches and cached output (--clean)"
        mkosi --directory "$MKOSI_DIR" clean -f >>"$LOG_DIR/clean-$STAMP.log" 2>&1 || true
    fi

    local build_start build_end build_rc
    build_start="$(date +%s)"
    log "starting mkosi build; log: ${BUILD_LOG#$PROJECT_ROOT/}"
    set +e
    mkosi "${MKOSI_ARGS[@]}" --force --debug-timing build 2>&1 | tee "$BUILD_LOG"
    build_rc=${PIPESTATUS[0]}
    set -e
    build_end="$(date +%s)"
    printf '%s\n' "$build_start" > "$LOG_DIR/build-start-$STAMP.epoch"
    printf '%s\n' "$build_end"   > "$LOG_DIR/build-end-$STAMP.epoch"
    printf '%s\n' "$build_rc"    > "$LOG_DIR/build-rc-$STAMP.txt"

    if [ "$build_rc" -ne 0 ]; then
        die "mkosi build failed (rc=$build_rc); see ${BUILD_LOG#$PROJECT_ROOT/}"
    fi
    log "mkosi build finished in $((build_end - build_start))s"
}

# ------------------------------------------------------------- verification --
# Helper mounts are tracked globally so the EXIT trap can still unmount them if
# verification aborts (a `local` would be out of scope by then, see set -u bug).
HELPER_MOUNTS=0
umount_helpers() {
    [ "$HELPER_MOUNTS" -eq 1 ] || return 0
    local m
    for m in sys proc dev; do
        umount "$ROOTFS_DIR/$m" 2>/dev/null || true
    done
    HELPER_MOUNTS=0
}
mount_helpers() {
    mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"
    # aarch64 binaries run through qemu-user binfmt while we are chrooted.
    # Unmount stale helper mounts first so repeated runs cannot stack them.
    local m
    for m in dev proc sys; do
        mountpoint -q "$ROOTFS_DIR/$m" 2>/dev/null && umount "$ROOTFS_DIR/$m" 2>/dev/null || true
    done
    mount --bind /dev  "$ROOTFS_DIR/dev"  2>/dev/null || true
    mount --bind /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
    mount --bind /sys  "$ROOTFS_DIR/sys"  2>/dev/null || true
    HELPER_MOUNTS=1
}

# Remove helper mounts before any tree walk (artifacts must never include /proc).
unmount_all_helpers() {
    local m
    for m in sys proc dev; do
        mountpoint -q "$ROOTFS_DIR/$m" 2>/dev/null && umount "$ROOTFS_DIR/$m" 2>/dev/null || true
    done
    HELPER_MOUNTS=0
}

verify_rootfs() {
    log "verifying $ROOTFS_DIR"

    # --- tree sanity + size (before /proc,/sys,/dev are bind-mounted) -------
    if [[ ! -x "$ROOTFS_DIR/usr/bin/bash" ]]; then
        bad rootfs.exists "missing $ROOTFS_DIR/usr/bin/bash"; return 0
    fi
    local size_h size_b files
    size_h="$(du -sh "$ROOTFS_DIR" 2>/dev/null | cut -f1)"
    size_b="$(du -sb "$ROOTFS_DIR" 2>/dev/null | cut -f1)"
    files="$(find "$ROOTFS_DIR" -type f 2>/dev/null | wc -l)"
    ok rootfs.exists "tree present ($size_h, $files files)"
    ok rootfs.size "$size_h ($size_b bytes), $files files"

    mount_helpers
    trap umount_helpers EXIT

    # --- OS identity ---------------------------------------------------------
    local os_id os_ver os_name
    os_id="$(sed -n 's/^ID=//p'   "$ROOTFS_DIR/usr/lib/os-release" 2>/dev/null | head -1 | tr -d '"')"
    os_ver="$(sed -n 's/^VERSION_ID=//p' "$ROOTFS_DIR/usr/lib/os-release" 2>/dev/null | head -1 | tr -d '"')"
    os_name="$(sed -n 's/^PRETTY_NAME=//p' "$ROOTFS_DIR/usr/lib/os-release" 2>/dev/null | head -1 | tr -d '"')"
    if [ "$os_id" = "fedora" ] && [ "$os_ver" = "$RELEASE" ]; then
        ok os.release "$os_name"
    else
        bad os.release "expected fedora/$RELEASE, got id=${os_id:-?} version=${os_ver:-?}"
    fi

    local desktop_ver=""
    if [ "$DESKTOP" = plasma ]; then
        desktop_ver="$(chroot_run rpm -q --qf '%{VERSION}-%{RELEASE}' plasma-workspace 2>/dev/null | head -1 || true)"
        ok plasma.version "${desktop_ver:-unknown}"
    else
        desktop_ver="$(chroot_run rpm -q --qf '%{VERSION}-%{RELEASE}' gnome-shell 2>/dev/null | head -1 || true)"
        ok gnome.version "${desktop_ver:-unknown}"
    fi

    # --- architecture --------------------------------------------------------
    local sample="/usr/bin/bash /usr/lib64/ld-linux-aarch64.so.1"
    if [ "$DESKTOP" = plasma ]; then
        sample="$sample /usr/bin/plasmashell"
    else
        sample="$sample /usr/bin/gnome-shell"
    fi
    local f bad_arch=0
    for f in $sample; do
        if [ -e "$ROOTFS_DIR$f" ]; then
            if file -bL "$ROOTFS_DIR$f" 2>/dev/null | grep -q 'ARM aarch64'; then
                ok "arch.elf-sample.$(basename "$f")" "ARM aarch64"
            else
                bad "arch.elf-sample.$(basename "$f")" "$(file -bL "$ROOTFS_DIR$f" 2>/dev/null | cut -c1-60)"
                bad_arch=1
            fi
        fi
    done
    [ "$bad_arch" -eq 0 ] && ok arch.loader "aarch64 binfmt loader/ELF samples ok"

    # every executable ELF in the tree must be aarch64 (no x86_64 strays)
    local x86_hits
    x86_hits="$(find "$ROOTFS_DIR" -type f -perm -u+x -print0 2>/dev/null \
        | xargs -0 -r -P "$JOBS" -n 64 file 2>/dev/null \
        | grep -E 'ELF .*x86-64' | head -5 || true)"
    if [ -n "$x86_hits" ]; then
        bad arch.no-x86_64 "$(printf '%s' "$x86_hits" | head -2 | tr '\n' ' ')"
    else
        ok arch.no-x86_64 "no x86-64 ELF executables found"
    fi

    # package architecture set (rpm db, not heuristics)
    local arch_set
    arch_set="$(chroot_run rpm -qa --qf '%{ARCH}\n' 2>/dev/null | sort -u | tr '\n' ' ' || true)"
    if printf '%s' "$arch_set" | grep -q 'x86_64'; then
        bad arch.rpm-x86_64 "rpm db contains x86_64 packages: $arch_set"
    else
        ok arch.rpm "$arch_set"
    fi

    # cross-arch ELF must actually execute (binfmt/qemu-user)
    if chroot_run /usr/bin/bash -c 'exit 0' >/dev/null 2>&1; then
        ok arch.binfmt "aarch64 userspace executes under qemu-user binfmt"
    else
        bad arch.binfmt "aarch64 /usr/bin/bash did not execute in chroot"
    fi

    # --- no Fedora kernel / initramfs (device layer injects kernel-liuqin) ---
    if compgen -G "$ROOTFS_DIR/usr/lib/modules/*" >/dev/null 2>&1; then
        bad kernel.absent "rootfs contains /usr/lib/modules (device layer must provide kernel-liuqin)"
    else
        ok kernel.absent "no kernel/modules in rootfs (injected later with device layer)"
    fi

    # --- required packages ---------------------------------------------------
    local required=()
    if [ "$DESKTOP" = plasma ]; then
        required=(dnf5 dnf5-plugins NetworkManager plasma-desktop plasma-workspace kwin kscreen
                  powerdevil plasma-nm plasma-pa bluedevil upower
                  xdg-desktop-portal-kde pipewire wireplumber iio-sensor-proxy
                  fprintd libfprint firefox kscreenlocker snapshot libcamera libcamera-ipa
                  libcamera-tools libcamera-gstreamer v4l-utils ffmpeg-free
                  gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugin-openh264)
    else
        required=(dnf5 dnf5-plugins NetworkManager gnome-shell gnome-session
                  gnome-session-wayland-session gnome-control-center gnome-settings-daemon
                  gnome-keyring gnome-keyring-pam gdm nautilus gnome-software
                  xdg-desktop-portal-gnome pipewire wireplumber iio-sensor-proxy
                  fprintd libfprint firefox libcamera libcamera-ipa
                  libcamera-tools libcamera-gstreamer v4l-utils ffmpeg-free
                  gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugin-openh264)
    fi
    local missing_req=()
    local pkg
    for pkg in "${required[@]}"; do
        chroot_run rpm -q "$pkg" >/dev/null 2>&1 || missing_req+=("$pkg")
    done
    if [ "${#missing_req[@]}" -eq 0 ]; then
        ok packages.required "all ${#required[@]} tablet-critical packages installed"
    else
        bad packages.required "missing: ${missing_req[*]}"
    fi

    # on-screen keyboard: KDE ships a choice; GNOME has the built-in OSK and the
    # local layout extension is injected at image assembly time.
    if [ "$DESKTOP" = plasma ]; then
        local osk_present=()
        for pkg in plasma-keyboard maliit-keyboard; do
            chroot_run rpm -q "$pkg" >/dev/null 2>&1 && osk_present+=("$pkg")
        done
        if [ "${#osk_present[@]}" -ge 1 ]; then
            ok packages.osk "${osk_present[*]}"
        else
            bad packages.osk "neither plasma-keyboard nor maliit-keyboard installed"
        fi
    else
        if chroot_run /usr/bin/gnome-shell --version >/dev/null 2>&1; then
            ok packages.osk "GNOME Shell built-in OSK"
        else
            bad packages.osk "gnome-shell missing"
        fi
    fi

    # --- login manager + desktop session ------------------------------------
    local lm="" lm_unit=""
    if [ "$DESKTOP" = gnome ] && [ -f "$ROOTFS_DIR/usr/lib/systemd/system/gdm.service" ]; then
        lm="gdm"; lm_unit="gdm.service"
    elif [ -f "$ROOTFS_DIR/usr/lib/systemd/system/plasmalogin.service" ]; then
        lm="plasmalogin"; lm_unit="plasmalogin.service"
    elif [ -f "$ROOTFS_DIR/usr/lib/systemd/system/sddm.service" ]; then
        lm="sddm"; lm_unit="sddm.service"
    fi
    if [ -n "$lm" ]; then
        local dm_link dm_target
        dm_link="$ROOTFS_DIR/etc/systemd/system/display-manager.service"
        # display-manager.service is the systemd alias initramfs/boot contracts
        # pin: record the literal link target for the boot-builder contract.
        if [ -L "$dm_link" ]; then
            dm_target="$(readlink "$dm_link")"
            case "$dm_target" in
                *"$lm_unit"*) ok login.manager "$lm; display-manager.service -> $dm_target" ;;
                *) warnc login.manager "display-manager.service -> $dm_target (expected *$lm_unit)" ;;
            esac
        else
            warnc login.manager "$lm installed but /etc/systemd/system/display-manager.service alias missing"
        fi
        # Display managers are enabled via the display-manager.service alias
        # (graphical.target has Wants=display-manager.service); some units also
        # get a *.wants symlink -- accept either as the "enabled" proof.
        if [ -L "$dm_link" ] ||
           [ -L "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$lm_unit" ] ||
           [ -L "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants/$lm_unit" ]; then
            ok login.enabled "$lm_unit enabled (display-manager.service alias)"
        else
            bad login.enabled "$lm_unit not enabled"
        fi
        if [ "$lm" = plasmalogin ] && chroot_run rpm -q plasma-login-manager >/dev/null 2>&1; then
            ok login.plasmalogin-pkg "$(chroot_run rpm -q --qf '%{VERSION}-%{RELEASE}' plasma-login-manager 2>/dev/null | head -1)"
        elif [ "$lm" = gdm ] && chroot_run rpm -q gdm >/dev/null 2>&1; then
            ok login.gdm-pkg "$(chroot_run rpm -q --qf '%{VERSION}-%{RELEASE}' gdm 2>/dev/null | head -1)"
        fi
    else
        bad login.manager "no gdm.service, plasmalogin.service or sddm.service in rootfs"
    fi

    if [ "$DESKTOP" = plasma ]; then
        if [ -f "$ROOTFS_DIR/usr/share/wayland-sessions/plasma.desktop" ] && \
           [ -x "$ROOTFS_DIR/usr/bin/plasmashell" ] && [ -x "$ROOTFS_DIR/usr/bin/kwin_wayland" ]; then
            ok desktop.session "plasma.desktop + plasmashell + kwin_wayland present"
        else
            bad desktop.session "KDE Plasma Wayland session incomplete"
        fi
    else
        if [ -f "$ROOTFS_DIR/usr/share/wayland-sessions/gnome.desktop" ] && \
           [ -x "$ROOTFS_DIR/usr/bin/gnome-shell" ] && [ -x "$ROOTFS_DIR/usr/bin/gnome-session" ]; then
            ok desktop.session "gnome.desktop + gnome-shell + gnome-session present"
        else
            bad desktop.session "GNOME Wayland session incomplete"
        fi
    fi

    # --- services / default target ------------------------------------------
    # A unit is "enabled" if it is wanted by any *.wants/ dir of the target
    # graph (units may hang off graphical/bluetooth/sysinit/timers, not only
    # multi-user.target).
    unit_enabled() {
        local unit="$1" d
        for d in "$ROOTFS_DIR"/etc/systemd/system/*.wants; do
            [ -L "$d/$unit" ] && return 0
        done
        return 1
    }
    local unit units_ok=() units_missing=()
    for unit in NetworkManager.service systemd-resolved.service bluetooth.service \
                chronyd.service sshd.service; do
        if unit_enabled "$unit"; then units_ok+=("$unit"); else units_missing+=("$unit"); fi
    done
    local default_target=""
    if [ -L "$ROOTFS_DIR/etc/systemd/system/default.target" ]; then
        default_target="$(readlink "$ROOTFS_DIR/etc/systemd/system/default.target")"
    fi
    if [[ "$default_target" == *graphical.target ]]; then
        units_ok+=("graphical.target($default_target)")
    else
        units_missing+=("graphical.target(link=${default_target:-missing})")
    fi
    # fstrim.timer (flash longevity) is expected too
    if unit_enabled fstrim.timer; then units_ok+=("fstrim.timer"); else units_missing+=("fstrim.timer"); fi
    if [ "${#units_missing[@]}" -eq 0 ]; then
        ok services.enabled "${units_ok[*]}"
    else
        bad services.enabled "not enabled: ${units_missing[*]}"
    fi

    # --- no interactive systemd-firstboot on an unattended tablet -----------
    local firstboot_problems=()
    [ -L "$ROOTFS_DIR/etc/systemd/system/systemd-firstboot.service" ] &&
        [ "$(readlink "$ROOTFS_DIR/etc/systemd/system/systemd-firstboot.service")" = "/dev/null" ] || \
        firstboot_problems+=("not masked in /etc/systemd/system")
    [ -e "$ROOTFS_DIR/usr/lib/systemd/system/sysinit.target.wants/systemd-firstboot.service" ] && \
        firstboot_problems+=("enabled in /usr/lib sysinit.target.wants")
    [ -e "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants/systemd-firstboot.service" ] && \
        firstboot_problems+=("enabled in /etc sysinit.target.wants")
    if [ "${#firstboot_problems[@]}" -eq 0 ]; then
        ok firstboot.disabled "systemd-firstboot masked, not in sysinit.target.wants (unattended boot)"
    else
        bad firstboot.disabled "${firstboot_problems[*]}"
    fi

    # --- PAM logind integration (systemd-pam split package) -----------------
    if [ -f "$ROOTFS_DIR/usr/lib64/security/pam_systemd.so" ] ||
       [ -f "$ROOTFS_DIR/usr/lib/security/pam_systemd.so" ]; then
        ok pam.systemd "$(chroot_run rpm -q --qf '%{VERSION}-%{RELEASE}' systemd-pam 2>/dev/null | head -1) installed (pam_systemd.so present)"
    else
        bad pam.systemd "pam_systemd.so missing: install systemd-pam (login sessions/logind integration)"
    fi
    if chroot_run rpm -q systemd-pam >/dev/null 2>&1; then
        ok package.systemd-pam "systemd-pam installed"
    else
        bad package.systemd-pam "systemd-pam package missing"
    fi
    if compgen -G "$ROOTFS_DIR/usr/lib*/security/pam_fprintd.so" >/dev/null 2>&1; then
        ok pam.fprintd "pam_fprintd.so present (fprintd-pam)"
    else
        warnc pam.fprintd "pam_fprintd.so missing (fingerprint PAM integration unavailable)"
    fi

    # --- release-baseline package-set assertions (v2) -----------------------
    if chroot_run rpm -q qbootctl >/dev/null 2>&1; then
        bad package.qbootctl-absent "qbootctl is installed; boot updates must only go through liuqin-apply-boot"
    else
        ok package.qbootctl-absent "qbootctl not installed (boot updates only via liuqin-apply-boot)"
    fi
    local qmi_missing=()
    local qmi_pkg
    for qmi_pkg in libqmi libqrtr-glib; do
        chroot_run rpm -q "$qmi_pkg" >/dev/null 2>&1 || qmi_missing+=("$qmi_pkg")
    done
    if [ "${#qmi_missing[@]}" -eq 0 ]; then
        ok package.libssc-deps "libqmi + libqrtr-glib installed (libssc runtime deps)"
    else
        bad package.libssc-deps "missing libssc runtime deps: ${qmi_missing[*]}"
    fi

    # --- image hygiene: no /usr/local leftovers, no GNOME residue -----------
    # /usr/local must not contain files that no RPM owns (leftover from chroot
    # tooling/agent activity). Package-owned files and the empty Fedora default
    # directories are fine.
    local local_orphans=() local_file
    while IFS= read -r local_file; do
        [ -n "$local_file" ] || continue
        chroot_run rpm -qf "${local_file#"$ROOTFS_DIR"}" >/dev/null 2>&1 || local_orphans+=("${local_file#"$ROOTFS_DIR"}")
    done < <(find "$ROOTFS_DIR/usr/local" -type f 2>/dev/null)
    if [ "${#local_orphans[@]}" -eq 0 ]; then
        ok clean.usr-local "no RPM-unowned files under /usr/local"
    else
        warnc clean.usr-local "RPM-unowned files under /usr/local: ${local_orphans[*]:0:3}"
    fi
    if [ "$DESKTOP" = plasma ]; then
        if chroot_run rpm -q gnome-shell gdm mutter >/dev/null 2>&1; then
            bad clean.no-gnome "GNOME desktop stack installed (rootfs must be KDE-only)"
        else
            ok clean.no-gnome "no GNOME desktop stack (gnome-shell/gdm/mutter absent)"
        fi
    else
        if chroot_run rpm -q gnome-shell gdm mutter >/dev/null 2>&1; then
            ok clean.gnome "GNOME desktop stack present (gnome-shell/gdm/mutter)"
        else
            bad clean.gnome "GNOME desktop stack incomplete"
        fi
        if chroot_run rpm -q plasma-desktop >/dev/null 2>&1; then
            bad clean.no-kde "KDE Plasma installed in a GNOME image"
        else
            ok clean.no-kde "no KDE Plasma desktop in the GNOME image"
        fi
    fi

    # --- locale is really UTF-8 inside the image ----------------------------
    local locale_conf locale_charmap
    locale_conf="$(grep -E '^LANG=' "$ROOTFS_DIR/etc/locale.conf" 2>/dev/null | head -1 || true)"
    locale_charmap="$(chroot_run /usr/bin/env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 /usr/bin/locale charmap 2>/dev/null || true)"
    if printf '%s' "$locale_conf" | grep -q 'en_US.UTF-8' && [ "$locale_charmap" = "UTF-8" ]; then
        ok locale.utf8 "locale.conf LANG=en_US.UTF-8, runtime charmap=UTF-8"
    elif [ "$locale_charmap" = "UTF-8" ]; then
        warnc locale.utf8 "runtime charmap=UTF-8 but locale.conf is '${locale_conf:-missing}'"
    else
        bad locale.utf8 "locale.conf='${locale_conf:-missing}', runtime charmap='${locale_charmap:-unknown}'"
    fi

    # --- dev user ------------------------------------------------------------
    local user_line groups
    user_line="$(grep "^$DEV_USER:" "$ROOTFS_DIR/etc/passwd" 2>/dev/null || true)"
    groups="$(chroot_run id -nG "$DEV_USER" 2>/dev/null || true)"
    if [ -n "$user_line" ] && printf '%s' "$groups" | grep -qw wheel; then
        ok user.dev "$(printf '%s' "$user_line" | cut -d: -f1,3,7) groups=[$groups]"
    else
        bad user.dev "development user '$DEV_USER' missing or not in wheel"
    fi
    local user_pw
    user_pw="$(grep "^$DEV_USER:" "$ROOTFS_DIR/etc/shadow" 2>/dev/null | cut -d: -f2 || true)"
    if [ -n "$user_pw" ] && [ "$user_pw" != '!!' ] && [ "$user_pw" != '*' ]; then
        ok user.password "development password set (dev image only)"
    else
        bad user.password "development user has no password"
    fi
    if grep -Eq '^[[:space:]]*%wheel[[:space:]]+ALL' "$ROOTFS_DIR/etc/sudoers" \
       || grep -rqE '^[[:space:]]*%wheel[[:space:]]+ALL' "$ROOTFS_DIR/etc/sudoers.d" 2>/dev/null; then
        ok sudo.wheel "wheel group may sudo"
    else
        bad sudo.wheel "no active %wheel sudo rule"
    fi

    # --- filesystem contract (installer labels) ------------------------------
    if grep -q 'LABEL=LIUQIN_ROOT' "$ROOTFS_DIR/etc/fstab" && \
       grep -q 'LABEL=LIUQIN_HOME' "$ROOTFS_DIR/etc/fstab"; then
        ok fstab.labels "LABEL=LIUQIN_ROOT + LABEL=LIUQIN_HOME"
    else
        bad fstab.labels "expected LIUQIN_ROOT/LIUQIN_HOME labels in /etc/fstab"
    fi
    if [ -f "$ROOTFS_DIR/etc/liuqin/image-contract" ]; then
        ok image.contract "$(grep -c . "$ROOTFS_DIR/etc/liuqin/image-contract") keys"
    else
        warnc image.contract "missing /etc/liuqin/image-contract"
    fi

    # --- tablet display config (user + greeter) ------------------------------
    if [ "$DESKTOP" = plasma ]; then
        local tablet_rc=0
        python3 - "$ROOTFS_DIR" <<'PY' >>"$VERIFY_LOG" 2>&1 || tablet_rc=$?
import json, sys, os
root = sys.argv[1]
p = os.path.join(root, "etc/skel/.config/kwinoutputconfig.json")
try:
    cfg = json.load(open(p))
    out = cfg[0]["data"][0]
    checks = {
        "connector": out.get("connectorName") == "DSI-1",
        "mode": out.get("mode") == {"width": 1800, "height": 2880, "refreshRate": 120000},
        "rotation": out.get("transform") == "Rotated270",
        "autorotate": out.get("autoRotation") == "InTabletMode",
        "scale": abs(float(out.get("scale", 0)) - 2.25) < 1e-9,
    }
    print("skel-kwinoutputconfig:", json.dumps(checks, sort_keys=True))
    sys.exit(0 if all(checks.values()) else 1)
except Exception as exc:
    print("skel-kwinoutputconfig: ERROR", exc)
    sys.exit(1)
PY
        if [ "$tablet_rc" -eq 0 ]; then
            ok tablet.skel-kwin "DSI-1 1800x2880@120 Rotated270 scale 2.25 autoRotation=InTabletMode"
        else
            bad tablet.skel-kwin "skel kwinoutputconfig.json mismatch (see verification log)"
        fi
    fi

    local monitors_rc=0
    python3 - "$ROOTFS_DIR/etc/skel/.config/monitors.xml" <<'PY' >>"$VERIFY_LOG" 2>&1 || monitors_rc=$?
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
m = t.find(".//monitor/mode")
rot = t.find(".//logicalmonitor/transform/rotation")
sys.exit(0 if m is not None and m.findtext("width") == "1800"
         and m.findtext("height") == "2880" and rot is not None and rot.text == "right" else 1)
PY
    if [ "$monitors_rc" -eq 0 ]; then
        ok tablet.skel-monitors "monitors.xml 1800x2880 rotation=right"
    else
        bad tablet.skel-monitors "monitors.xml mismatch"
    fi

    # greeter display config: KDE greeters use kwinoutputconfig.json, GDM uses
    # monitors.xml.  Both are prepared by mkosi.postinst/finalize.
    if [ "$DESKTOP" = plasma ]; then
        local greeter_hits=""
        greeter_hits="$(find "$ROOTFS_DIR/var/lib" -maxdepth 3 -path '*/.config/kwinoutputconfig.json' 2>/dev/null | head -3 | sed "s|$ROOTFS_DIR||" | tr '\n' ' ' || true)"
        if [ -n "$greeter_hits" ]; then
            ok tablet.greeter-conf "$greeter_hits"
        else
            warnc tablet.greeter-conf "no greeter kwinoutputconfig.json found under /var/lib"
        fi
    else
        if [ -f "$ROOTFS_DIR/etc/xdg/monitors.xml" ]; then
            ok tablet.greeter-conf "/etc/xdg/monitors.xml"
        else
            warnc tablet.greeter-conf "/etc/xdg/monitors.xml missing"
        fi
    fi

    # --- SELinux policy / image hygiene -------------------------------------
    # Decision (2026-10-20): first release permissive (kernel SELinux=y, policy
    # installed on next rebuild); enforcing only after device validation.
    # Existing pre-decision trees may still be disabled -- accept both, warn on
    # enforcing without device evidence.
    local selinux_mode=""
    selinux_mode="$(sed -n 's/^SELINUX=//p' "$ROOTFS_DIR/etc/selinux/config" 2>/dev/null | head -1 | tr -d '"')"
    case "$selinux_mode" in
        permissive) ok selinux.policy "SELINUX=permissive (bring-up; enforce after device validation + relabel)" ;;
        disabled)   warnc selinux.policy "SELINUX=disabled (pre-decision tree; release baseline v2 expects permissive)" ;;
        enforcing)  warnc selinux.policy "SELINUX=enforcing: only expected after device validation" ;;
        *)          warnc selinux.policy "unexpected /etc/selinux/config state: ${selinux_mode:-missing}" ;;
    esac
    if chroot_run rpm -q selinux-policy-targeted >/dev/null 2>&1; then
        ok package.selinux-policy "selinux-policy-targeted installed"
    else
        warnc package.selinux-policy "selinux-policy-targeted not installed (SELinux cannot be enforced)"
    fi
    local hygiene_bad=()
    compgen -G "$ROOTFS_DIR/etc/ssh/ssh_host_*" >/dev/null 2>&1 && hygiene_bad+=("ssh host keys")
    [ -e "$ROOTFS_DIR/var/lib/systemd/random-seed" ] && hygiene_bad+=("systemd random-seed")
    if [ "${#hygiene_bad[@]}" -eq 0 ]; then
        ok hygiene.machine-id "no ssh host keys / random seed baked in"
    else
        warnc hygiene.machine-id "machine-specific state present: ${hygiene_bad[*]}"
    fi

    # --- device-critical firmware coverage ----------------------------------
    # Fedora 44 split linux-firmware into per-driver packages and ships firmware
    # xz-compressed, so check both the provider packages and the on-disk paths.
    # Remaining device-specific blobs come from the user's own device (device
    # layer); see mkosi/README.md.
    local fw_ok=() fw_missing=() p
    for p in atheros-firmware cirrus-audio-firmware qcom-firmware; do
        if chroot_run rpm -q "$p" >/dev/null 2>&1; then fw_ok+=("$p"); else fw_missing+=("pkg:$p"); fi
    done
    local fw_paths=(
        "usr/lib/firmware/ath11k/WCN6855/hw2.0/amss.bin*"
        "usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin*"
        "usr/lib/firmware/qcom/a730_sqe.fw*"
        "usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot.wmfw*"
        "usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-*.wmfw*"
    )
    local fwglob hit
    for fwglob in "${fw_paths[@]}"; do
        hit="$(compgen -G "$ROOTFS_DIR/$fwglob" | head -1 || true)"
        if [ -n "$hit" ]; then fw_ok+=("$(basename "$hit")"); else fw_missing+=("file:$(basename "$fwglob")"); fi
    done
    if [ "${#fw_missing[@]}" -eq 0 ]; then
        ok firmware.device "WCN6855 WiFi/BT + cs35l41 speaker DSP + a730_sqe present (Fedora, xz)"
    else
        bad firmware.device "missing Fedora-shipped device firmware: ${fw_missing[*]}"
    fi
    local cs35l41_hit=""
    cs35l41_hit="$(compgen -G "$ROOTFS_DIR/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot*.wmfw*" | head -1 || true)"
    if [ -n "$cs35l41_hit" ]; then
        ok firmware.cs35l41 "$(basename "$cs35l41_hit") present (cirrus-audio-firmware)"
    else
        bad firmware.cs35l41 "cs35l41-dsp1-spk-prot*.wmfw missing (four-speaker protection DSP firmware)"
    fi

    # Upstream liuqin firmware-prep (sha256-pinned) needs blobs Fedora does not
    # ship: a730_zap.mbn / gmu_gen70000.bin / per-device cs35l41 calibration.
    # These are device data (user's own stock ROM/vendor_a) -> pending-device.
    warnc firmware.device-specific \
        "a730_zap.mbn/gmu_gen70000.bin/cs35l41 per-device cal must come from user device (upstream firmware-prep, sha256-pinned)"

    # --- locale / user defaults ---------------------------------------------
    if grep -q 'LANG="en_US.UTF-8"' "$ROOTFS_DIR/etc/locale.conf" 2>/dev/null; then
        ok locale.default "en_US.UTF-8"
    else
        warnc locale.default "$(cat "$ROOTFS_DIR/etc/locale.conf" 2>/dev/null | tr '\n' ' ')"
    fi

    umount_helpers
    trap - EXIT
}

# ------------------------------------------------------- manifest artifacts --
emit_manifests() {
    log "emitting rootfs.packages.txt / rootfs.files.sha256 / rootfs.manifest"
    unmount_all_helpers
    # Never hash the verification helper mounts (would include host /proc).

    chroot_run rpm -qa 2>/dev/null | LC_ALL=C sort > "$OUT_DIR/rootfs.packages.txt"

    # machine-readable per-package manifest (arch/version/size/install time)
    chroot_run rpm -qa --qf \
        '%{NAME}\t%{EPOCH}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{SIZE}\t%{INSTALLTIME:date}\n' \
        2>/dev/null | LC_ALL=C sort > "$VALIDATION_DIR/packages-by-nevra.tsv"

    # file digests: `<sha256>  </path/inside/rootfs>` (sorted, deterministic)
    # -> boot-builder selects the paths it needs for the initramfs root contract.
    #
    # Hashing is done in Python (single deterministic walk) because a shell
    # pipeline is racy: the tree can be mutated concurrently (another task
    # chrooting into it) and a leaked /proc bind mount silently poisons the
    # output. The walker refuses to run with mounts inside the tree, excludes
    # pseudo-runtime directories (/proc /sys /dev /run /tmp /var/tmp) and secrets,
    # skips paths containing newlines (counted), retries on vanishing files and
    # emits a stats file used for the consistency self-check below.
    if [ "$FILE_DIGESTS" -eq 1 ]; then
        log "hashing rootfs files (disable with --no-file-digests)"
        local mounted_inside=""
        mounted_inside="$(findmnt -rn -o TARGET | awk -v root="$ROOTFS_DIR/" 'index($0, root) == 1' | head -5 || true)"
        if [ -n "$mounted_inside" ]; then
            die "rootfs tree has active mounts (would hash host filesystems); unmount first: $mounted_inside"
        fi
        python3 - "$ROOTFS_DIR" "$OUT_DIR" "$VALIDATION_DIR" <<'PY'
import hashlib, json, os, sys, time

root, out_dir, val_dir = sys.argv[1:4]
EXCLUDED_TOP = {"proc", "sys", "dev", "run", "tmp"}
EXCLUDED_SUBTREES = ("var/tmp", "usr/lib/sysimage/rpm")  # runtime/volatile, not contract-relevant
EXCLUDED_FILES = {"etc/shadow", "etc/gshadow", "etc/security/opasswd"}
CHUNK = 1 << 20


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def walk_tree(stats: dict):
    pairs = []
    symlinks = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_TOP]
        else:
            relp = rel_dir + "/"
            if any(relp == p + "/" or relp.startswith(p + "/") for p in EXCLUDED_SUBTREES):
                dirnames[:] = []
                continue
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if rel in EXCLUDED_FILES:
                stats["secrets_excluded"] += 1
                continue
            if os.path.islink(full):
                try:
                    target = os.readlink(full)
                except OSError:
                    stats["vanished"] += 1
                    continue
                if "\n" in rel or "\t" in rel:
                    stats["skipped_newline"] += 1
                    continue
                symlinks.append("/%s\t%s" % (rel, target))
                continue
            if not os.path.isfile(full):
                continue
            if "\n" in rel:
                stats["skipped_newline"] += 1
                continue
            pairs.append(("/" + rel, full))
    return pairs, symlinks


stats = {"skipped_newline": 0, "vanished": 0, "secrets_excluded": 0, "attempts": 0}
lines = []
symlinks = []
for attempt in range(1, 4):
    stats["vanished"] = 0
    pairs, symlinks = walk_tree(stats)
    lines = []
    for relpath, full in sorted(pairs):
        try:
            lines.append("%s  %s\n" % (sha256_file(full), relpath))
        except FileNotFoundError:
            stats["vanished"] += 1
    stats["attempts"] = attempt
    if stats["vanished"] == 0:
        break
    time.sleep(2)
if stats["vanished"]:
    sys.exit("ERROR: %d files vanished while hashing; the rootfs tree is not quiescent" % stats["vanished"])

digest_path = os.path.join(out_dir, "rootfs.files.sha256")
symlink_path = os.path.join(out_dir, "rootfs.symlinks.txt")
for path, content in ((digest_path, lines), (symlink_path, [s + "\n" for s in sorted(symlinks)])):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)

h = hashlib.sha256()
with open(digest_path, "rb") as f:
    for chunk in iter(lambda: f.read(CHUNK), b""):
        h.update(chunk)
stats.update({"count": len(lines), "sha256": h.hexdigest(), "symlink_count": len(symlinks)})
with open(os.path.join(val_dir, "file-digests-stats.json"), "w", encoding="utf-8") as f:
    json.dump(stats, f, indent=1, sort_keys=True)
    f.write("\n")
print(
    "file digests: %d files, sha256 %s, symlinks %d, skipped_newline=%d, "
    "secrets_excluded=%d, attempts=%d"
    % (stats["count"], stats["sha256"], stats["symlink_count"],
       stats["skipped_newline"], stats["secrets_excluded"], stats["attempts"])
)
PY
        # boot-builder alias: byte-identical copy of the digest list
        cp -f "$OUT_DIR/rootfs.files.sha256" "$OUT_DIR/rootfs.hashes"
    else
        : > "$OUT_DIR/rootfs.files.sha256"
        : > "$OUT_DIR/rootfs.hashes"
        : > "$OUT_DIR/rootfs.symlinks.txt"
        printf '{"count": 0, "sha256": "", "skipped_newline": 0, "secrets_excluded": 0}\n' \
            > "$VALIDATION_DIR/file-digests-stats.json"
    fi

    # ---- manifest inputs + consistency self-check ---------------------------
    local pkgs_sha="" files_sha="" files_count=0 symlink_count=0 skipped_newline=0 secrets_excluded=0
    pkgs_sha="$(sha256sum "$OUT_DIR/rootfs.packages.txt" | cut -d' ' -f1)"
    if [ -s "$OUT_DIR/rootfs.files.sha256" ] && [ -s "$VALIDATION_DIR/file-digests-stats.json" ]; then
        read -r files_sha files_count symlink_count skipped_newline secrets_excluded < <(
            python3 - "$VALIDATION_DIR/file-digests-stats.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("sha256", ""), d.get("count", 0), d.get("symlink_count", 0),
      d.get("skipped_newline", 0), d.get("secrets_excluded", 0))
PY
        )
        local actual_sha actual_count
        actual_sha="$(sha256sum "$OUT_DIR/rootfs.files.sha256" | cut -d' ' -f1)"
        actual_count="$(wc -l < "$OUT_DIR/rootfs.files.sha256")"
        [ "$files_sha" = "$actual_sha" ] || \
            die "digest consistency: recorded sha256 $files_sha != actual $actual_sha"
        [ "$files_count" = "$actual_count" ] || \
            die "digest consistency: recorded count $files_count != actual $actual_count"
        cmp -s "$OUT_DIR/rootfs.files.sha256" "$OUT_DIR/rootfs.hashes" || \
            die "digest consistency: rootfs.hashes is not byte-identical to rootfs.files.sha256"
        ok digest.consistency "files=${files_count} sha256=${files_sha} (rootfs.hashes identical)"
    fi

    python3 - "$OUT_DIR" "$RELEASE" "$PROFILE" "$DESKTOP" "$pkgs_sha" "$files_sha" "$files_count" \
             "$symlink_count" "$skipped_newline" "$secrets_excluded" <<'PY'
import json, sys, datetime
out_dir, release, profile, desktop, pkgs_sha, files_sha, files_count = sys.argv[1:8]
symlink_count, skipped_newline, secrets_excluded = sys.argv[8:11]
packages = []
for line in open(f"{out_dir}/validation/packages-by-nevra.tsv"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 7:
        continue
    name, epoch, ver, rel, arch, size, itime = f[:7]
    epoch = "0" if epoch in ("(none)", "") else epoch
    packages.append({
        "name": name, "epoch": epoch, "version": ver, "release": rel,
        "arch": arch, "size": int(size or 0), "installed": itime,
        "nevra": f"{name}-{epoch}:{ver}-{rel}.{arch}",
    })
manifest = {
    "format": "liuqin-rootfs-manifest/v1",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "image": {
        "id": f"liuqin-fedora-{desktop}",
        "device": "liuqin",
        "architecture": "aarch64",
        "distribution": "fedora",
        "release": release,
        "profile": profile,
        "format": "directory",
        "bootable": False,
        "desktop": desktop,
    },
    "artifact": {
        "rootfs_dir": "rootfs",
        "packages_txt": "rootfs.packages.txt",
        "packages_txt_sha256": pkgs_sha,
        "files_sha256": ("rootfs.files.sha256" if files_sha else None),
        "files_sha256_sha256": files_sha or None,
        "files_sha256_count": int(files_count or 0),
        "hashes_txt": ("rootfs.hashes" if files_sha else None),
        "hashes_txt_sha256": files_sha or None,
        "symlinks_txt": "rootfs.symlinks.txt",
        "symlink_count": int(symlink_count or 0),
        "skipped_newline_paths": int(skipped_newline or 0),
        "excluded_secret_files": int(secrets_excluded or 0),
        "digest_format": "<sha256>  /absolute/path-inside-rootfs (sorted, UTF-8; "
                         "excludes /etc/shadow*, /etc/gshadow*, /etc/security/opasswd, "
                         "/proc, /sys, /dev, /run, /tmp, /var/tmp)",
        "consistency": {
            "manifest_sha256_fields_match_digest_file": True,
            "rootfs_hashes_identical_to_rootfs_files_sha256": bool(files_sha),
        },
    },
    "package_count": len(packages),
    "packages": packages,
}
json.dump(manifest, open(f"{out_dir}/rootfs.manifest", "w"), indent=1, sort_keys=True)
open(f"{out_dir}/rootfs.manifest", "a").write("\n")
print(f"wrote rootfs.manifest: {len(packages)} packages")
PY
}

emit_build_info() {
    log "emitting build-info.json"
    local mkosi_version mkosi_bin_sha script_sha conf_sha profile_sha postinst_sha skeleton_sha
    mkosi_version="$(mkosi --version 2>/dev/null | head -1)"
    mkosi_bin_sha="$(command -v mkosi | xargs sha256sum 2>/dev/null | cut -d' ' -f1)"
    script_sha="$(sha256sum "$SCRIPT_PATH" | cut -d' ' -f1)"
    conf_sha="$(sha256sum "$MKOSI_DIR/mkosi.conf" | cut -d' ' -f1)"
    profile_sha="$(
        if [ -f "$MKOSI_DIR/mkosi.profiles/$PROFILE.conf" ]; then
            sha256sum "$MKOSI_DIR/mkosi.profiles/$PROFILE.conf" | cut -d' ' -f1
        else echo ""; fi)"
    postinst_sha="$(sha256sum "$MKOSI_DIR/mkosi.postinst.chroot" | cut -d' ' -f1)"
    skeleton_sha="$(cd "$MKOSI_DIR" && find mkosi.skeleton -type f -print0 | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)"

    local build_start build_end duration
    build_start="$(cat "$LOG_DIR/build-start-$BUILD_STAMP.epoch" 2>/dev/null || echo 0)"
    build_end="$(cat "$LOG_DIR/build-end-$BUILD_STAMP.epoch" 2>/dev/null || echo 0)"
    # A build whose wrapper died after mkosi finished (or an externally produced
    # tree) may have no build-end epoch: never report a negative duration.
    if [ "$build_end" -gt "$build_start" ] 2>/dev/null; then
        duration=$(( build_end - build_start ))
    else
        duration=0
    fi

    local rootfs_size files_count fedora_version desktop_version
    rootfs_size="$(du -sb "$ROOTFS_DIR" | cut -f1)"
    files_count="$(find "$ROOTFS_DIR" -type f | wc -l)"
    fedora_version="$(sed -n 's/^VERSION_ID=//p' "$ROOTFS_DIR/usr/lib/os-release" 2>/dev/null | head -1 | tr -d '"')"
    if [ "$DESKTOP" = plasma ]; then
        desktop_version="$(chroot "$ROOTFS_DIR" rpm -q --qf '%{VERSION}-%{RELEASE}' plasma-workspace 2>/dev/null | head -1 || true)"
    else
        desktop_version="$(chroot "$ROOTFS_DIR" rpm -q --qf '%{VERSION}-%{RELEASE}' gnome-shell 2>/dev/null | head -1 || true)"
    fi

    local pkgs_sha manifest_sha files_sha digest_count symlink_count
    pkgs_sha="$(sha256sum "$OUT_DIR/rootfs.packages.txt" 2>/dev/null | cut -d' ' -f1 || true)"
    manifest_sha="$(sha256sum "$OUT_DIR/rootfs.manifest" 2>/dev/null | cut -d' ' -f1 || true)"
    files_sha="$(sha256sum "$OUT_DIR/rootfs.files.sha256" 2>/dev/null | cut -d' ' -f1 || true)"
    digest_count="$(wc -l < "$OUT_DIR/rootfs.files.sha256" 2>/dev/null || echo 0)"
    symlink_count="$(wc -l < "$OUT_DIR/rootfs.symlinks.txt" 2>/dev/null || echo 0)"
    export LIUQIN_SKIP_BUILD="$SKIP_BUILD"

    python3 - "$OUT_DIR" "$RELEASE" "$PROFILE" "$DESKTOP" "$BUILD_STAMP" "$duration" \
             "$mkosi_version" "$mkosi_bin_sha" "$script_sha" "$conf_sha" \
             "$profile_sha" "$postinst_sha" "$skeleton_sha" \
             "$rootfs_size" "$files_count" "$fedora_version" "$desktop_version" \
             "$pkgs_sha" "$manifest_sha" "$files_sha" \
             "$digest_count" "$symlink_count" <<'PY'
import json, sys, os, platform, datetime
(out_dir, release, profile, desktop, stamp, duration, mkosi_version, mkosi_bin_sha,
 script_sha, conf_sha, profile_sha, postinst_sha, skeleton_sha,
 rootfs_size, files_count, fedora_version, desktop_version,
 pkgs_sha, manifest_sha, files_sha, digest_count, symlink_count) = sys.argv[1:23]

def sha_or_none(path):
    try:
        import hashlib
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return None

# On --skip-build the inputs must describe the ORIGINAL build, not files that may
# have changed since (e.g. libqmi/libqrtr-glib added to mkosi.conf for the next
# rebuild): reuse the previous build-info inputs block when available.
prev_inputs = None
prev_info = os.path.join(out_dir, "build-info.json")
if os.environ.get("LIUQIN_SKIP_BUILD") == "1" and os.path.exists(prev_info):
    try:
        with open(prev_info, encoding="utf-8") as f:
            prev_inputs = json.load(f).get("inputs") or None
    except (OSError, json.JSONDecodeError):
        prev_inputs = None
finalize_sha = None
try:
    import hashlib
    # out_dir is <project>/out/<name>; the config lives at <project>/mkosi/
    finalize_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(out_dir))), "mkosi", "mkosi.finalize.chroot")
    finalize_sha = hashlib.sha256(open(finalize_path, "rb").read()).hexdigest()
except OSError:
    finalize_sha = None

if os.path.exists(f"{out_dir}/rootfs/usr/lib/systemd/system/gdm.service"):
    login = "gdm"
elif os.path.exists(f"{out_dir}/rootfs/usr/lib/systemd/system/plasmalogin.service"):
    login = "plasmalogin"
elif os.path.exists(f"{out_dir}/rootfs/usr/lib/systemd/system/sddm.service"):
    login = "sddm"
else:
    login = "unknown"

# display-manager.service alias target: consumed by initramfs/boot contracts.
dm_link = f"{out_dir}/rootfs/etc/systemd/system/display-manager.service"
try:
    display_manager = os.readlink(dm_link)
except OSError:
    display_manager = None

info = {
    "format": "liuqin-rootfs-build-info/v1",
    "build": {
        "stamp": stamp,
        "started_at": datetime.datetime.fromtimestamp(int(open(f"{out_dir}/logs/build-start-{stamp}.epoch").read().strip()), datetime.timezone.utc).isoformat(timespec="seconds") if os.path.exists(f"{out_dir}/logs/build-start-{stamp}.epoch") else None,
        "finished_at": datetime.datetime.fromtimestamp(int(open(f"{out_dir}/logs/build-end-{stamp}.epoch").read().strip()), datetime.timezone.utc).isoformat(timespec="seconds") if os.path.exists(f"{out_dir}/logs/build-end-{stamp}.epoch") else None,
        "duration_seconds": int(duration),
        "host": {"hostname": platform.node(), "arch": platform.machine(),
                  "kernel": platform.release(), "python": platform.python_version()},
        "bootstrap": "mkosi (rootful, cross-arch, qemu-user binfmt) + rootful podman",
    },
    "target": {
        "distribution": "fedora",
        "release": fedora_version or release,
        "architecture": "aarch64",
        "format": "directory",
        "bootable": False,
        "profile": profile,
        "desktop": desktop,
        "login_manager": login,
        "display_manager_service": display_manager,
        "selinux_mode": next((line.split("=", 1)[1].strip().strip('\"')
                              for line in open(f"{out_dir}/rootfs/etc/selinux/config")
                              if line.startswith("SELINUX=")), "unknown"),
        "desktop_version": desktop_version,
    },
    "inputs": prev_inputs if prev_inputs else {
        "mkosi_version": mkosi_version,
        "mkosi_binary_sha256": mkosi_bin_sha,
        "script": "scripts/build-rootfs.sh",
        "script_sha256": script_sha,
        "mkosi_conf_sha256": conf_sha,
        "profile_conf_sha256": profile_sha,
        "postinst_sha256": postinst_sha,
        "finalize_sha256": finalize_sha,
        "skeleton_tree_sha256": skeleton_sha,
    },
    "inputs_source": "preserved-from-build (--skip-build)" if prev_inputs else "current-files-at-build",
    "outputs": {
        "rootfs_dir": "rootfs",
        "rootfs_size_bytes": int(rootfs_size or 0),
        "rootfs_file_count": int(files_count or 0),
        "packages_txt": "rootfs.packages.txt",
        "packages_txt_sha256": pkgs_sha or None,
        "manifest": "rootfs.manifest",
        "manifest_sha256": manifest_sha or None,
        "files_sha256": "rootfs.files.sha256",
        "files_sha256_sha256": files_sha or None,
        "files_sha256_count": int(digest_count or 0),
        "hashes_txt": "rootfs.hashes",
        "hashes_txt_sha256": files_sha or None,
        "symlink_count": int(symlink_count or 0),
        "digest_consistency": {
            "digest_file_sha256_matches_manifest": True,
            "rootfs_hashes_identical": True,
        },
        "validation_summary": "validation/verify-summary.json",
        "build_log": f"logs/build-{stamp}.log",
    },
    "notes": [
        "Development image: one development account with a well-known password; NOT for release.",
        "No kernel/initramfs in the rootfs: device layer (kernel-liuqin, liuqin-firmware, ...) is injected at root.img assembly time.",
        "SELinux bring-up baseline is permissive with selinux-policy-targeted; target.selinux_mode records the actual tree. Enforcing requires relabel and device validation.",
        "rootfs.files.sha256 (alias: rootfs.hashes) maps sha256 -> absolute path inside the rootfs; this is the input format for initramfs/root-contract generation.",
        "display-manager.service points at the profile login manager (gdm.service for Workstation, plasmalogin.service for KDE); contracts assert that alias.",
    ],
}
json.dump(info, open(f"{out_dir}/build-info.json", "w"), indent=2, sort_keys=True)
open(f"{out_dir}/build-info.json", "a").write("\n")
print("wrote build-info.json")
PY
}

emit_verify_summary() {
    python3 - "$CHECKS_TSV" "$SUMMARY_JSON" "$OUT_DIR" <<'PY'
import json, sys, datetime
tsv, out, out_dir = sys.argv[1:4]
checks = []
counts = {"PASS": 0, "WARN": 0, "FAIL": 0}
for line in open(tsv):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    cid, status, detail = parts[0], parts[1], parts[2]
    counts[status] = counts.get(status, 0) + 1
    checks.append({"id": cid, "status": status, "detail": detail})
summary = {
    "format": "liuqin-rootfs-verify/v1",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "result": "FAIL" if counts.get("FAIL") else ("WARN" if counts.get("WARN") else "PASS"),
    "counts": counts,
    "checks": checks,
}
json.dump(summary, open(out, "w"), indent=2, sort_keys=True)
open(out, "a").write("\n")
print(f"verification: {summary['result']} ({counts})")
PY
}

# -------------------------------------------------------------------- main --
log "project: $PROJECT_ROOT"
log "target : fedora/$RELEASE arm64 profile=$PROFILE out=${OUT_DIR#$PROJECT_ROOT/}"
[ "$SKIP_BUILD" -eq 1 ] && log "skip-build: reusing existing rootfs tree" || build_rootfs

[[ -d "$ROOTFS_DIR" ]] || die "no rootfs tree at $ROOTFS_DIR (build failed or --skip-build used before a build)"

verify_rootfs
emit_manifests
emit_build_info
emit_verify_summary

FAILS="$(awk -F'\t' '$2=="FAIL"' "$CHECKS_TSV" | wc -l)"
WARNS="$(awk -F'\t' '$2=="WARN"' "$CHECKS_TSV" | wc -l)"
log "checks: FAIL=$FAILS WARN=$WARNS"
log "artifacts:"
log "  ${ROOTFS_DIR#$PROJECT_ROOT/}/            ($(du -sh "$ROOTFS_DIR" | cut -f1))"
log "  ${OUT_DIR#$PROJECT_ROOT/}/rootfs.manifest"
log "  ${OUT_DIR#$PROJECT_ROOT/}/rootfs.hashes (alias of rootfs.files.sha256)"
log "  ${OUT_DIR#$PROJECT_ROOT/}/build-info.json"
log "  ${OUT_DIR#$PROJECT_ROOT/}/validation/verify-summary.json"
log "  ${LOG_DIR#$PROJECT_ROOT/}/build-$BUILD_STAMP.log"
if [ "$FAILS" -gt 0 ]; then
    die "rootfs validation failed ($FAILS check(s)); see ${VERIFY_LOG#$PROJECT_ROOT/}"
fi
log "done"
