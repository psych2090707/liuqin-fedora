#!/bin/bash
# AFK channel (TN0048) — push the AFK overlay to the device and install it.
#
#   tools/afk/install-overlay.sh --dry-run          # show what would change
#   tools/afk/install-overlay.sh                    # real install (backs up first)
#   tools/afk/install-overlay.sh --rpms             # + offline RPM bundle (if built)
#   tools/afk/install-overlay.sh --uninstall        # remove overlay-owned files
#
# Requires the SSH channel (run tools/afk/afk.sh up first) and the device's dev
# password for sudo (AFK_DEV_PASS, dev-only image).
#
# Everything after `--` is passed to the device-side install.sh unchanged.
set -euo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

TARBALL=""
RPMS_DIR=""
USE_RPMS=auto        # auto = use out/afk/repo/rpms when it exists
REPO_URL=""
FOREGROUND=0
PASSTHRU=()

while [ $# -gt 0 ]; do
    case "$1" in
        --tarball) TARBALL="${2:?}"; shift 2 ;;
        --tarball=*) TARBALL="${1#*=}"; shift ;;
        --rpms)
            if [ $# -ge 2 ] && [ "$2" != "--" ] && [ "${2#--}" = "$2" ]; then
                RPMS_DIR="$2"; shift 2
            else
                USE_RPMS=yes; shift
            fi
            ;;
        --rpms=*) RPMS_DIR="${1#*=}"; USE_RPMS=yes; shift ;;
        --no-rpms) USE_RPMS=no; shift ;;
        --foreground) FOREGROUND=1; shift ;;
        --repo) REPO_URL="${2:?}"; shift 2 ;;
        --repo=*) REPO_URL="${1#*=}"; shift ;;
        --help|-h)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --) shift; PASSTHRU+=("$@"); break ;;
        *) PASSTHRU+=("$1"); shift ;;
    esac
done

afk_state_init
# Bootstrap-friendly: generate the key on the host if this is the very first run
# (`tools/afk/afk.sh setup` does this too, but a bare overlay-install should not
# require it before falling back to password auth below).
if [ ! -f "$AFK_SSH_KEY" ]; then
    bash "$TOOLS_DIR/keys/gen-keys.sh" >&2 || warn "could not generate the AFK key; will use password auth"
fi

if ! port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
    die "device SSH port is closed at $AFK_DEV_HOST; run tools/afk/afk.sh up first"
fi
# First contact happens before authorized_keys exists on the device: pick the
# auth mode once, then use wraps everywhere so scripts never prompt.
AUTH_MODE=key
if ! ssh_run "$AFK_DEV_HOST" true >/dev/null 2>&1; then
    if ssh_run_password "$AFK_DEV_HOST" true >/dev/null 2>&1; then
        AUTH_MODE=password
        warn "SSH key auth not installed yet; using the dev password (askpass) for this run"
    else
        die "neither key nor password SSH works; run tools/afk/afk.sh up and check the device"
    fi
fi
ssh_x() { if [ "$AUTH_MODE" = key ]; then ssh_run "$@"; else ssh_run_password "$@"; fi; }
scp_x_to() { if [ "$AUTH_MODE" = key ]; then scp_to "$1" "$2"; else scp_password_to "$1" "$2"; fi; }
scp_x_from() { if [ "$AUTH_MODE" = key ]; then scp_from "$1" "$2"; else scp_password_from "$1" "$2"; fi; }

# ------------------------------------------------------------------ preflight ---
# The whole install rides on usb0.  Show the device's current usb0 address and
# whether the overlay has already pinned it: if the address is missing, fix the
# link (tools/afk/afk.sh up / bootstrap DHCP) BEFORE touching the device config.
say "preflight: device usb0 state"
usb0_report="$(ssh_x "$AFK_DEV_HOST" 'ip -4 -o addr show dev usb0 2>/dev/null || echo "usb0: no IPv4 address"' 2>/dev/null || true)"
printf '%s\n' "$usb0_report"
case "$usb0_report" in
    *"no IPv4 address"*|"")
        warn "device usb0 has no IPv4 address; the install will configure it, but the"
        warn "current SSH session must survive until then - consider 'tools/afk/afk.sh up' first" ;;
