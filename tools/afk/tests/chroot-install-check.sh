#!/bin/bash
# AFK channel (TN0048) — install the overlay into the *real* device rootfs in a
# user-mode QEMU chroot, without a device and without touching the rootfs tree.
#
# What this proves (offline):
#   * overlays/afk/install.sh runs on Fedora 44 aarch64 (no host-only paths)
#   * the offline RPM bundle resolves/installs against the delivery rootfs
#     (krdp 6.7.5 + deps, dnsmasq, openssl, dnf5)
#   * file modes/ownership, authorized_keys, KRDP TLS identity, user-unit
#     symlinks, sshd effective config (with the *device's* sshd), backups
#   * `--uninstall` removes overlay files and restores the pre-existing file
#
# What it can NOT prove: anything that needs a running systemd session
# (autologin, KRDP portal session, journald persistence, RDP port) - that is
# pending-device.
#
# Requirements: sudo (passwordless or a prompt), qemu-aarch64 binfmt (already
# registered on this host), a device rootfs tree in out/tn0045-rootfs-*/rootfs.
#
# Usage: tests/chroot-install-check.sh [--rootfs PATH] [--keep] [--skip-packages]
set -uo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

ROOTFS=""
KEEP=0
SKIP_PACKAGES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="${2:?}"; shift 2 ;;
        --rootfs=*) ROOTFS="${1#*=}"; shift ;;
        --keep) KEEP=1; shift ;;
        --skip-packages) SKIP_PACKAGES=--skip-packages; shift ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

pass=0
fail=0
okc()   { printf '\033[32m[pass]\033[0m %s\n' "$*"; pass=$((pass + 1)); }
failc() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail + 1)); }
sect()  { printf '\n== %s ==\n' "$*"; }

afk_state_init
EVIDENCE_DIR="$AFK_STATE_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/chroot-install-check-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

say "log: $LOG"

# ------------------------------------------------------------- preconditions ---
have_passwordless_sudo || { warn "passwordless sudo required for overlayfs mounts; aborting"; exit 0; }
command -v qemu-aarch64-static >/dev/null 2>&1 || command -v qemu-aarch64 >/dev/null 2>&1 || \
    { warn "qemu-aarch64 not installed; aborting"; exit 0; }
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    warn "binfmt qemu-aarch64 not registered; aborting"; exit 0
fi

if [ -z "$ROOTFS" ]; then
    ROOTFS="$(ls -1dt "$AFK_ROOT"/out/tn0045-rootfs-*/rootfs 2>/dev/null | head -n1 || true)"
fi
[ -n "$ROOTFS" ] || die "no device rootfs found (pass --rootfs)"
ROOTFS="$(cd "$ROOTFS" && pwd)"
[ -f "$ROOTFS/usr/lib/sysimage/rpm/rpmdb.sqlite" ] || die "$ROOTFS is not a Fedora rootfs"
say "device rootfs: $ROOTFS"

TARBALL="$(bash "$TOOLS_DIR/build-overlay.sh" 2>/dev/null)" || die "could not build the overlay tarball"
say "overlay tarball: $TARBALL"
RPM_DIR="$AFK_STATE_DIR/repo/rpms"
[ -d "$RPM_DIR" ] && ls "$RPM_DIR"/*.rpm >/dev/null 2>&1 || { [ -z "$SKIP_PACKAGES" ] && die "no RPM bundle at $RPM_DIR (run tools/afk/afk.sh repo build)"; }

# ---------------------------------------------------------------- mount + setup ---
WORK="$AFK_STATE_DIR/run/chroot-check"
# The upper layer is written by root inside the chroot, but the work dir itself
# is created here; clean both with the same privileges.
sudo -n rm -rf -- "$WORK" 2>/dev/null || rm -rf -- "$WORK" 2>/dev/null || true
mkdir -p "$WORK"/{upper,work,mnt}
MNT="$WORK/mnt"

cleanup() {
    sudo -n umount "$MNT/proc" 2>/dev/null || true
    sudo -n umount "$MNT/dev" 2>/dev/null || true
    sudo -n umount "$MNT" 2>/dev/null || true
    if [ "$KEEP" = 1 ]; then
        say "kept work dir (upper layer with the installed overlay): $WORK"
    else
        sudo -n rm -rf -- "$WORK" 2>/dev/null || rm -rf -- "$WORK" 2>/dev/null || warn "could not remove $WORK"
    fi
}
trap cleanup EXIT

say "mounting an overlayfs (lower=$ROOTFS, upper=$WORK/upper)"
sudo -n mount -t overlay overlay -o "lowerdir=$ROOTFS,upperdir=$WORK/upper,workdir=$WORK/work" "$MNT" \
    || die "overlayfs mount failed"
sudo -n mount --bind /dev "$MNT/dev" 2>/dev/null || warn "could not bind /dev (some rpm scriptlets may complain)"
sudo -n mount --bind /proc "$MNT/proc" 2>/dev/null || warn "could not bind /proc"

mkdir -p "$MNT/tmp"
sudo -n tar -xzf "$TARBALL" -C "$MNT/tmp"
INSTALLER="$(ls -d "$MNT"/tmp/afk-overlay-*/install.sh 2>/dev/null | head -n1)"
[ -n "$INSTALLER" ] || die "installer not found in the extracted tarball"
INSTALLER_IN_CHROOT="/${INSTALLER#"$MNT"/}"
say "installer (in chroot): $INSTALLER_IN_CHROOT"

