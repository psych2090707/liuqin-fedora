#!/bin/bash
# AFK channel (TN0048) — shared host-side helpers.
#
# Sourced by tools/afk/afk.sh, build-overlay.sh, install-overlay.sh,
# build-repo.sh.  Keep this file free of side effects other than loading config
# and defining functions.
#
# Layout convention: AFK_ROOT is the project root (…/Fedora), all state goes to
# $AFK_ROOT/out/afk (git-ignored), all committed tools live in $AFK_ROOT/tools/afk.

# NOTE: this file is sourced, so it must not `set -e` on the caller's behalf.

AFK_TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AFK_ROOT="$(cd -- "$AFK_TOOLS_DIR/../.." && pwd)"

# ------------------------------------------------------------------- config ---
# Committed defaults for the liuqin bring-up device (TN0047/TN0048).
AFK_DEV_HOST="${AFK_DEV_HOST:-192.168.7.2}"
AFK_HOST_IP="${AFK_HOST_IP:-192.168.7.10}"
AFK_DEV_USER="${AFK_DEV_USER:-user}"
AFK_DEV_PASS="${AFK_DEV_PASS:-147147}"          # dev-only image password (docs/STATUS.md)
AFK_REPO_PORT="${AFK_REPO_PORT:-8080}"
# The configfs NCM gadget pins the host-side MAC (initramfs/init sets host_addr).
AFK_GADGET_HOST_MAC="${AFK_GADGET_HOST_MAC:-02:00:00:00:07:01}"
AFK_GADGET_DEV_MAC="${AFK_GADGET_DEV_MAC:-02:00:00:00:07:02}"
# IPv6 link-local that the gadget's fixed device MAC produces (EUI-64).
AFK_DEV_LL="${AFK_DEV_LL:-fe80::200:ff:fe00:702}"

AFK_STATE_DIR="${AFK_STATE_DIR:-$AFK_ROOT/out/afk}"
AFK_SSH_KEY="${AFK_SSH_KEY:-$AFK_TOOLS_DIR/keys/id_ed25519_afk}"
AFK_KNOWN_HOSTS="${AFK_KNOWN_HOSTS:-$AFK_STATE_DIR/known_hosts}"
AFK_RDP_PORT="${AFK_RDP_PORT:-3389}"

# Local, git-ignored overrides (tools/afk/afk.env).
if [ -f "$AFK_TOOLS_DIR/afk.env" ]; then
    # shellcheck disable=SC1090
    . "$AFK_TOOLS_DIR/afk.env"
fi

# OpenSSH tokenises -o values on whitespace, so a state path containing spaces
# (for example a workspace named "Agent Studio") silently loads a truncated
# path such as "$HOME/Agent" as the known_hosts file and rejects the device.
# Route the option through a no-space symlink when needed; the link points at
# the real file, so accept-new still appends to the intended store.
afk_known_hosts_opt() {
    case "$AFK_KNOWN_HOSTS" in
        *[[:space:]]*)
            local dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/liuqin-afk"
            if mkdir -p "$dir" "$(dirname "$AFK_KNOWN_HOSTS")" 2>/dev/null \
               && { [ -e "$AFK_KNOWN_HOSTS" ] || : >"$AFK_KNOWN_HOSTS"; } \
               && chmod 700 "$dir" 2>/dev/null \
               && ln -sfn "$AFK_KNOWN_HOSTS" "$dir/known_hosts" 2>/dev/null; then
                printf '%s\n' "$dir/known_hosts"
            else
                printf '%s\n' "$AFK_KNOWN_HOSTS"
            fi
            ;;
        *) printf '%s\n' "$AFK_KNOWN_HOSTS" ;;
    esac
    return 0
}
AFK_KNOWN_HOSTS_OPT="$(afk_known_hosts_opt)"

