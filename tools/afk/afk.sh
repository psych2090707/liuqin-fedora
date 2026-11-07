#!/bin/bash
# AFK channel — host-side control tool for the liuqin Fedora device.
#
# One USB cable, no interaction, scriptable:
#   afk.sh setup                 # local keys/config/state only (not device setup)
#   afk.sh up                    # find usb0 host iface, give it 192.168.7.10, wait for SSH
#   afk.sh status | doctor       # is the channel healthy?
#   afk.sh ssh / run / sudo / push / pull
#   afk.sh shot                  # retired KDE path; reports unsupported on GNOME
#   afk.sh logs                  # journal+dmesg+pstore bundle into out/afk/logs/<ts>/
#   afk.sh diag                  # device-side afk-health
#   afk.sh reboot [--wait N]     # remote reboot and wait until SSH is back
#   afk.sh watchdog show|enable|disable
#   afk.sh rdp                   # retired KRDP path; reports unsupported on GNOME
#   afk.sh overlay-install       # legacy KDE deployment; not a GNOME repair method
#   afk.sh repo build|serve      # offline aarch64 RPM repo over the USB link
#   afk.sh dhcp                  # bootstrap DHCP server (first contact only)
#
# Configuration: tools/afk/afk.env (see afk.env.example), or AFK_* environment
# variables.  Everything written goes to out/afk/ (git-ignored).
#
# Docs: tools/afk/README.md
set -euo pipefail

AFK_TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$AFK_TOOLS_DIR/lib/common.sh"

usage() {
    sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Environment (override in tools/afk/afk.env):
  AFK_DEV_HOST     device address        (default 192.168.7.2)
  AFK_HOST_IP      host address          (default 192.168.7.10)
  AFK_DEV_USER     device login user     (legacy image default: user)
  AFK_DEV_PASS     device sudo password  (legacy default is not current credentials)
  AFK_IFACE        force the USB iface   (default: auto-detect by gadget MAC)
  AFK_REPO_PORT    local repo HTTP port  (default 8080)
  AFK_SSH_KEY      host key for the device (default tools/afk/keys/id_ed25519_afk)
EOF
}