INSTALL_ARGS=(--no-services)
if [ -n "$SKIP_PACKAGES" ]; then
    :
else
    sudo -n mkdir -p "$MNT/tmp/afk-rpms"
    sudo -n tar -xzf "$AFK_STATE_DIR/repo/afk-rpms.tar.gz" -C "$MNT/tmp/afk-rpms"
    INSTALL_ARGS+=(--rpms /tmp/afk-rpms)
fi

# A pre-existing file the installer must back up and --uninstall must restore.
SENTINEL="# chroot-test sentinel: this file predates the overlay"
sudo -n mkdir -p "$MNT/etc/ssh/sshd_config.d"
printf '%s\n' "$SENTINEL" | sudo -n tee "$MNT/etc/ssh/sshd_config.d/90-afk.conf" >/dev/null

# Admission topology files (validated by the initramfs on every boot) must be
# byte-identical after install *and* after uninstall.
sudo -n mkdir -p "$MNT/etc/liuqin"
printf 'liuqin-fedora-root-v1\n' | sudo -n tee "$MNT/etc/liuqin-fedora-root" >/dev/null
printf '# afk chroot test: fake contract\n' | sudo -n tee "$MNT/etc/liuqin-fedora-root.contract" >/dev/null
printf '# afk chroot test: fake image contract\n' | sudo -n tee "$MNT/etc/liuqin/image-contract" >/dev/null

PROTECTED_PATHS="/etc/liuqin-fedora-root /etc/liuqin-fedora-root.contract /etc/liuqin/image-contract"
protected_sum() { sudo -n chroot "$MNT" /bin/bash -c "sha256sum $PROTECTED_PATHS 2>/dev/null" | awk '{print $1}' | tr '\n' ' '; }
PROTECTED_SUM_BEFORE="$(protected_sum)"
say "protected admission file sums (before): $PROTECTED_SUM_BEFORE"

chroot_do() { sudo -n chroot "$MNT" /bin/bash -c "$1"; }
assert_ok() {  # assert_ok <description> <chroot command>
    if chroot_do "$2" >/dev/null 2>&1; then okc "$1"; else failc "$1"; fi
}

# --------------------------------------------------------------------- install ---
sect "install (--no-services)"
if sudo -n chroot "$MNT" /bin/bash "$INSTALLER_IN_CHROOT" "${INSTALL_ARGS[@]}"; then
    okc "installer exited 0"
else
    failc "installer failed"
fi

sect "installed packages (aarch64 RPM bundle vs delivery rootfs)"
for pkg in krdp krdp-libs dnsmasq openssl dnf5; do
    assert_ok "rpm -q $pkg" "rpm -q $pkg"
done
assert_ok "krdp version matches the rootfs plasma series (6.7.x)" "rpm -q --qf '%{VERSION}' krdp | grep -q '^6\\.7\\.'"

sect "installed files and modes"
assert_ok "sshd drop-in installed"            "test -s /etc/ssh/sshd_config.d/90-afk.conf"
assert_ok "NM leaves usb0 unmanaged"          "grep -q 'unmanaged-devices=interface-name:usb0' /etc/NetworkManager/conf.d/90-afk-unmanaged.conf"
assert_ok "no NM connection profile for usb0" "test ! -e /etc/NetworkManager/system-connections/99-afk-usb0.nmconnection"
assert_ok "usb0 address unit installed"       "test -s /etc/systemd/system/afk-usb0-address.service"
assert_ok "usb0 address timer installed"      "test -s /etc/systemd/system/afk-usb0-address.timer"
assert_ok "afk-usb0-up is executable"         "test -x /usr/local/sbin/afk-usb0-up"
assert_ok "journald persistent drop-in"       "grep -q '^Storage=persistent' /etc/systemd/journald.conf.d/90-afk-persistent.conf"
assert_ok "dhcp unit installed"               "test -s /etc/systemd/system/afk-usb0-dhcp.service"
assert_ok "autologin drop-in (user)"           "grep -q '^User=user' /etc/plasmalogin.conf.d/90-afk-autologin.conf"
assert_ok "autologin drop-in (session file)"   "grep -qx 'Session=plasma.desktop' /etc/plasmalogin.conf.d/90-afk-autologin.conf"
assert_ok "powerdevilrc (Plasma 6 format)"     "grep -q '^\[AC\]\[Display\]' /etc/xdg/powerdevilrc"
assert_ok "old powermanagementprofilesrc not installed" "test ! -e /etc/xdg/powermanagementprofilesrc"
assert_ok "krdp config has SystemUserEnabled" "grep -q '^SystemUserEnabled=true' /etc/xdg/krdpserverrc"
assert_ok "afk-shot is executable"            "test -x /usr/local/sbin/afk-shot"
assert_ok "afk-collect is executable"         "test -x /usr/local/sbin/afk-collect"
assert_ok "watchdog drop-in NOT installed by default" "test ! -e /etc/systemd/system.conf.d/90-afk-watchdog.conf"
assert_ok "firewall unit NOT installed by default"    "test ! -e /etc/systemd/system/afk-firewall.service"
assert_ok "/var/log/journal is 2755 root:systemd-journal" "[ \"\$(stat -c '%a %U:%G' /var/log/journal)\" = '2755 root:systemd-journal' ]"

