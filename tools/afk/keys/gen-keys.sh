#!/bin/bash
# AFK channel — generate the dedicated host->device SSH key.
#
# The private key stays on the host and is git-ignored
# (tools/afk/keys/.gitignore); only the .pub is baked into the overlay tarball
# and installed into the device user's authorized_keys.
#
# Idempotent: existing keys are never overwritten.
set -euo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

KEY="$AFK_SSH_KEY"
COMMENT="afk-tn0048@$(hostname 2>/dev/null || echo host)"

mkdir -p "$(dirname "$KEY")"
chmod 0700 "$(dirname "$KEY")" 2>/dev/null || true

if [ -f "$KEY" ]; then
    say "SSH key already exists: $KEY"
else
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
    ssh-keygen -q -t ed25519 -N '' -C "$COMMENT" -f "$KEY"
    chmod 0600 "$KEY"
    say "generated: $KEY"
fi

if [ ! -f "$KEY.pub" ]; then
    ssh-keygen -y -f "$KEY" >"$KEY.pub"
    chmod 0644 "$KEY.pub"
fi

say "public key (installed by overlays/afk/install.sh):"
cat "$KEY.pub"
note "the private key is git-ignored and never copied to the device"