esac
if ssh_x "$AFK_DEV_HOST" "test -f /var/lib/afk/version" >/dev/null 2>&1; then
    say "preflight: an AFK overlay is already installed (version $(ssh_x "$AFK_DEV_HOST" 'cat /var/lib/afk/version' 2>/dev/null)); this run upgrades/repairs it"
fi

# ------------------------------------------------------------------- tarball ---
if [ -z "$TARBALL" ]; then
    say "building overlay tarball"
    TARBALL="$(bash "$TOOLS_DIR/build-overlay.sh")"
fi
[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"
say "tarball: $TARBALL"

remote_tar="/tmp/$(basename "$TARBALL")"
remote_dir="/tmp/afk-overlay"
say "uploading to $AFK_DEV_HOST:$remote_tar"
scp_x_to "$TARBALL" "$remote_tar"
if [ -f "$TARBALL.sha256" ]; then
    scp_x_to "$TARBALL.sha256" "$remote_tar.sha256"
fi

ssh_x "$AFK_DEV_HOST" "rm -rf '$remote_dir' && mkdir -p '$remote_dir' && tar -xzf '$remote_tar' -C '$remote_dir' && echo extracted"

INSTALLER="$(ssh_x "$AFK_DEV_HOST" "ls -d '$remote_dir'/afk-overlay-*/install.sh 2>/dev/null | head -n1")"
[ -n "$INSTALLER" ] || die "install.sh not found inside the uploaded tarball"

# ------------------------------------------------------------------- rpm bundle ---
args=()
if [ -n "$RPMS_DIR" ]; then
    :
elif [ "$USE_RPMS" = auto ] || [ "$USE_RPMS" = yes ]; then
    if [ -d "$AFK_STATE_DIR/repo/rpms" ] && ls "$AFK_STATE_DIR/repo/rpms/"*.rpm >/dev/null 2>&1; then
        RPMS_DIR="$AFK_STATE_DIR/repo/rpms"
    elif [ "$USE_RPMS" = yes ]; then
        die "no RPMs at $AFK_STATE_DIR/repo/rpms; run tools/afk/afk.sh repo build first"
    fi
fi

if [ -n "$RPMS_DIR" ]; then
    [ -d "$RPMS_DIR" ] || die "RPM directory not found: $RPMS_DIR"
    say "packing offline RPMs from $RPMS_DIR"
    rpm_tar="/tmp/afk-rpms.tar.gz"
    tar -czf "$rpm_tar" -C "$RPMS_DIR" .
    scp_x_to "$rpm_tar" "/tmp/afk-rpms.tar.gz"
    ssh_x "$AFK_DEV_HOST" "rm -rf /tmp/afk-rpms && mkdir -p /tmp/afk-rpms && tar -xzf /tmp/afk-rpms.tar.gz -C /tmp/afk-rpms && ls /tmp/afk-rpms | wc -l"
    rm -f "$rpm_tar"
    args+=(--rpms /tmp/afk-rpms)
elif [ -n "$REPO_URL" ]; then
    args+=(--repo "$REPO_URL")
fi

# Installer options the host understands; everything else is passed through.
if [ -n "$REPO_URL" ] && [[ " ${args[*]+"${args[*]}"} " != *" --repo "* ]]; then
    args+=(--repo "$REPO_URL")
fi
args+=("${PASSTHRU[@]+"${PASSTHRU[@]}"}")

# The installer deliberately makes usb0 NetworkManager-unmanaged and re-pins
# the address early.  On the very first install NetworkManager may own the
# current usb0 address, so that switch can bounce the SSH session the installer
# is running in.  Therefore the default is to run it detached (setsid --fork)
# with its output on the device, then poll for the exit code and fetch the log:
# a dropped SSH connection then cannot kill a half-finished install.
run_installer_detached() {
    local ts remote_log remote_rc launcher
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    remote_log="/var/log/afk/install-$ts.log"
    remote_rc="/tmp/afk-install-$ts.rc"
    launcher="/tmp/afk-run-install-$ts.sh"

    say "launching (detached on the device); log: $remote_log"
    {
        echo '#!/bin/bash'
        echo 'set -u'
        # The log directory does not exist on a first install, and exec would
        # prevent the completion marker below from ever being written.
        echo 'mkdir -p /var/log/afk || exit 1'
        printf 'bash %q' "$INSTALLER"
        if [ ${#args[@]} -gt 0 ]; then printf ' %q' "${args[@]}"; fi
        printf ' >%q 2>&1\n' "$remote_log"
        echo 'echo $? >"'$remote_rc'"'
    } >/tmp/afk-launcher.$$ 2>/dev/null || die "cannot write a local launcher"
    printf '%s\n' "$(cat /tmp/afk-launcher.$$)" | ssh_x "$AFK_DEV_HOST" "cat > $launcher" || die "could not upload the launcher"
    rm -f /tmp/afk-launcher.$$

    { printf '%s\n' "$AFK_DEV_PASS"; } | \
        ssh_x "$AFK_DEV_HOST" "sudo -S -p '' setsid --fork bash $launcher >/dev/null 2>&1; echo launched" \
        || warn "SSH connection dropped while launching (expected if NM released usb0); still polling"

    local waited=0 timeout=900 rc=""
    while [ "$waited" -lt "$timeout" ]; do
        sleep 3
        waited=$((waited + 3))
        if ! port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
            if [ $((waited % 30)) -lt 3 ]; then say "  waiting for the device to come back (${waited}s)"; fi
            continue
        fi
        # The installer may have just added our public key (and possibly
        # disabled password auth) mid-run: upgrade the auth mode as soon as key
        # auth works, so polling keeps working either way.
        if [ "$AUTH_MODE" = password ] && ssh_run "$AFK_DEV_HOST" true >/dev/null 2>&1; then
            AUTH_MODE=key
            say "key auth is now available; switching the poll loop to it"
        fi
        rc="$(ssh_x "$AFK_DEV_HOST" "cat $remote_rc 2>/dev/null" 2>/dev/null || true)"
        if [ -n "$rc" ]; then
            break
        fi
    done

    local local_log="$AFK_STATE_DIR/logs/install-$(basename "$remote_log")"
    mkdir -p "$AFK_STATE_DIR/logs"
    if port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
        scp_x_from "$remote_log" "$local_log" 2>/dev/null && say "device log: $local_log"
    fi
    if [ -z "$rc" ]; then
        warn "installer did not report completion within ${timeout}s"
        [ -f "$local_log" ] && tail -n 20 "$local_log"
        return 1
    fi
    [ -f "$local_log" ] && cat "$local_log"
    say "device installer exit code: $rc"
    if [ "$rc" != 0 ]; then
        err "device installer failed; log: ${local_log:-device $remote_log}"
        return "$rc"
    fi
    return 0
}

if [ "$FOREGROUND" = 1 ] || [[ " ${PASSTHRU[*]+"${PASSTHRU[*]}"} " == *" --dry-run "* ]]; then
    say "running device installer: install.sh ${args[*]+"${args[*]}"} (foreground)"
    say "---------------------------------------------"
    rc=0
    { printf '%s\n' "$AFK_DEV_PASS"; } | \
        ssh_x "$AFK_DEV_HOST" "sudo -S -p '' bash '$INSTALLER' ${args[*]+"${args[*]}"}" || rc=$?
    say "---------------------------------------------"
    if [ "$rc" != 0 ]; then
        err "device installer exited $rc (see the output above; it is idempotent, safe to rerun)"
        exit "$rc"
    fi
else
    run_installer_detached || exit $?
fi

# The installer activates the static usb0 NetworkManager profile last, which can
# bounce the SSH session it is running in.  Wait for it to come back.
if ! port_open "$AFK_DEV_HOST" "${AFK_SSH_PORT:-22}"; then
    say "waiting for SSH to return after the network change"
    afk_wait_ssh 60 || warn "SSH did not return within 60s; re-run tools/afk/afk.sh up"
fi

say ""
say "overlay installed. Verify:"
say "  tools/afk/afk.sh doctor"
say "  tools/afk/afk.sh reboot --wait 240   # applies autologin + KRDP user units"
exit 0