sect "user state"
assert_ok "authorized_keys has the AFK key"   "grep -q 'afk-tn0048' /home/user/.ssh/authorized_keys"
assert_ok "authorized_keys is 0600 user"      "[ \"\$(stat -c '%a %U' /home/user/.ssh/authorized_keys)\" = '600 user' ]"
assert_ok "krdp certificate generated"        "test -s /home/user/.local/share/krdpserver/krdp.crt"
assert_ok "krdp key is 0600 user"             "[ \"\$(stat -c '%a %U' /home/user/.local/share/krdpserver/krdp.key)\" = '600 user' ]"
assert_ok "krdp user unit enabled via wants symlink" \
    "test -L /home/user/.config/systemd/user/plasma-workspace.target.wants/app-org.kde.krdpserver.service"
assert_ok "preauth user unit enabled via wants symlink" \
    "test -L /home/user/.config/systemd/user/plasma-workspace.target.wants/afk-krdp-preauth.service"
assert_ok "file manifest recorded"            "test -s /var/lib/afk/files.manifest"
assert_ok "overlay version recorded"          "test -s /var/lib/afk/version"
assert_ok "previous 90-afk.conf was backed up" "grep -rqs 'chroot-test sentinel' /var/lib/afk/backup/"
if [ "$(protected_sum)" = "$PROTECTED_SUM_BEFORE" ]; then
    okc "admission topology files untouched by install"
else
    failc "admission topology files CHANGED by install ($(protected_sum) != $PROTECTED_SUM_BEFORE)"
fi

sect "sshd effective configuration (device sshd, real drop-in)"
assert_ok "sshd -t accepts the config"        "ssh-keygen -A >/dev/null 2>&1; sshd -t"
assert_ok "PasswordAuthentication yes"        "sshd -T 2>/dev/null | grep -qx 'passwordauthentication yes'"
assert_ok "PermitRootLogin no"                "sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'"
assert_ok "AllowUsers user"                   "sshd -T 2>/dev/null | grep -qx 'allowusers user'"
assert_ok "MaxAuthTries 5"                    "sshd -T 2>/dev/null | grep -qx 'maxauthtries 5'"
assert_ok "ClientAliveInterval 30"            "sshd -T 2>/dev/null | grep -qx 'clientaliveinterval 30'"

# ------------------------------------------------------------------- uninstall ---
sect "uninstall"
if sudo -n chroot "$MNT" /bin/bash "$INSTALLER_IN_CHROOT" --uninstall --no-services; then
    okc "uninstall exited 0"
else
    failc "uninstall failed"
fi
# The pre-existing 90-afk.conf must be restored (sentinel), so check that the
# *overlay content* is gone rather than the path.
assert_ok "overlay sshd content removed"      "! grep -q 'AFK channel (TN0048)' /etc/ssh/sshd_config.d/90-afk.conf"
assert_ok "pre-existing 90-afk.conf restored" "grep -q 'chroot-test sentinel' /etc/ssh/sshd_config.d/90-afk.conf"
assert_ok "afk units removed"                 "test ! -e /etc/systemd/system/afk-usb0-dhcp.service"
assert_ok "NM unmanaged conf removed"         "test ! -e /etc/NetworkManager/conf.d/90-afk-unmanaged.conf"
assert_ok "usb0 address unit removed"         "test ! -e /etc/systemd/system/afk-usb0-address.service"
if [ "$(protected_sum)" = "$PROTECTED_SUM_BEFORE" ]; then
    okc "admission topology files untouched by uninstall"
else
    failc "admission topology files CHANGED by uninstall"
fi
assert_ok "manifest removed"                  "test ! -e /var/lib/afk/files.manifest"
assert_ok "installed packages intentionally kept" "rpm -q krdp >/dev/null"
assert_ok "evidence dir kept (/var/log/afk)"  "test -d /var/log/afk"

sect "summary"
printf 'pass=%d fail=%d  log=%s\n' "$pass" "$fail" "$LOG"
[ "$fail" -eq 0 ]
