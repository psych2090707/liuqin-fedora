#!/bin/bash
# AFK channel (TN0048) — serve the offline aarch64 repo over the USB link.
#
# The tablet has no Wi-Fi; it reaches the host at $AFK_HOST_IP over the USB NCM
# cable.  This starts a plain HTTP server bound to that address so the device can:
#
#   dnf5 --repofrompath=afk,http://192.168.7.10:8080/ --setopt=afk.gpgcheck=0 install <pkg>
#
# (packages are installed with rpm -Uvh from the bundled tarball for the first
# bootstrap, because the delivery rootfs ships no dnf CLI.)
#
# Usage: serve-repo.sh [--port PORT] [--bind ADDR] [--dir DIR]
set -euo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

PORT="$AFK_REPO_PORT"
BIND="$AFK_HOST_IP"
DIR="$AFK_STATE_DIR/repo/rpms"

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:?}"; shift 2 ;;
        --port=*) PORT="${1#*=}"; shift ;;
        -p) PORT="${2:?}"; shift 2 ;;
        --bind) BIND="${2:?}"; shift 2 ;;
        --bind=*) BIND="${1#*=}"; shift ;;
        --dir) DIR="${2:?}"; shift 2 ;;
        --dir=*) DIR="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

have_cmd python3 || die "python3 is required (stdlib http.server is used deliberately: no extra deps)"
[ -d "$DIR" ] || die "repo directory not found: $DIR (run: tools/afk/afk.sh repo build)"
[ -f "$DIR/repodata/repomd.xml" ] || die "$DIR has no repodata (run: tools/afk/afk.sh repo build)"

if ! ip -4 -o addr show 2>/dev/null | grep -q "inet $BIND/"; then
    warn "$BIND is not configured on this host (run tools/afk/afk.sh up); binding 0.0.0.0 instead"
    BIND=0.0.0.0
fi

say "serving $DIR"
say "  url:    http://$AFK_HOST_IP:$PORT/  (bind $BIND)"
say "  device: dnf5 --repofrompath=afk,http://$AFK_HOST_IP:$PORT/ --setopt=afk.gpgcheck=0 install <pkg>"
say "  Ctrl-C to stop"
exec python3 -m http.server "$PORT" --bind "$BIND" --directory "$DIR"