# --------------------------------------------------------------- small helpers ---
host_iface_hint() {
    cat <<EOF
  * cable plugged into the host, tablet booted into the installed system
  * 'ip link' should list an interface with MAC $AFK_GADGET_HOST_MAC
    (check: for i in /sys/class/net/*; do echo "\$i \$(cat \$i/address)"; done)
  * if the tablet has no address yet: tools/afk/afk.sh dhcp   (bootstrap DHCP server)
EOF
}

bootstrap_dhcp_background() {  # iface seconds
    local iface="$1" secs="$2"
    have_cmd python3 || { warn "python3 missing; cannot start bootstrap DHCP server"; return 1; }
    if ! have_passwordless_sudo; then
        warn "cannot start bootstrap DHCP server without sudo; run manually:"
        note "   sudo $AFK_TOOLS_DIR/dhcp-serve.py --iface $iface --seconds $secs --host-ip $AFK_HOST_IP"
        return 1
    fi
    note "starting bootstrap DHCP server on $iface for ${secs}s (grants the tablet $AFK_DEV_HOST)"
    sudo -n python3 "$AFK_TOOLS_DIR/dhcp-serve.py" \
        --iface "$iface" --seconds "$secs" --host-ip "$AFK_HOST_IP" \
        --client-ip "$AFK_DEV_HOST" --allow-mac "$AFK_GADGET_DEV_MAC" \
        >"$AFK_STATE_DIR/run/dhcp-serve.log" 2>&1 &
    return 0
}

# --------------------------------------------------------------------- setup ---
cmd_setup() {
    afk_state_init
    section "keys"
    if [ -f "$AFK_SSH_KEY" ]; then
        ok "SSH key present: $AFK_SSH_KEY"
    else
        bash "$AFK_TOOLS_DIR/keys/gen-keys.sh"
    fi
    section "config"
    if [ -f "$AFK_TOOLS_DIR/afk.env" ]; then
        ok "config present: tools/afk/afk.env"
    else
        cp "$AFK_TOOLS_DIR/afk.env.example" "$AFK_TOOLS_DIR/afk.env"
        chmod 0600 "$AFK_TOOLS_DIR/afk.env"
        note "wrote tools/afk/afk.env from the example (git-ignored)"
    fi
    section "host dependencies"
    local missing=0 c
    for c in ssh scp tar python3; do
        if have_cmd "$c"; then ok "$c"; else err "$c missing"; missing=1; fi
    done
    have_passwordless_sudo && ok "passwordless sudo (bootstrap/addr/DHCP available)" \
        || note "sudo needs a password (bootstrap steps will tell you what to run)"
    section "next steps"
    cat <<EOF
Try the existing connection first: tools/afk/afk.sh run 'id'
Current GNOME maintenance: tools/afk/README.md
Do not reinstall the historical KDE overlay or assume the example credentials
match this device. Network setup, device changes and reboot are separate actions.
EOF
}

# ------------------------------------------------------------------------ up ---
cmd_up() {
    afk_state_init
    section "usb link"
    local iface
    if ! iface="$(afk_detect_iface)"; then
        err "no USB NCM interface found (gadget host MAC $AFK_GADGET_HOST_MAC)"
        host_iface_hint
        return 1
    fi
    ok "interface: $iface"
    if ! afk_ensure_host_addr "$iface"; then
        warn "could not assign $AFK_HOST_IP/24 to $iface (needs root once):"
        note "   sudo ip addr replace $AFK_HOST_IP/24 dev $iface"
    else
        ok "host address: $(iface_addr4 "$iface" | tr '\n' ' ')"
    fi

    if port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
        ok "SSH reachable at $AFK_DEV_USER@$AFK_DEV_HOST:22"
    else
        warn "no SSH yet at $AFK_DEV_HOST:22"
        if ! bootstrap_dhcp_background "$iface" 90; then
            note "then retry: tools/afk/afk.sh up"
            return 1
        fi
        local waited=0
        while [ "$waited" -lt 60 ]; do
            if port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
                ok "SSH reachable at $AFK_DEV_USER@$AFK_DEV_HOST:22"
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done
        port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}" || {
            err "still no SSH after bootstrap DHCP"
            note "try the IPv6 link-local fallback: tools/afk/afk.sh ssh --v6"
            note "check the tablet screen: is it booted past the initramfs? any kernel panic?"
            return 1
        }
    fi

    section "authentication"
    if afk_require_key 2>/dev/null && ssh_run "$AFK_DEV_HOST" true 2>/dev/null; then
        ok "key auth works"
    else
        note "key auth not usable; check the current account/key in private afk.env"
        note "see tools/afk/README.md; do not reinstall the old KDE overlay"
    fi
    section "device"
    afk_remote_summary || warn "device summary unavailable (SSH not authenticated yet)"
}

# -------------------------------------------------------------------- status ---
cmd_status() {
    afk_state_init
    section "host side"
    local iface
    if iface="$(afk_detect_iface)"; then
        ok "interface: $iface  mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null)"
        printf '  addr: %s\n' "$(iface_addr4 "$iface" | tr '\n' ' ')"
        printf '  operstate: %s carrier: %s\n' \
            "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" \
            "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"
    else
        err "no USB NCM interface (cable unplugged / tablet not booted?)"
    fi
    section "reachability"
    if port_open "$AFK_DEV_HOST" 22; then
        ok "ssh port open ($AFK_DEV_HOST:22)"
    else
        err "ssh port closed ($AFK_DEV_HOST:22)"
    fi
    section "device side (ssh)"
    afk_remote_summary || { err "ssh not usable"; return 1; }
}

# -------------------------------------------------------------------- doctor ---
cmd_doctor() {
    afk_state_init
    local fails=0 warns=0
    section "host"
    [ -f "$AFK_SSH_KEY" ] && ok "ssh key: $AFK_SSH_KEY" || { err "ssh key missing (afk.sh setup)"; fails=$((fails+1)); }
    for c in ssh scp tar python3; do
        have_cmd "$c" || { err "missing host command: $c"; fails=$((fails+1)); }
    done
    local iface=""
    if iface="$(afk_detect_iface)"; then
        ok "usb iface: $iface"
        iface_addr4 "$iface" | grep -q "^$AFK_HOST_IP/" && ok "host addr $AFK_HOST_IP/24" \
            || { err "host addr $AFK_HOST_IP/24 missing (afk.sh up)"; fails=$((fails+1)); }
    else
        err "no USB NCM interface"; fails=$((fails+1))
    fi
    port_open "$AFK_DEV_HOST" 22 && ok "ssh port open" || { err "ssh port closed"; fails=$((fails+1)); }

    section "device"
    if ssh_run "$AFK_DEV_HOST" true 2>/dev/null; then
        ok "ssh key auth"
        local h
        if h="$(ssh_run "$AFK_DEV_HOST" "cat /var/lib/afk/version 2>/dev/null" 2>/dev/null)" && [ -n "$h" ]; then
            ok "AFK overlay installed (version $h)"
        else
            warn "legacy AFK version marker absent; inspect existing services, do not reinstall overlay"; warns=$((warns+1))
        fi
        # Check the pieces the channel depends on.
        check_remote() {  # check_remote <label> <command>
            local label="$1" cmd="$2"
            if ssh_run "$AFK_DEV_HOST" "$cmd" >/dev/null 2>&1; then ok "$label"; else
                case "$label" in
                    *optional*) ;;
                esac
                err "$label"; fails=$((fails+1))
            fi
        }
        # Pre-install readiness: the device must already have a usb0 address
        # (initramfs or NM-managed DHCP) before overlay-install can be trusted.
        local usb0_addrs
        usb0_addrs="$(ssh_run "$AFK_DEV_HOST" 'ip -4 -o addr show dev usb0 2>/dev/null | awk "{print \$4}" | tr "\n" " "' 2>/dev/null || true)"
        if [ -n "$usb0_addrs" ]; then
            ok "device usb0 address(es): $usb0_addrs"
        else
            warn "device usb0 has no IPv4 address yet (run 'afk.sh up' / bootstrap DHCP first)"; warns=$((warns+1))
        fi
        check_remote "usb0 has $AFK_DEV_HOST/24" "ip -4 addr show dev usb0 | grep -q 'inet $AFK_DEV_HOST/'"
        check_remote "sshd active" "systemctl is-active sshd"
        check_remote "journald persistent" "test -d /var/log/journal"
        check_remote "systemd-pstore active" "systemctl is-active systemd-pstore"
        check_remote "display manager active" "systemctl is-active display-manager"
        check_remote "afk-usb0-dhcp active" "systemctl is-active afk-usb0-dhcp"
        check_remote "NetworkManager leaves usb0 unmanaged" "grep -q 'unmanaged-devices=interface-name:usb0' /etc/NetworkManager/conf.d/90-afk-unmanaged.conf"
        check_remote "afk-usb0-address unit enabled" "systemctl is-enabled afk-usb0-address.service"
        check_remote "afk-usb0-address timer enabled" "systemctl is-enabled afk-usb0-address.timer"
        # Legacy afk-health may still contain KDE fields; do not require KRDP.
        if ssh_run "$AFK_DEV_HOST" "test -x /usr/local/sbin/afk-health" >/dev/null 2>&1; then
            local wd
            wd="$(ssh_run "$AFK_DEV_HOST" '/usr/local/sbin/afk-health 2>/dev/null | grep -E "^watchdog_devices="' 2>/dev/null | cut -d= -f2- || true)"
            [ -n "$wd" ] && note "hardware watchdog devices: $wd" || note "no hardware watchdog device (see afk.sh watchdog)"
        fi
    else
        err "ssh key auth failed"; fails=$((fails+1))
    fi

    section "summary"
    say "failures: $fails  warnings: $warns"
    [ "$fails" -eq 0 ]
}

# ---------------------------------------------------------------- ssh / run ---
cmd_ssh() {
    local v6=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --v6) v6=1; shift ;;
            --host) AFK_DEV_HOST="$2"; shift 2 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    afk_require_key
    if [ "$v6" = 1 ]; then
        local iface; iface="$(afk_detect_iface)" || die "no iface for --v6"
        ssh_run6 "$iface" "$@"
    else
        ssh_interactive "$AFK_DEV_HOST" "$@"
    fi
}

cmd_run() {
    [ $# -gt 0 ] || die "usage: afk.sh run '<command>'"
    afk_require_key
    ssh_run "$AFK_DEV_HOST" "$*"
}

cmd_sudo() {
    [ $# -gt 0 ] || die "usage: afk.sh sudo '<command>'"
    afk_require_key
    remote_sudo_cmd "$*"
}

cmd_push() {
    [ $# -eq 2 ] || die "usage: afk.sh push <local> <remote>"
    afk_require_key
    scp_to "$1" "$2"
}

cmd_pull() {
    [ $# -eq 2 ] || die "usage: afk.sh pull <remote> <local>"
    afk_require_key
    scp_from "$1" "$2"
}

# ------------------------------------------------------------------- screenshot ---
cmd_shot() {
    die "legacy KDE screenshot command retired; current GNOME capture is not implemented (tools/afk/README.md)"
}

# -------------------------------------------------------------------- logs ---
cmd_logs() {
    local since="" use_sudo=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --since) since="${2:?}"; shift 2 ;;
            --since=*) since="${1#*=}"; shift ;;
            --no-sudo) use_sudo=0; shift ;;
            -h|--help) say "usage: afk.sh logs [--since <journal-since>] [--no-sudo]"; return 0 ;;
            *) die "unknown logs argument: $1" ;;
        esac
    done
    afk_state_init
    afk_require_key
    local ts dir
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    dir="$AFK_STATE_DIR/logs/$ts"
    mkdir -p "$dir"
    say "collecting device logs -> $dir"

    local rc=0
    if [ "$use_sudo" = 1 ]; then
        { printf '%s\n' "$AFK_DEV_PASS"; } | \
            ssh_run "$AFK_DEV_HOST" "sudo -S -p '' afk-collect" >"$dir/bundle.tar.gz" 2>"$dir/collect.stderr" || rc=$?
    else
        ssh_run "$AFK_DEV_HOST" "afk-collect" >"$dir/bundle.tar.gz" 2>"$dir/collect.stderr" || rc=$?
    fi
    if [ "$rc" != 0 ] || [ ! -s "$dir/bundle.tar.gz" ]; then
        err "log collection failed (rc=$rc)"
        sed -n '1,5p' "$dir/collect.stderr" >&2 || true
        return 1
    fi
    mkdir -p "$dir/bundle"
    if ! tar -xzf "$dir/bundle.tar.gz" -C "$dir/bundle"; then
        err "could not extract $dir/bundle.tar.gz"
        return 1
    fi
    {
        printf 'collected_at=%s\n' "$ts"
        printf 'device_host=%s\n' "$AFK_DEV_HOST"
        printf 'since=%s\n' "${since:-all}"
    } >"$dir/meta.txt"

    # Compact human summary so afk.sh logs alone is enough to see the shape.
    local boots failed warnings
    boots="$(sed -n 's/^[^=]*=//p' "$dir/bundle/meta/journal-boots.txt" 2>/dev/null | wc -l || true)"
    failed="$(grep -c 'loaded failed' "$dir/bundle/logs/failed-units.txt" 2>/dev/null || true)"
    warnings="$(wc -l <"$dir/bundle/logs/journal-previous-warning.log" 2>/dev/null || true)"
    say "  journal boots in bundle: ${boots:-?}"
    say "  failed unit lines:       ${failed:-0}"
    say "  previous-boot warnings:  ${warnings:-0}"
    say "  pstore:                  $(find "$dir/bundle/logs" -path '*pstore*' -type f 2>/dev/null | wc -l) file(s)"
    say "  latest boot snapshot:    $(find "$dir/bundle/logs/afk/boots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | tail -n1)"
    say "$dir"
}

# --------------------------------------------------------------------- diag ---
cmd_diag() {
    afk_require_key
    if ssh_run "$AFK_DEV_HOST" "test -x /usr/local/sbin/afk-health" 2>/dev/null; then
        ssh_run "$AFK_DEV_HOST" "afk-health"
    else
        warn "afk-health not installed; falling back to a minimal probe"
        ssh_run "$AFK_DEV_HOST" 'set -x; uname -a; ip -4 addr; systemctl --failed --no-legend; journalctl --list-boots --no-pager | tail -n5'
    fi
}

# ------------------------------------------------------------------- reboot ---
cmd_reboot() {
    local wait_secs=180
    while [ $# -gt 0 ]; do
        case "$1" in
            --wait) wait_secs="${2:?}"; shift 2 ;;
            --wait=*) wait_secs="${1#*=}"; shift ;;
            --no-wait) wait_secs=0; shift ;;
            -h|--help) say "usage: afk.sh reboot [--wait SECONDS | --no-wait]"; return 0 ;;
            *) die "unknown reboot argument: $1" ;;
        esac
    done
    afk_require_key
    local before; before="$(ssh_run "$AFK_DEV_HOST" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    [ -n "$before" ] && say "current boot_id: $before"
    say "requesting reboot"
    { printf '%s\n' "$AFK_DEV_PASS"; printf 'sync; systemctl reboot\n'; } | \
        ssh_run "$AFK_DEV_HOST" "sudo -S -p '' bash -s" >/dev/null 2>&1 || \
        note "ssh connection closed by reboot (expected)"
    [ "$wait_secs" -eq 0 ] && { say "not waiting (--no-wait)"; return 0; }

    say "waiting up to ${wait_secs}s for the device to come back"
    local waited=0 back=0
    while [ "$waited" -lt "$wait_secs" ]; do
        sleep 3
        waited=$((waited + 3))
        if port_open "$AFK_DEV_HOST" 22; then
            # Port open is not enough: sshd may still be starting; try a command.
            if ssh_run "$AFK_DEV_HOST" true >/dev/null 2>&1; then back=1; break; fi
        fi
    done
    if [ "$back" != 1 ]; then
        err "device did not come back within ${wait_secs}s"
        cat <<EOF
Recovery guidance (no physical access needed first):
  * if the tablet is mid-boot, wait; inspect the existing link without reconfiguring it
  * check host side:                      tools/afk/afk.sh status
  * retrieve existing journal / snapshots once SSH is back; pstore may be empty
  * if it never returns, the last resort is a long-power-button press or
    an explicitly approved Fastboot recovery with matching Fedora boot/modules.
    B is unverified; restoring an old boot alone does not restore Android.
EOF
        return 1
    fi
    sleep 2
    local after; after="$(ssh_run "$AFK_DEV_HOST" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    ok "device is back in ${waited}s (boot_id: ${after:-unknown})"
    [ -n "$before" ] && [ "$before" = "$after" ] && warn "boot_id unchanged - did the reboot actually happen?"
    section "post-reboot"
    afk_remote_summary || true
}

# ------------------------------------------------------------------ watchdog ---
WATCHDOG_DROPIN_NAME=90-afk-watchdog.conf

cmd_watchdog() {
    local action="${1:-show}"
    case "$action" in
        show|status)
            afk_require_key
            say "== device watchdog state =="
            ssh_run "$AFK_DEV_HOST" 'ls /sys/class/watchdog 2>/dev/null; \
                for w in /sys/class/watchdog/watchdog*; do [ -e "$w/identity" ] && echo "$w: $(cat $w/identity)"; done; \
                systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec; \
                test -f /etc/systemd/system.conf.d/'"$WATCHDOG_DROPIN_NAME"' && echo "systemd drop-in: enabled" || echo "systemd drop-in: disabled"'
            ;;
        enable)
            afk_require_key
            local template="$AFK_ROOT/overlays/afk/files/etc/systemd/system.conf.d/$WATCHDOG_DROPIN_NAME.off"
            [ -f "$template" ] || die "missing template: $template"
            local payload; payload="$(cat "$template")"
            remote_sudo_script <<EOF
install -D -m 0644 /dev/stdin /etc/systemd/system.conf.d/$WATCHDOG_DROPIN_NAME <<'AFK_WD_EOF'
$payload
AFK_WD_EOF
systemctl daemon-reexec
systemctl show -p RuntimeWatchdogUSec
EOF
            ok "watchdog drop-in enabled (takes effect after daemon-reexec; verify HW support with 'show')"
            ;;
        disable)
            afk_require_key
            remote_sudo_script <<EOF
rm -f /etc/systemd/system.conf.d/$WATCHDOG_DROPIN_NAME
systemctl daemon-reexec
systemctl show -p RuntimeWatchdogUSec
EOF
            ok "watchdog drop-in disabled"
            ;;
        *) die "usage: afk.sh watchdog show|enable|disable" ;;
    esac
}

# ---------------------------------------------------------------------- rdp ---
cmd_rdp() {
    die "legacy KRDP command retired; current GNOME remote desktop is not implemented (tools/afk/README.md)"
}

cmd_tunnel() {
    local spec="${1:-}"
    [ -n "$spec" ] || die "usage: afk.sh tunnel <local-port>:<remote-host>:<remote-port>"
    afk_require_key
    say "ssh -N -L $spec (Ctrl-C to close)"
    AFK_SSH_BATCH=0 ssh -N -L "$spec" \
        -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        -i "$AFK_SSH_KEY" -o IdentitiesOnly=yes "$AFK_DEV_USER@$AFK_DEV_HOST"
}

# ---------------------------------------------------------------- overlay ops ---
cmd_overlay_install() { exec bash "$AFK_TOOLS_DIR/install-overlay.sh" "$@"; }
cmd_overlay_uninstall() { exec bash "$AFK_TOOLS_DIR/install-overlay.sh" --uninstall "$@"; }

# --------------------------------------------------------------------- repo ---
cmd_repo() {
    local action="${1:-}"; shift || true
    case "$action" in
        build) exec bash "$AFK_TOOLS_DIR/build-repo.sh" "$@" ;;
        serve) exec bash "$AFK_TOOLS_DIR/serve-repo.sh" "$@" ;;
        *) die "usage: afk.sh repo build|serve [options]" ;;
    esac
}

# --------------------------------------------------------------------- dhcp ---
cmd_dhcp() {
    have_cmd python3 || die "python3 required"
    local iface
    iface="$(afk_detect_iface)" || die "no USB NCM interface found (specify AFK_IFACE or --iface)"
    if ! have_passwordless_sudo; then
        say "starting (sudo will ask for your password once):"
        exec sudo python3 "$AFK_TOOLS_DIR/dhcp-serve.py" --iface "$iface" \
            --host-ip "$AFK_HOST_IP" --client-ip "$AFK_DEV_HOST" \
            --allow-mac "$AFK_GADGET_DEV_MAC" "$@"
    fi
    exec sudo -n python3 "$AFK_TOOLS_DIR/dhcp-serve.py" --iface "$iface" \
        --host-ip "$AFK_HOST_IP" --client-ip "$AFK_DEV_HOST" \
        --allow-mac "$AFK_GADGET_DEV_MAC" "$@"
}

# --------------------------------------------------------------------- main ---
cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
    setup)             cmd_setup "$@" ;;
    up)                cmd_up "$@" ;;
    status)            cmd_status "$@" ;;
    doctor)            cmd_doctor "$@" ;;
    ssh)               cmd_ssh "$@" ;;
    run|exec)          cmd_run "$@" ;;
    sudo)              cmd_sudo "$@" ;;
    push)              cmd_push "$@" ;;
    pull)              cmd_pull "$@" ;;
    shot|screenshot)   cmd_shot "$@" ;;
    logs)              cmd_logs "$@" ;;
    diag|health)       cmd_diag "$@" ;;
    reboot)            cmd_reboot "$@" ;;
    watchdog)          cmd_watchdog "$@" ;;
    rdp|vnc)           cmd_rdp "$@" ;;
    tunnel)            cmd_tunnel "$@" ;;
    overlay-install)   cmd_overlay_install "$@" ;;
    overlay-uninstall) cmd_overlay_uninstall "$@" ;;
    repo)              cmd_repo "$@" ;;
    dhcp)              cmd_dhcp "$@" ;;
    help|-h|--help)    usage ;;
    *) err "unknown command: $cmd"; echo; usage; exit 2 ;;
esac
