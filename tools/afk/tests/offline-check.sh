#!/bin/bash
# AFK channel — offline self-check for the host-side tooling.
#
# Verifies everything that can be verified without a device:
#   * every shell script parses (bash -n) and every python file compiles
#   * the overlay tarball builds and has the expected layout/modes
#   * sshd drop-in parses with the host's real sshd (-t, temp host key)
#   * systemd units have valid syntax / only expected "binary not found" warnings
#   * USB ownership config has the expected static keys (never reload host NM)
#   * krfb/krdp selection evidence is still accurate against the device rpmdb
#   * documentation links referenced from the task README exist
#
# Usage: tests/offline-check.sh [--keep]
# Exit code 0 = all required checks passed.
set -uo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

pass=0
fail=0
skip=0
okc()   { printf '\033[32m[pass]\033[0m %s\n' "$*"; pass=$((pass + 1)); }
failc() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail + 1)); }
skipc() { printf '\033[33m[skip]\033[0m %s\n' "$*"; skip=$((skip + 1)); }
sect()  { printf '\n== %s ==\n' "$*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/afk-offline-check.XXXXXX")"
cleanup() { [ "$KEEP" = 1 ] && echo "kept: $work" || rm -rf -- "$work"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 1. syntax ---
sect "shell syntax"
while IFS= read -r -d '' f; do
    if bash -n "$f" 2>"$work/syntax.err"; then
        okc "bash -n ${f#"$AFK_ROOT/"}"
    else
        failc "bash -n ${f#"$AFK_ROOT/"}"; sed -n '1,5p' "$work/syntax.err"
    fi
done < <(find "$TOOLS_DIR" "$AFK_ROOT/overlays/afk" -type f -name '*.sh' -print0)

sect "python syntax"
if python3 -m py_compile "$TOOLS_DIR/dhcp-serve.py" 2>"$work/py.err"; then
    okc "py_compile dhcp-serve.py"
else
    failc "py_compile dhcp-serve.py"; cat "$work/py.err"
fi

# --------------------------------------------------------------- 2. overlay ---
sect "overlay tarball"
if tarball="$(bash "$TOOLS_DIR/build-overlay.sh" 2>"$work/tar.err")"; then
    okc "tarball builds: $(basename "$tarball")"
    tar -tzf "$tarball" >"$work/tar-list.txt" 2>/dev/null
    tar -tvzf "$tarball" >"$work/tar-verbose.txt" 2>/dev/null
    list="$(cat "$work/tar-list.txt")"
    for want in \
        install.sh afk-pubkey.txt packages.txt VERSION \
        files/etc/ssh/sshd_config.d/90-afk.conf \
        files/etc/NetworkManager/conf.d/90-afk-unmanaged.conf \
        files/etc/systemd/system/afk-usb0-address.service \
        files/etc/systemd/system/afk-usb0-address.timer \
        files/usr/local/sbin/afk-usb0-up \
        files/etc/systemd/journald.conf.d/90-afk-persistent.conf \
        files/etc/systemd/system/afk-usb0-dhcp.service \
        files/etc/systemd/system/afk-boot-snapshot.service \
        files/etc/systemd/system/afk-shutdown-snapshot.service \
        files/usr/local/sbin/afk-shot \
        files/usr/local/sbin/afk-collect \
        files/usr/local/sbin/afk-boot-snapshot \
        files/usr/local/sbin/afk-health \
        files/usr/local/sbin/afk-krdp-preauth \
        files/etc/plasmalogin.conf.d/90-afk-autologin.conf \
        files/etc/xdg/krdpserverrc \
        files/etc/xdg/powerdevilrc \
        files/etc/xdg/kscreenlockerrc \
        files/home/user/.config/systemd/user/afk-krdp-preauth.service ; do
        if grep -q "/$want$" "$work/tar-list.txt"; then
            okc "payload contains $want"
        else
            failc "payload MISSING $want"
        fi
    done
    # Symlinks to the krdp unit must be stored as symlinks (cp -a + tar keep them).
    if grep -q "app-org.kde.krdpserver.service -> /usr/lib/systemd/user" "$work/tar-verbose.txt"; then
        okc "krdp user-unit symlink preserved"
    else
        failc "krdp user-unit symlink missing/not a symlink"
    fi
    # Plasmalogin needs the session *file* name; sddm-style "plasma" is a
    # silent autologin failure on the real device.
    if grep -q "files/etc/plasmalogin.conf.d/90-afk-autologin.conf" "$work/tar-list.txt"; then
        tar -xzOf "$tarball" --wildcards "*/files/etc/plasmalogin.conf.d/90-afk-autologin.conf" \
            >"$work/autologin.conf" 2>/dev/null
        if grep -qx 'Session=plasma.desktop' "$work/autologin.conf"; then
            okc "autologin uses the session file name (Session=plasma.desktop)"
        else
            failc "autologin Session= is not plasma.desktop (plasmalogin would skip autologin)"
        fi
    fi
    rm -f "$tarball" "$tarball.sha256"
else
    failc "tarball build failed"; sed -n '1,10p' "$work/tar.err"
fi

# -------------------------------------------------------------- 3. sshd conf ---
sect "sshd drop-in"
if have_cmd sshd; then
    tmpconf="$work/sshd_test.conf"
    # Copy the drop-in to a whitespace-free path first: sshd's Include tokenizes
    # on spaces, and the workspace path may contain spaces.
    cp "$AFK_ROOT/overlays/afk/files/etc/ssh/sshd_config.d/90-afk.conf" "$work/90-afk.conf"
    ssh-keygen -q -t ed25519 -N '' -f "$work/hostkey" >/dev/null 2>&1
    {
        echo "Port 2222"
        echo "ListenAddress 127.0.0.1"
        echo "HostKey $work/hostkey"
        echo "PidFile $work/sshd.pid"
        echo "Include $work/90-afk.conf"
    } >"$tmpconf"
    if sshd -t -f "$tmpconf" 2>"$work/sshd.err"; then
        okc "sshd -t accepts the drop-in"
    else
        failc "sshd -t rejects the drop-in"; cat "$work/sshd.err"
    fi
    # Read the complete output before grep: under pipefail, grep -q can close
    # the pipe early and turn sshd's SIGPIPE into a false configuration failure.
    effective_ok=0
    sshd -T -f "$tmpconf" >"$work/sshd-effective.txt" 2>"$work/sshd-effective.err" && effective_ok=1
    if [ "$effective_ok" = 1 ] && grep -qix 'PasswordAuthentication yes' "$work/sshd-effective.txt"; then
        okc "sshd effective config: PasswordAuthentication yes (bootstrap)"
    else
        failc "sshd effective config does not show the expected password auth"
    fi
    if [ "$effective_ok" = 1 ] && grep -qix 'PermitRootLogin no' "$work/sshd-effective.txt"; then
        okc "sshd effective config: PermitRootLogin no"
    else
        failc "sshd effective config PermitRootLogin unexpected"
    fi
else
    skipc "sshd not installed on this host"
fi

# ------------------------------------------------------------- 4. systemd units ---
sect "systemd unit syntax"
if have_cmd systemd-analyze; then
    rc=0
    for unit in "$AFK_ROOT"/overlays/afk/files/etc/systemd/system/*.service; do
        out="$(systemd-analyze verify --man=no "$unit" 2>&1)"
        # Missing executables are expected: the units refer to the *device* rootfs.
        filtered="$(printf '%s\n' "$out" | grep -vE 'is not executable|No such file or directory|Failed to prepare|Unit .* not found|Cannot add dependency' || true)"
        if [ -n "$filtered" ]; then
            failc "systemd-analyze: $(basename "$unit")"; printf '%s\n' "$filtered" | sed -n '1,5p'; rc=1
        fi
    done
    [ "$rc" = 0 ] && okc "all overlay units pass systemd-analyze verify (ignoring device-only binaries)"
else
    skipc "systemd-analyze not available"
fi

# ------------------------------------------------------------ 5. NM keyfile ---
sect "USB network ownership (network-first design)"
NM_UNMANAGED="$AFK_ROOT/overlays/afk/files/etc/NetworkManager/conf.d/90-afk-unmanaged.conf"
NM_OLD="$AFK_ROOT/overlays/afk/files/etc/NetworkManager/system-connections/99-afk-usb0.nmconnection"
if grep -q 'unmanaged-devices=interface-name:usb0' "$NM_UNMANAGED" 2>/dev/null; then
    okc "NM leaves usb0 unmanaged (no DHCP takeover after switch_root)"
else
    failc "NM unmanaged config missing or wrong"
fi
if [ -e "$NM_OLD" ]; then
    failc "legacy NM connection profile still present (NM would manage usb0)"
else
    okc "no NM connection profile for usb0 (address is owned by a unit)"
fi
if grep -q 'ip addr replace \|"$ADDR" dev' "$AFK_ROOT/overlays/afk/files/usr/local/sbin/afk-usb0-up" 2>/dev/null; then
    okc "afk-usb0-up pins 192.168.7.2/24 with ip addr replace"
else
    failc "afk-usb0-up does not pin the address as expected"
fi
if grep -q 'ConditionPathExists=/sys/class/net/usb0' "$AFK_ROOT/overlays/afk/files/etc/systemd/system/afk-usb0-address.service" 2>/dev/null; then
    okc "address unit is guarded by the usb0 device"
else
    failc "address unit lacks the usb0 condition"
fi
if grep -q 'OnUnitActiveSec=' "$AFK_ROOT/overlays/afk/files/etc/systemd/system/afk-usb0-address.timer" 2>/dev/null; then
    okc "address safety-net timer re-asserts the address periodically"
else
    failc "address timer missing OnUnitActiveSec (no safety net)"
fi
# The installer must persist the address units BEFORE packages/user steps.
order_line_net="$(grep -n '^apply_network_early' "$AFK_ROOT/overlays/afk/install.sh" | head -n1 | cut -d: -f1)"
order_line_pkg="$(grep -n '^install_packages$' "$AFK_ROOT/overlays/afk/install.sh" | head -n1 | cut -d: -f1)"
if [ -n "$order_line_net" ] && [ -n "$order_line_pkg" ] && [ "$order_line_net" -lt "$order_line_pkg" ]; then
    okc "installer applies the USB network before packages/config"
else
    failc "installer no longer applies the network first"
fi
if grep -q 'is_protected_path' "$AFK_ROOT/overlays/afk/install.sh" && \
   grep -q '/etc/liuqin-fedora-root' "$AFK_ROOT/overlays/afk/install.sh"; then
    okc "installer guards the initramfs admission topology files"
else
    failc "installer has no guard for /etc/liuqin* admission files"
fi
# Loading a copied snippet was never exercised by reloading the host daemon.
# That only touched the host's real configuration and violated the network rule.
skipc "host NetworkManager reload deliberately excluded; static USB config checked"

# --------------------------------------------------------- 6. package choices ---
sect "package selection evidence"
PKGMANIFEST="$(ls -1t "$AFK_ROOT"/out/tn0045-rootfs-*/rootfs.packages.txt 2>/dev/null | head -n1 || true)"
if [ -n "${PKGMANIFEST:-}" ] && [ -f "$PKGMANIFEST" ]; then
    if grep -q '^kwin-6\.7\.5' "$PKGMANIFEST"; then
        okc "device rootfs is Plasma/kwin 6.7.5 (matches krdp 6.7.5 from f44 updates)"
    else
        skipc "device rootfs plasma version differs; re-check krdp version pairing"
    fi
    if grep -q '^krdp-' "$PKGMANIFEST"; then
        failc "krdp is already in the rootfs; the repo would be redundant"
    else
        okc "krdp is not in the rootfs (offline repo is needed)"
    fi
    if grep -q '^spectacle-' "$PKGMANIFEST"; then
        okc "spectacle present (host-side screenshots need no extra package)"
    else
        failc "spectacle missing from the rootfs; screenshot path breaks"
    fi
    if grep -q '^systemd-259' "$PKGMANIFEST"; then
        okc "systemd (and thus systemd-pstore) present"
    fi
