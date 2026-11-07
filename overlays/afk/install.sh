#!/bin/bash
# AFK channel — device-side overlay installer.
#
# Runs ON THE TABLET as root (normally: tools/afk/install-overlay.sh pushes this
# tarball over SSH and executes it through sudo).  Idempotent, backs up every
# file it replaces, and supports --dry-run / --uninstall.
#
# It configures, in this order:
#   packages (offline RPMs or the host's local repo)
#   /etc files (systemd units, NM profile, sshd + journald drop-ins, plasmalogin
#     autologin, XDG defaults for krfb/krdp/powerdevil/kscreenlocker)
#   /usr/local/sbin helpers (afk-health, afk-shot, afk-collect, afk-boot-snapshot,
#     afk-krdp-preauth)
#   user state (authorized_keys, krdp TLS identity, user-unit symlinks, groups)
#   services (journald persistent, DHCP, boot snapshots, optional watchdog/firewall)
#   sshd reload, and NetworkManager last (activating the static usb0 profile can
#   briefly interrupt the very SSH session this script runs in).
#
# Docs: tools/afk/README.md
set -euo pipefail

VERSION_DEFAULT="1"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SELF_DIR/files"
PUBKEY_FILE="$SELF_DIR/afk-pubkey.txt"
OVERLAY_VERSION="$(cat "$SELF_DIR/VERSION" 2>/dev/null || echo "$VERSION_DEFAULT")"

DEV_USER="${AFK_DEV_USER:-user}"
DEV_HOME="$(getent passwd "$DEV_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "${DEV_HOME:-}" ] || DEV_HOME="/home/$DEV_USER"
DEV_UID="$(id -u "$DEV_USER" 2>/dev/null || echo 1000)"

STATE_DIR=/var/lib/afk
LOG_DIR=/var/log/afk
BACKUP_ROOT="$STATE_DIR/backup"
MANIFEST="$STATE_DIR/files.manifest"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

DRY_RUN=0
DO_UNINSTALL=0
ENABLE_WATCHDOG=0
ENABLE_FIREWALL=0
NO_PASSWORD_AUTH=0
SKIP_PACKAGES=0
NO_SERVICES=0
RESTART_DM=0
RPMS_DIR=""
REPO_URL=""

say()  { printf 'afk-install: %s\n' "$*"; }
warn() { printf 'afk-install: WARN: %s\n' "$*" >&2; }
die()  { printf 'afk-install: ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: install.sh [options]

Device-side installer for the AFK channel overlay. Must run as root.

Options:
  --rpms DIR              install missing RPMs from DIR (offline bundle, one rpm -Uvh transaction)
  --repo URL              install required packages with dnf5 --repofrompath=afk,URL
  --skip-packages         do not install packages (they must already be present)
  --watchdog              enable the systemd hardware watchdog drop-in (default: off)
  --firewall              install+enable the nftables usb0 restriction (default: off)
  --no-password-auth      sshd drop-in with PasswordAuthentication no (key-only)
  --restart-dm            restart plasmalogin at the end (drops any running session!)
  --no-services           only lay down files/packages (image build, chroot tests; no systemctl/nmcli)
  --dry-run               print what would happen, change nothing
  --uninstall             remove overlay-owned files and restore backups
  -h, --help              this help

Environment:
  AFK_DEV_USER            device user (default: user)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rpms)           RPMS_DIR="${2:?--rpms needs a directory}"; shift 2 ;;
        --rpms=*)         RPMS_DIR="${1#*=}"; shift ;;
        --repo)           REPO_URL="${2:?--repo needs a URL}"; shift 2 ;;
        --repo=*)         REPO_URL="${1#*=}"; shift ;;
        --skip-packages)  SKIP_PACKAGES=1; shift ;;
        --watchdog)       ENABLE_WATCHDOG=1; shift ;;
        --firewall)       ENABLE_FIREWALL=1; shift ;;
        --no-password-auth) NO_PASSWORD_AUTH=1; shift ;;
        --restart-dm)     RESTART_DM=1; shift ;;
        --no-services)    NO_SERVICES=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --uninstall)      DO_UNINSTALL=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "afk-install: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------- preconditions ---
