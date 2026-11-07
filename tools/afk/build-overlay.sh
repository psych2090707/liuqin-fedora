#!/bin/bash
# AFK channel — pack overlays/afk into a self-contained tarball.
#
# The tarball is what tools/afk/install-overlay.sh pushes to the device:
#
#   afk-overlay-<version>/
#     install.sh            device-side installer (run as root)
#     files/                file tree rooted at / (systemd units, NM, sshd, …)
#     packages.txt          package list for --repo installs
#     afk-pubkey.txt        host public key -> device authorized_keys
#     VERSION               overlay version string
#
# Usage: build-overlay.sh [--out PATH] [--version STR]
# Prints the tarball path on stdout (and nothing else on stdout).
set -euo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

OUT=""
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:?}"; shift 2 ;;
        --out=*) OUT="${1#*=}"; shift ;;
        --version) VERSION="${2:?}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        -h|--help)
            echo "usage: build-overlay.sh [--out PATH] [--version STR]" >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

afk_state_init
OVERLAY_SRC="$AFK_ROOT/overlays/afk"
[ -d "$OVERLAY_SRC/files" ] || die "missing $OVERLAY_SRC/files"
[ -f "$OVERLAY_SRC/install.sh" ] || die "missing $OVERLAY_SRC/install.sh"

if [ -z "$VERSION" ]; then
    local_sha="nogit"
    if command -v git >/dev/null 2>&1 && git -C "$AFK_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
        local_sha="$(git -C "$AFK_ROOT" rev-parse --short HEAD)"
    fi
    VERSION="$(date -u +%Y%m%dT%H%M%SZ)-$local_sha"
fi
if [ -z "$OUT" ]; then
    OUT="$AFK_STATE_DIR/afk-overlay-$VERSION.tar.gz"
fi
mkdir -p "$(dirname "$OUT")"

# Always ship a usable public key: generate one on the host if missing.
if [ ! -f "$AFK_SSH_KEY.pub" ]; then
    bash "$TOOLS_DIR/keys/gen-keys.sh" >&2
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/afk-overlay-stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
root="$stage/afk-overlay-$VERSION"
mkdir -p "$root"

cp -a -- "$OVERLAY_SRC/install.sh" "$root/install.sh"
cp -a -- "$OVERLAY_SRC/files" "$root/files"
cp -a -- "$TOOLS_DIR/packages.txt" "$root/packages.txt"
cp -a -- "$AFK_SSH_KEY.pub" "$root/afk-pubkey.txt"
printf '%s\n' "$VERSION" >"$root/VERSION"

# Deterministic modes: units/config 0644, helper scripts 0755, NM keyfiles 0600.
chmod 0755 "$root/install.sh"
find "$root/files" -type d -exec chmod 0755 {} +
find "$root/files" -type f -exec chmod 0644 {} +
if [ -d "$root/files/usr/local/sbin" ]; then
    chmod 0755 "$root/files/usr/local/sbin/"*
fi
if [ -d "$root/files/etc/NetworkManager/system-connections" ]; then
    chmod 0600 "$root/files/etc/NetworkManager/system-connections/"*
fi
# Symlinks are stored by tar as-is (chmod would follow them, so do not).

tar -C "$stage" -czf "$OUT" "afk-overlay-$VERSION"

# A checksum next to the tarball is handy when scp'ing by hand.
sha256sum "$OUT" >"$OUT.sha256"

# Keep the state dir tidy: every build creates a new timestamped tarball.
if [ -z "${AFK_KEEP_OLD_OVERLAYS:-}" ]; then
    ls -1t "$AFK_STATE_DIR"/afk-overlay-*.tar.gz 2>/dev/null | tail -n +6 | while IFS= read -r old; do
        rm -f -- "$old" "$old.sha256"
    done
fi

# stdout: the path only; the human summary goes to stderr.
printf '%s\n' "$OUT"
note "overlay tarball: $OUT ($(du -h "$OUT" | cut -f1), version $VERSION)" >&2
note "sha256: $(cut -d' ' -f1 "$OUT.sha256")" >&2