# ------------------------------------------------------------------ output ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    AFK_C_RED=$'\033[31m'; AFK_C_YEL=$'\033[33m'; AFK_C_GRN=$'\033[32m'
    AFK_C_BLU=$'\033[36m'; AFK_C_DIM=$'\033[2m'; AFK_C_OFF=$'\033[0m'
else
    AFK_C_RED=; AFK_C_YEL=; AFK_C_GRN=; AFK_C_BLU=; AFK_C_DIM=; AFK_C_OFF=
fi

say()  { printf '%s\n' "$*"; }
note() { printf '%s%s%s\n' "$AFK_C_DIM" "$*" "$AFK_C_OFF"; }
ok()   { printf '%s[ ok ]%s %s\n' "$AFK_C_GRN" "$AFK_C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$AFK_C_YEL" "$AFK_C_OFF" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$AFK_C_RED" "$AFK_C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }
section() { printf '\n%s== %s ==%s\n' "$AFK_C_BLU" "$*" "$AFK_C_OFF"; }

# ------------------------------------------------------------------ state ---
afk_state_init() {
    mkdir -p "$AFK_STATE_DIR"/{shots,logs,repo,run}
}

# --------------------------------------------------------------- host tools ---
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing host command: $1${2:+ ($2)}"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Can we run privileged commands without a prompt?
have_passwordless_sudo() { sudo -n true >/dev/null 2>&1; }