[ "$(id -u)" = 0 ] || die "must run as root (use tools/afk/install-overlay.sh, or sudo)"
[ -d "$FILES_DIR" ] || die "missing overlay payload: $FILES_DIR"
command -v systemctl >/dev/null || die "systemd is required"
if ! id "$DEV_USER" >/dev/null 2>&1; then
    die "device user '$DEV_USER' does not exist (AFK_DEV_USER overrides)"
fi

run() {  # run a command unless --dry-run
    if [ "$DRY_RUN" = 1 ]; then
        printf 'DRY-RUN: %s\n' "$*"
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------- protected paths ---
# The initramfs admission gate validates the booted rootfs by these files
# (initramfs/init: /etc/liuqin-fedora-root, /etc/liuqin-fedora-root.contract,
# /etc/liuqin/image-contract).  The AFK overlay must never create, replace or
# remove them: a damaged admission topology would send the next boot to rescue.
is_protected_path() {
    case "$1" in
        /etc/liuqin|/etc/liuqin/*|/etc/liuqin-fedora-root|/etc/liuqin-fedora-root.*)
            return 0 ;;
        *) return 1 ;;
    esac
}

guard_path() {
    if is_protected_path "$1"; then
        die "refusing to touch admission topology file: $1"
    fi
}

# -------------------------------------------------------------- backup helpers ---
backup_path() {
    local p="$1"
    [ "$DRY_RUN" != 1 ] || return 0
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
        return 0
    fi
    local dest="$BACKUP_ROOT/$TIMESTAMP$p"
    mkdir -p "$(dirname -- "$dest")"
    cp -a -- "$p" "$dest"
    printf '%s\n' "$p" >>"$BACKUP_ROOT/$TIMESTAMP.manifest"
}

record_installed() {
    [ "$DRY_RUN" != 1 ] || return 0
    printf '%s\n' "$1" >>"$MANIFEST.new"
}

# -------------------------------------------------------------- package install ---
package_names() {
    # Keep in sync with tools/afk/packages.txt (the tarball carries this list).
    local list="$SELF_DIR/packages.txt"
    if [ -f "$list" ]; then
        grep -v '^[[:space:]]*#' "$list" | grep -v '^[[:space:]]*$' | tr '\n' ' '
    else
        echo "krdp dnsmasq openssl dnf5"
    fi
}

install_packages() {
    [ "$SKIP_PACKAGES" = 1 ] && { warn "package installation skipped (--skip-packages)"; return 0; }

    if [ -n "$RPMS_DIR" ]; then
        [ -d "$RPMS_DIR" ] || die "--rpms directory not found: $RPMS_DIR"
        local missing=() rpm name
        for rpm in "$RPMS_DIR"/*.rpm; do
            [ -e "$rpm" ] || continue
            name="$(rpm -qp --qf '%{NAME}\n' "$rpm" 2>/dev/null | head -n1 || true)"
            [ -n "$name" ] || { warn "cannot read RPM header: $rpm"; continue; }
            if rpm -q --quiet "$name" 2>/dev/null; then
                continue
            fi
            missing+=("$rpm")
        done
        if [ ${#missing[@]} -eq 0 ]; then
            say "all offline RPMs are already installed"
        else
            say "installing ${#missing[@]} offline RPM(s) in one transaction"
            if [ "$DRY_RUN" = 1 ]; then
                printf 'DRY-RUN: rpm -Uvh %s\n' "${missing[*]}"
            else
                rpm -Uvh --oldpackage "${missing[@]}" || die "rpm transaction failed (missing dependency outside the bundle?)"
            fi
        fi
        return 0
    fi

    if [ -n "$REPO_URL" ]; then
        command -v dnf5 >/dev/null || command -v dnf >/dev/null || die "no dnf5/dnf for --repo (install the offline RPM bundle first)"
        local dnf_bin; dnf_bin="$(command -v dnf5 || command -v dnf)"
        run "$dnf_bin" --repofrompath=afk,"$REPO_URL" --setopt=afk.gpgcheck=0 \
            --setopt=install_weak_deps=False install -y $(package_names) \
            || die "dnf install from $REPO_URL failed"
        return 0
    fi

    warn "no --rpms/--repo given; assuming packages are already installed"
}

# ---------------------------------------------------------------- file staging ---
# Build the tree of files that applies for the selected options.  Files shipped
# with an ".off" suffix (watchdog) and opt-in units are only staged on request.
stage_files() {
    local stage="$1"
    rm -rf -- "$stage"
    mkdir -p -- "$stage"
    cp -a -- "$FILES_DIR/." "$stage/"

    # Opt-in pieces.
    if [ "$ENABLE_WATCHDOG" = 1 ]; then
        mv -- "$stage/etc/systemd/system.conf.d/90-afk-watchdog.conf.off" \
              "$stage/etc/systemd/system.conf.d/90-afk-watchdog.conf"
    else
        rm -f -- "$stage/etc/systemd/system.conf.d/90-afk-watchdog.conf.off"
    fi
    if [ "$ENABLE_FIREWALL" != 1 ]; then
        rm -f -- "$stage/etc/systemd/system/afk-firewall.service"
    fi

    if [ "$NO_PASSWORD_AUTH" = 1 ]; then
        sed -i 's/^PasswordAuthentication yes$/PasswordAuthentication no/' \
            "$stage/etc/ssh/sshd_config.d/90-afk.conf"
    fi
}

install_tree() {
    local stage="$1" rel src dest parent
    while IFS= read -r -d '' src; do
        # src is an absolute path under $stage; strip the stage prefix *and* its
        # slash so dest is a single-slash absolute path (never "//etc/...").
        rel="${src#"$stage"/}"
        dest="/$rel"
        guard_path "$dest"
        if [ -L "$src" ]; then
            backup_path "$dest"
            local target; target="$(readlink -- "$src")"
            # install -D creates parents for regular files; symlinks need it here.
            [ "$DRY_RUN" = 1 ] || mkdir -p "$(dirname -- "$dest")"
            run ln -sfn -- "$target" "$dest"
            record_installed "$dest"
        elif [ -f "$src" ]; then
            local mode; mode="$(stat -c '%a' -- "$src")"
            backup_path "$dest"
            if [ "$DRY_RUN" = 1 ]; then
                printf 'DRY-RUN: install -D -m %s %s %s\n' "$mode" "$src" "$dest"
            else
                install -D -m "$mode" -o root -g root -- "$src" "$dest"
            fi
            record_installed "$dest"
        fi
        # install -D runs as root, but KDE must be able to update its own user
        # units and configuration. Only adjust the paths this overlay installs
        # and their parents inside DEV_HOME, never recursively chown the home.
        if [[ "$dest" = "$DEV_HOME/"* ]]; then
            run chown -h "$DEV_USER:$DEV_USER" "$dest"
            parent="$(dirname -- "$dest")"
            while [[ "$parent" = "$DEV_HOME/"* ]] || [ "$parent" = "$DEV_HOME" ]; do
                run chown "$DEV_USER:$DEV_USER" "$parent"
                [ "$parent" != "$DEV_HOME" ] || break
                parent="$(dirname -- "$parent")"
            done
        fi
    done < <(find "$stage" \( -type f -o -type l \) -print0)
}

# ------------------------------------------------------------------- user state ---
provision_user() {
    local ssh_dir="$DEV_HOME/.ssh" authorized="$DEV_HOME/.ssh/authorized_keys"

    run install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$ssh_dir"

    if [ -s "$PUBKEY_FILE" ]; then
        local key; key="$(head -n1 "$PUBKEY_FILE")"
        if [ "$DRY_RUN" = 1 ]; then
            printf 'DRY-RUN: append AFK key to %s\n' "$authorized"
        else
            touch "$authorized"
            if ! grep -qxF -- "$key" "$authorized"; then
                printf '%s\n' "$key" >>"$authorized"
                say "added AFK public key to $authorized"
            else
                say "AFK public key already present in $authorized"
            fi
            chown "$DEV_USER:$DEV_USER" "$authorized"
            chmod 0600 "$authorized"
        fi
    else
        warn "no afk-pubkey.txt in the bundle; SSH key auth will be unavailable"
    fi

    # Unprivileged reads for the log collector + systemd-journal access.
    run usermod -aG systemd-journal,adm "$DEV_USER" || warn "could not add $DEV_USER to systemd-journal/adm"

    # krdp TLS identity (RDP/NLA). krdp self-generates one if this fails.
    # install -d only assigns ownership to its final directory. Ensure the
    # parents it may create, and the portal permission database, are writable
    # by the session user as well.
    run install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" \
        "$DEV_HOME/.local" "$DEV_HOME/.local/share"
    run install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" \
        "$DEV_HOME/.local/share/flatpak/db"
    local cert_dir="$DEV_HOME/.local/share/krdpserver"
    run install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$cert_dir"
    if [ -s "$cert_dir/krdp.crt" ] && [ -s "$cert_dir/krdp.key" ]; then
        say "krdp TLS identity already present"
    elif command -v openssl >/dev/null 2>&1; then
        if [ "$DRY_RUN" = 1 ]; then
            printf 'DRY-RUN: openssl req -nodes -new -x509 ... in %s\n' "$cert_dir"
        else
            runuser -u "$DEV_USER" -- openssl req -nodes -new -x509 \
                -keyout "$cert_dir/krdp.key" -out "$cert_dir/krdp.crt" \
                -days 3650 -subj "/CN=liuqin-afk" -batch >>"$LOG_DIR/openssl.log" 2>&1 \
                && chmod 0600 "$cert_dir/krdp.key" \
                && say "generated krdp TLS identity in $cert_dir" \
                || warn "openssl certificate generation failed; krdp will self-generate"
        fi
    else
        warn "openssl not installed; krdp will self-generate a certificate"
    fi
}

# --------------------------------------------------------------------- services ---
apply_systemd() {
    if [ "$NO_SERVICES" = 1 ]; then
        say "--no-services: skipping systemd enable/journald restart"
        run install -d -m 2755 -o root -g systemd-journal /var/log/journal 2>/dev/null \
            || run mkdir -p /var/log/journal
        return 0
    fi
    run systemctl daemon-reload

    # If the base image already ships the product USB link/DHCP units, do not
    # enable a second address/DHCP owner.  The AFK channel then only adds its
    # maintenance tooling on top of liuqin-usb0-link/dhcp.
    if run systemctl cat liuqin-usb0-link.service >/dev/null 2>&1; then
        say "product liuqin-usb0-link/dhcp present; skipping AFK USB address/DHCP units"
        run systemctl disable --now afk-usb0-dhcp.service >/dev/null 2>&1 || true
        run systemctl disable --now afk-usb0-address.timer >/dev/null 2>&1 || true
        run systemctl disable --now afk-usb0-address.service >/dev/null 2>&1 || true
    else
        run systemctl enable afk-usb0-address.service >/dev/null 2>&1 || warn "could not enable afk-usb0-address.service"
        run systemctl enable afk-usb0-address.timer >/dev/null 2>&1 || warn "could not enable afk-usb0-address.timer"
        run systemctl enable afk-usb0-dhcp.service >/dev/null 2>&1 || warn "could not enable afk-usb0-dhcp.service"
    fi
    run systemctl enable afk-boot-snapshot.service >/dev/null 2>&1 || warn "could not enable afk-boot-snapshot.service"
    run systemctl enable afk-shutdown-snapshot.service >/dev/null 2>&1 || warn "could not enable afk-shutdown-snapshot.service"
    run systemctl enable systemd-pstore.service >/dev/null 2>&1 || warn "could not enable systemd-pstore.service"

    if [ "$ENABLE_FIREWALL" = 1 ]; then
        run systemctl enable afk-firewall.service >/dev/null 2>&1 || warn "could not enable afk-firewall.service"
    fi

    # Journald: create the persistent directory with the layout systemd expects,
    # then restart so the drop-in takes effect and flush /run into /var.
    run install -d -m 2755 -o root -g systemd-journal /var/log/journal 2>/dev/null \
        || run mkdir -p /var/log/journal
    run systemctl restart systemd-journald
    run journalctl --flush >/dev/null 2>&1 || true

    # DHCP server for the host side (needs usb0; harmless if absent).  Skip it
    # when the product liuqin-usb0-dhcp unit already owns the link.
    if ! run systemctl cat liuqin-usb0-link.service >/dev/null 2>&1; then
        run systemctl restart afk-usb0-dhcp.service 2>/dev/null || \
            warn "afk-usb0-dhcp.service did not start (usb0 missing or dnsmasq not installed)"
    fi

    if [ "$RESTART_DM" = 1 ]; then
        warn "restarting plasmalogin (any running Plasma session is terminated)"
        run systemctl restart plasmalogin.service || warn "plasmalogin restart failed"
    fi
}

apply_sshd() {
    if [ "$NO_SERVICES" = 1 ]; then
        say "--no-services: skipping sshd reload (config still validated below)"
        command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A >/dev/null 2>&1 || true
        if command -v sshd >/dev/null 2>&1 && sshd -t 2>"$LOG_DIR/sshd-config-test.err"; then
            say "sshd -t accepts the installed config"
        else
            warn "sshd -t failed: $(head -n3 "$LOG_DIR/sshd-config-test.err" 2>/dev/null)"
        fi
        return 0
    fi
    command -v sshd >/dev/null 2>&1 || { warn "sshd not installed"; return 0; }
    if [ "$DRY_RUN" = 1 ]; then
        printf 'DRY-RUN: ssh-keygen -A; sshd -t; systemctl reload sshd\n'
        return 0
    fi
    ssh-keygen -A >/dev/null 2>&1 || true
    if ! sshd -t 2>"$LOG_DIR/sshd-config-test.err"; then
        warn "sshd config test failed: $(cat "$LOG_DIR/sshd-config-test.err" 2>/dev/null | head -n3)"
        warn "NOT reloading sshd; fix /etc/ssh/sshd_config.d/90-afk.conf and run: systemctl reload sshd"
        return 0
    fi
    systemctl reload sshd 2>/dev/null || systemctl restart sshd || warn "sshd reload failed"
    say "sshd reloaded (key + password auth as configured)"
}

# Make usb0 reachable *before* anything risky (packages, KRDP, certificates).
# This is the first thing that runs after the files are laid down, because the
# whole AFK channel (and the operator's only way in) depends on it.
apply_network_early() {
    if [ "$NO_SERVICES" = 1 ]; then
        say "--no-services: skipping NetworkManager unmanage + address pinning"
        return 0
    fi
    # 1. Tell NetworkManager to leave usb0 alone (90-afk-unmanaged.conf).  NM
    #    reads conf.d on reload; reloading drops the NM-managed usb0 profile and
    #    can flush the address, so the address is re-asserted immediately after.
    run systemctl daemon-reload >/dev/null 2>&1 || true
    if command -v NetworkManager >/dev/null 2>&1 || systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
        run systemctl reload NetworkManager >/dev/null 2>&1 || true
        run nmcli general reload conf >/dev/null 2>&1 || run nmcli connection reload >/dev/null 2>&1 || true
    fi
    # 2. Pin 192.168.7.2/24 and bring the link up (idempotent).
    run systemctl start afk-usb0-address.service 2>/dev/null || {
        # Unit may not be known yet if --no-services/daemon-reload was skipped.
        [ -x /usr/local/sbin/afk-usb0-up ] && run /usr/local/sbin/afk-usb0-up || true
    }
    # 3. Safety net: re-assert the address periodically.
    run systemctl start afk-usb0-address.timer 2>/dev/null || true
    # 4. Persist the network units NOW, before the package/config steps that can
    #    fail: even a failed install must leave the device reachable after a
    #    reboot (NM made usb0 unmanaged above, so nothing else would set it).
    run systemctl enable afk-usb0-address.service afk-usb0-address.timer >/dev/null 2>&1 \
        || warn "could not enable afk-usb0-address units yet (they will be enabled later)"
    if [ -e /sys/class/net/usb0 ]; then
        say "usb0 address now: $(ip -4 -o addr show dev usb0 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
    fi
}

preauth_portal() {
    if [ "$NO_SERVICES" = 1 ]; then
        say "--no-services: skipping portal pre-authorization (done at login by afk-krdp-preauth.service)"
        return 0
    fi
    local bus="/run/user/$DEV_UID/bus"
    if [ ! -S "$bus" ]; then
        say "no user session bus at $bus yet; afk-krdp-preauth.service will grant the portal permission at login"
        return 0
    fi
    if [ -x /usr/local/sbin/afk-krdp-preauth ]; then
        run runuser -u "$DEV_USER" -- env XDG_RUNTIME_DIR="/run/user/$DEV_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" /usr/local/sbin/afk-krdp-preauth \
            || warn "portal pre-authorization failed (krdp will ask the dialog)"
    fi
}

# --------------------------------------------------------------------- reporting ---
report() {
    say "---------------------------------------------"
    say "AFK overlay $OVERLAY_VERSION installed"
    say "  user:          $DEV_USER ($DEV_HOME)"
    say "  ssh:           $(systemctl is-active sshd 2>/dev/null) / $(systemctl is-enabled sshd 2>/dev/null)"
    say "  usb0:          $(ip -4 -o addr show dev usb0 2>/dev/null | awk '{print $4}' | tr '\n' ' ') (NM unmanaged: $([ -f /etc/NetworkManager/conf.d/90-afk-unmanaged.conf ] && echo yes || echo no))"
    say "  dhcp:          $(systemctl is-active afk-usb0-dhcp 2>/dev/null)"
    say "  journal:       $(journalctl --disk-usage 2>/dev/null)"
    say "  pstore:        $(systemctl is-active systemd-pstore 2>/dev/null)"
    say "  krdp config:   /etc/xdg/krdpserverrc"
    say "  watchdog:      $([ -f /etc/systemd/system.conf.d/90-afk-watchdog.conf ] && echo enabled || echo disabled)"
    say "  firewall:      $([ -f /etc/systemd/system/afk-firewall.service ] && echo installed || echo not-installed)"
    say "  backups:       $BACKUP_ROOT/$TIMESTAMP"
    say "Next: reboot (or log out/in) so autologin + the KRDP user units apply,"
    say "      then on the host run: tools/afk/afk.sh status / shot / rdp"
    say "---------------------------------------------"
}

# -------------------------------------------------------------------- uninstall ---
do_uninstall() {
    say "uninstalling AFK overlay (version $OVERLAY_VERSION)"
    local unit
    if [ "$NO_SERVICES" != 1 ]; then
        for unit in afk-usb0-dhcp.service afk-boot-snapshot.service \
                    afk-shutdown-snapshot.service afk-firewall.service; do
            run systemctl disable --now "$unit" >/dev/null 2>&1 || true
        done
    fi

    if [ -f "$MANIFEST" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            while [ "${p#//}" != "$p" ]; do p="${p#/}"; done
            if is_protected_path "$p"; then
                warn "refusing to remove admission topology file: $p"
                continue
            fi
            case "$p" in
                /etc/*|/usr/local/*|/home/*) ;;
                *) warn "refusing to remove unexpected manifest entry: $p"; continue ;;
            esac
            run rm -f -- "$p"
        done <"$MANIFEST"
        run rm -f -- "$MANIFEST"
    else
        warn "no $MANIFEST; only restoring backups"
    fi

    # Legacy cleanup: early overlay builds shipped an NM connection profile
    # instead of the unmanaged+NUM-free address pinning; remove it if present.
    run rm -f -- /etc/NetworkManager/system-connections/99-afk-usb0.nmconnection 2>/dev/null || true

    # Restore the newest backup tree (paths are absolute below it).
    if [ -d "$BACKUP_ROOT" ]; then
        local newest
        newest="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n1 || true)"
        if [ -n "${newest:-}" ]; then
            say "restoring files from $newest"
            while IFS= read -r -d '' src; do
                local rel dest
                rel="${src#"${newest%/}"}"
                dest="$rel"
                run install -D -m "$(stat -c '%a' -- "$src")" -o root -g root -- "$src" "$dest"
            done < <(find "${newest%/}" -type f -print0)
        fi
    fi

    if [ "$NO_SERVICES" != 1 ]; then
        run systemctl daemon-reload || true
        run systemctl reload sshd 2>/dev/null || true
        run systemctl reload NetworkManager 2>/dev/null || true
    fi
    say "uninstall complete. Kept: $STATE_DIR, $LOG_DIR, krdp TLS identity."
    say "Remove manually if desired: rm -rf $STATE_DIR $LOG_DIR $DEV_HOME/.local/share/krdpserver"
}

# --------------------------------------------------------------------- main flow ---
if [ "$DO_UNINSTALL" = 1 ]; then
    [ "$DRY_RUN" = 1 ] || mkdir -p "$STATE_DIR" "$LOG_DIR"
    do_uninstall
    exit 0
fi

say "installing AFK overlay $OVERLAY_VERSION (dry-run=$DRY_RUN)"
[ -e /sys/class/net/usb0 ] || warn "usb0 not present right now; network profile will apply when the gadget appears"
[ -e /sys/kernel/config/usb_gadget/liuqin/UDC ] || warn "configfs gadget not found (expected from the initramfs); USB access may be unavailable"

run mkdir -p "$STATE_DIR" "$LOG_DIR" "$LOG_DIR/boots" "$BACKUP_ROOT" /var/lib/systemd/pstore
run chmod 0755 "$LOG_DIR" "$LOG_DIR/boots"
run chmod 0700 "$STATE_DIR"
run chmod 0700 /var/lib/systemd/pstore 2>/dev/null || true
if [ "$DRY_RUN" != 1 ]; then
    : >"$MANIFEST.new"
fi

# Order matters (network-first, so a failed later step cannot strand the channel):
#   files -> RELIABLE USB NETWORK -> packages -> user/config -> services -> sshd.
# If anything after step 2 fails, the operator can still SSH in and rerun the
# installer (it is idempotent).
stage="$(mktemp -d /tmp/afk-stage.XXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
stage_files "$stage"
install_tree "$stage"
apply_network_early

install_packages
provision_user
apply_systemd
apply_sshd
preauth_portal

if [ "$DRY_RUN" != 1 ]; then
    # Publish the file manifest only after a successful run.
    if [ -f "$MANIFEST" ]; then
        cat "$MANIFEST" "$MANIFEST.new" 2>/dev/null | sort -u >"$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    else
        sort -u "$MANIFEST.new" >"$MANIFEST"
    fi
    rm -f "$MANIFEST.new"
    printf '%s\n' "$OVERLAY_VERSION" >"$STATE_DIR/version"
    restorecon -R /etc/ssh /etc/NetworkManager /etc/systemd/system \
        /usr/local/sbin 2>/dev/null || true
fi

report
exit 0
