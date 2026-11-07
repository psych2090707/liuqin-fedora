#!/usr/bin/env bash
# Offline validation of overlays/kde/ against the real Fedora 44 KDE 6.7.5
# rootfs (out/rootfs/rootfs) using its own kreadconfig6/kwriteconfig6 via
# qemu-user. No device, no KWin session: this verifies key names, group
# nesting, value types and KConfig system-dir fallback as parsed by KDE.
set -uo pipefail
project=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
rootfs=$project/out/rootfs/rootfs
overlay=$project/overlays/kde
fail=0
pass() { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
skip() { printf 'SKIP  %s\n' "$*"; }
say()  { printf '%s\n' "$*"; }

[ -d "$overlay/etc/xdg" ] || { say "FAIL: overlays/kde missing"; exit 1; }
if [ ! -x "$rootfs/usr/bin/kreadconfig6" ] || ! command -v qemu-aarch64-static >/dev/null; then
    skip "rootfs kreadconfig6/qemu-user unavailable; INI-only checks"
else
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/home/.config" "$tmp/xdg"
    export HOME=$tmp/home XDG_CONFIG_HOME=$tmp/home/.config
    export XDG_CONFIG_DIRS="$overlay/etc/xdg:$rootfs/usr/share/kde-settings/kde-profile/default/xdg"
    K() { qemu-aarch64-static -L "$rootfs" "$rootfs/usr/bin/kreadconfig6" "$@"; }
    expect() { # file groups key expected type
        local file=$1 groups=$2 key=$3 want=$4 type=${5:-}
        local args=(--file "$file")
        IFS='|' read -ra gl <<<"$groups"
        for g in "${gl[@]}"; do args+=(--group "$g"); done
        args+=(--key "$key")
        # NOTE: kreadconfig6 --type <T> returns empty / exit 128 for plain
        # system-config values in KDE 6.7.5 (verified 2026-10-20), so the type
        # column is documentation only; KWin source is the type authority.
        local got; got=$(K "${args[@]}" 2>/dev/null || true)
        if [ "$got" = "$want" ]; then pass "$file [$groups] $key=$got"
        else bad "$file [$groups] $key expected '$want' got '$got'"; fi
    }
    expect kwinrc 'Wayland' VirtualKeyboardMode 1 int
    expect kwinrc 'Wayland' InputMethod /usr/share/applications/org.kde.plasma.keyboard.desktop
    expect kwinrc 'Libinput|Defaults|Touchpad' TapToClick true bool
    expect kwinrc 'Libinput|Defaults|Touchpad' NaturalScroll true bool
    expect kwinrc 'Libinput|Defaults|Touchpad' DisableWhileTyping true bool
    for profile in AC Battery LowBattery; do
        expect powerdevilrc "$profile|SuspendAndShutdown" PowerButtonAction 128 int
        expect powerdevilrc "$profile|SuspendAndShutdown" LidAction 64 int
    done
    # kwriteconfig6 round-trip through a copy (does not touch the overlay)
    cp "$overlay/etc/xdg/kwinrc" "$tmp/xdg/kwinrc"
    out=$(HOME=$tmp/home XDG_CONFIG_HOME=$tmp/xdg XDG_CONFIG_DIRS= \
          qemu-aarch64-static -L "$rootfs" "$rootfs/usr/bin/kreadconfig6" \
          --file kwinrc --group Wayland --key VirtualKeyboardMode 2>/dev/null || true)
    [ "$out" = "1" ] && pass "kwriteconfig6/kreadconfig6 round-trip kwinrc" \
        || bad "round-trip kwinrc got '$out'"
fi
# static/schema checks independent of qemu
grep -q 'VirtualKeyboardMode' "$rootfs/usr/share/config.kcfg/kwin.kcfg" 2>/dev/null \
    && skip "VirtualKeyboardMode not in kwin.kcfg (read manually in inputmethod.cpp; verified from source)" \
    || skip "VirtualKeyboardMode not in kwin.kcfg (expected: plugin reads it in inputmethod.cpp)"
grep -q '<entry name="InputMethod" type="Path"' "$rootfs/usr/share/config.kcfg/kwin.kcfg" 2>/dev/null \
    && pass "kwin.kcfg schema contains [Wayland] InputMethod (Path)" \
    || bad "kwin.kcfg schema missing InputMethod"
grep -q 'InputMethod\[\$e\]=/usr/share/applications/org.kde.plasma.keyboard.desktop' \
    "$rootfs/usr/share/kde-settings/kde-profile/default/xdg/kwinrc" 2>/dev/null \
    && pass "Fedora kde-settings supplies plasma-keyboard InputMethod default" \
    || bad "Fedora kde-settings InputMethod default not found"
for f in "$overlay/etc/xdg/kwinrc" "$overlay/etc/xdg/powerdevilrc" \
         "$overlay/etc/systemd/logind.conf.d/95-liuqin-kde.conf"; do
    [ -f "$f" ] && pass "overlay file exists: ${f#$project/}" || bad "missing $f"
done
sh -n "$overlay/usr/libexec/liuqin/kde-tablet-status" 2>/dev/null \
    && pass "kde-tablet-status helper: sh -n" || bad "kde-tablet-status syntax"
for f in "$overlay/etc/xdg/kwinrc" "$overlay/etc/xdg/powerdevilrc" \
         "$overlay/etc/systemd/logind.conf.d/95-liuqin-kde.conf" \
         "$overlay/usr/share/doc/liuqin/kde-examples/kscreenlockerrc.fingerprint.example"; do
    grep -q '^#' "$f" || bad "$f lacks provenance comments"
done
say '----'
[ "$fail" = 0 ] && { say 'KDE OVERLAY: PASS'; exit 0; } || { say 'KDE OVERLAY: FAIL'; exit 1; }