# ------------------------------------------------------------ interface ops ---
# Interfaces whose MAC matches the gadget's host side (02:00:00:00:07:01).
afk_candidate_ifaces() {
    local d mac
    for d in /sys/class/net/*; do
        [ -e "$d/address" ] || continue
        mac="$(cat "$d/address" 2>/dev/null)"
        [ "$mac" = "$AFK_GADGET_HOST_MAC" ] && basename "$d"
    done
}

# Best guess for the device-facing interface:
#   AFK_IFACE override > gadget MAC match > interface with a 192.168.7.x address.
afk_detect_iface() {
    if [ -n "${AFK_IFACE:-}" ]; then
        printf '%s\n' "$AFK_IFACE"
        return 0
    fi
    local iface
    iface="$(afk_candidate_ifaces | head -n1)"
    if [ -n "$iface" ]; then
        printf '%s\n' "$iface"
        return 0
    fi
    iface="$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.7\./ {print $2; exit}')"
    [ -n "$iface" ] && { printf '%s\n' "$iface"; return 0; }
    return 1
}

iface_addr4() {  # iface_addr4 IFACE -> prints addresses, one per line
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}'
}

port_open() {  # port_open HOST PORT -> 0 if TCP connect succeeds (2s timeout)
    local host="$1" port="$2"
    timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

# Make sure the host side of the USB link has $AFK_HOST_IP/24.
# Returns 0 if the address is (now) present, 1 otherwise (no privileges, etc.).
afk_ensure_host_addr() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    if iface_addr4 "$iface" | grep -q "^$AFK_HOST_IP/"; then
        return 0
    fi
    # Maybe NetworkManager already got a lease for it; ask it to retry.
    if have_cmd nmcli; then
        nmcli device reapply "$iface" >/dev/null 2>&1 || true
        sleep 1
        if iface_addr4 "$iface" | grep -q "^$AFK_HOST_IP/"; then
            return 0
        fi
    fi
    if have_passwordless_sudo; then
        sudo -n ip addr replace "$AFK_HOST_IP/24" dev "$iface" >/dev/null 2>&1 || true
        sudo -n ip link set dev "$iface" up >/dev/null 2>&1 || true
        iface_addr4 "$iface" | grep -q "^$AFK_HOST_IP/" && return 0
    fi
    return 1
}

# ------------------------------------------------------------------- ssh layer ---
afk_ssh_opts() {
    printf '%s\n' \
        -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        -o LogLevel=ERROR
}

afk_require_key() {
    if [ ! -f "$AFK_SSH_KEY" ]; then
        die "SSH key not found: $AFK_SSH_KEY (run tools/afk/keys/gen-keys.sh)"
    fi
}

# ssh_run <host> [command...]
# Non-interactive by default (BatchMode=yes) so scripts never hang on a prompt.
ssh_run() {
    local host="$1"; shift
    local batch="${AFK_SSH_BATCH:-1}"
    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(afk_ssh_opts)
    [ "$batch" = 1 ] && opts+=(-o BatchMode=yes)
    local key_opts=()
    [ -f "$AFK_SSH_KEY" ] && key_opts=(-i "$AFK_SSH_KEY" -o IdentitiesOnly=yes)
    mkdir -p "$(dirname "$AFK_KNOWN_HOSTS")"
    # shellcheck disable=SC2086
    ssh "${opts[@]}" "${key_opts[@]}" -p "${AFK_SSH_PORT:-22}" "$AFK_DEV_USER@$host" "$@"
}

# ssh_run6: same, but via the IPv6 link-local address (bootstrap fallback).
ssh_run6() {
    local iface="$1"; shift
    [ "$#" -gt 0 ] || set -- true
    local batch="${AFK_SSH_BATCH:-1}"
    local opts=(-6 -o "BindInterface=$iface" -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT"
                -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
    [ "$batch" = 1 ] && opts+=(-o BatchMode=yes)
    local key_opts=()
    [ -f "$AFK_SSH_KEY" ] && key_opts=(-i "$AFK_SSH_KEY" -o IdentitiesOnly=yes)
    ssh "${opts[@]}" "${key_opts[@]}" "$AFK_DEV_USER@$AFK_DEV_LL%$iface" "$@"
}

# ssh_interactive: real TTY, no BatchMode (for `afk.sh ssh`).
ssh_interactive() {
    local host="$1"; shift
    [ "$#" -gt 0 ] || set -- /bin/bash -l
    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(afk_ssh_opts)
    local key_opts=()
    [ -f "$AFK_SSH_KEY" ] && key_opts=(-i "$AFK_SSH_KEY" -o IdentitiesOnly=yes)
    mkdir -p "$(dirname "$AFK_KNOWN_HOSTS")"
    AFK_SSH_BATCH=0 ssh -t "${opts[@]}" "${key_opts[@]}" "$AFK_DEV_USER@$host" "$@"
}

# scp around the device.
scp_from() {  # scp_from <remote-path> <local-path>
    local opts=(-P "${AFK_SSH_PORT:-22}" -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT"
                -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -q)
    local key_opts=()
    [ -f "$AFK_SSH_KEY" ] && key_opts=(-i "$AFK_SSH_KEY" -o IdentitiesOnly=yes)
    scp "${opts[@]}" "${key_opts[@]}" "$AFK_DEV_USER@$AFK_DEV_HOST:$1" "$2"
}

scp_to() {  # scp_to <local-path> <remote-path>
    local opts=(-P "${AFK_SSH_PORT:-22}" -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT"
                -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -q)
    local key_opts=()
    [ -f "$AFK_SSH_KEY" ] && key_opts=(-i "$AFK_SSH_KEY" -o IdentitiesOnly=yes)
    scp "${opts[@]}" "${key_opts[@]}" "$1" "$AFK_DEV_USER@$AFK_DEV_HOST:$2"
}

# Feed a shell script to the device and execute it through `sudo -S`.
# Usage: remote_sudo_script <<'EOF' ... EOF
# The script is written to a temp file, then password + script are streamed to
# `sudo -S bash -s` so nothing has to be quoted on the remote side.
remote_sudo_script() {
    local script_file
    script_file="$(mktemp "${TMPDIR:-/tmp}/afk-sudo.XXXXXX")"
    cat >"$script_file"
    { printf '%s\n' "$AFK_DEV_PASS"; cat "$script_file"; } | \
        ssh_run "$AFK_DEV_HOST" "sudo -S -p '' bash -s"
    local rc=$?
    rm -f "$script_file"
    return $rc
}

# Run one remote command through sudo, printing its output.
remote_sudo_cmd() {
    { printf '%s\n' "$AFK_DEV_PASS"; printf '%s\n' "$*"; } | \
        ssh_run "$AFK_DEV_HOST" "sudo -S -p '' bash -s"
}

# --------------------------------------------------------------- device state ---
afk_wait_ssh() {  # afk_wait_ssh TIMEOUT_SEC
    local timeout="${1:-60}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# Compact one-line summary, used by `status`/`reboot --wait`.
afk_remote_summary() {
    ssh_run "$AFK_DEV_HOST" "printf 'boot_id=%s\n' \"\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)\"; \
        printf 'uptime_sec=%s\n' \"\$(cut -d' ' -f1 /proc/uptime)\"; \
        printf 'usb0=%s\n' \"\$(ip -4 -o addr show dev usb0 2>/dev/null | awk '{print \$4}')\"; \
        printf 'failed=%s\n' \"\$(systemctl --failed --no-legend 2>/dev/null | wc -l)\"; \
        printf 'journal=%s\n' \"\$(journalctl --disk-usage 2>/dev/null | sed 's/.*take up //')\"; \
        printf 'display_manager=%s\n' \"\$(systemctl is-active display-manager 2>/dev/null)\"" 2>/dev/null
}

# --------------------------------------------------- password-auth SSH (bootstrap) ---
# First contact happens before the AFK public key is installed on the device, so
# the tooling must be able to use the dev password without an interactive
# prompt (scripts must never hang).  OpenSSH can be fed a password through
# SSH_ASKPASS; SSH_ASKPASS_REQUIRE=force makes it use it even when a tty exists.
AFK_ASKPASS_FILE=""
afk_askpass() {
    if [ -z "$AFK_ASKPASS_FILE" ] || [ ! -x "$AFK_ASKPASS_FILE" ]; then
        AFK_ASKPASS_FILE="$(mktemp "${TMPDIR:-/tmp}/afk-askpass.XXXXXX")"
        chmod 0700 "$AFK_ASKPASS_FILE"
        # %q shell-quotes the password, so the generated script prints it verbatim.
        printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$(printf '%q' "$AFK_DEV_PASS")" >"$AFK_ASKPASS_FILE"
        chmod 0700 "$AFK_ASKPASS_FILE"
    fi
    printf '%s\n' "$AFK_ASKPASS_FILE"
}

# ssh_run_password <host> [command...] — like ssh_run but password auth, non-interactive.
ssh_run_password() {
    local host="$1"; shift
    local askpass opts
    askpass="$(afk_askpass)"
    opts=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o NumberOfPasswordPrompts=1 -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT"
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5
          -o LogLevel=ERROR)
    mkdir -p "$(dirname "$AFK_KNOWN_HOSTS")"
    SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force setsid -w ssh "${opts[@]}" \
        -p "${AFK_SSH_PORT:-22}" "$AFK_DEV_USER@$host" "$@"
}

scp_password_from() {
    local askpass opts
    askpass="$(afk_askpass)"
    opts=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o NumberOfPasswordPrompts=1 -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT"
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -q)
    SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force setsid -w scp "${opts[@]}" \
        -P "${AFK_SSH_PORT:-22}" "$AFK_DEV_USER@$AFK_DEV_HOST:$1" "$2"
}

scp_password_to() {
    local askpass opts
    askpass="$(afk_askpass)"
    opts=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o NumberOfPasswordPrompts=1 -o "UserKnownHostsFile=$AFK_KNOWN_HOSTS_OPT"
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -q)
    SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force setsid -w scp "${opts[@]}" \
        -P "${AFK_SSH_PORT:-22}" "$1" "$AFK_DEV_USER@$AFK_DEV_HOST:$2"
}