else
    skipc "no device rootfs package manifest found (out/tn0045-rootfs-*/rootfs.packages.txt)"
fi

# ------------------------------------------------------------- 7. repo/docs ---
sect "documentation and repo wiring"
for f in \
    "$AFK_ROOT/overlays/afk/README.md" \
    "$AFK_ROOT/tools/afk/README.md" \
    "$TOOLS_DIR/packages.txt" "$TOOLS_DIR/afk.env.example" ; do
    if [ -f "$f" ]; then okc "exists ${f#"$AFK_ROOT/"}"; else failc "missing ${f#"$AFK_ROOT/"}"; fi
done
# The full maintainer tree also carries a longer channel guide and the original
# task record; a public source export intentionally omits them.
if [ -f "$AFK_ROOT/docs/maintenance/afk-channel.md" ]; then
    if grep -q 'tools/afk/afk.sh' "$AFK_ROOT/docs/maintenance/afk-channel.md"; then
        okc "docs reference the host tool"
    else
        failc "docs/maintenance/afk-channel.md does not reference tools/afk/afk.sh"
    fi
else
    skipc "full maintainer channel guide not present (public source export)"
fi
if grep -qE '^krdp$' "$TOOLS_DIR/packages.txt"; then
    okc "packages.txt includes krdp"
else
    failc "packages.txt is missing krdp"
fi

# ---------------------------------------------------------------- 8. gitignore ---
sect "secret hygiene"
if [ -f "$TOOLS_DIR/keys/.gitignore" ] && grep -q '^id_ed25519_afk$' "$TOOLS_DIR/keys/.gitignore"; then
    okc "private AFK key is git-ignored"
else
    failc "keys/.gitignore does not ignore the private key"
fi
if [ -f "$TOOLS_DIR/afk.env" ]; then
    skipc "tools/afk/afk.env exists (local config; make sure it stays untracked)"
fi
if [ -f "$AFK_SSH_KEY" ]; then
    if git -C "$AFK_ROOT" check-ignore -q "$AFK_SSH_KEY" 2>/dev/null; then
        okc "local private key exists and is git-ignored"
    else
        failc "local private key exists but is NOT git-ignored: $AFK_SSH_KEY"
    fi
else
    okc "no local private key yet (gen-keys.sh creates it on setup)"
fi

# ------------------------------------------------------------------ summary ---
sect "summary"
printf 'pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
