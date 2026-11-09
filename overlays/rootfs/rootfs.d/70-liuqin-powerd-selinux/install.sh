#!/bin/bash
# Install the local SELinux type used by liuqin-powerd's state directory.
# Optional: the daemon works without it, it only removes a few AVC records per
# minute from the permissive audit log.  See README.md.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for tool in checkmodule semodule_package semodule semanage; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "liuqin-powerd selinux: $tool missing; skipping optional module" >&2
        exit 0
    fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

checkmodule -M -m -o "$tmp/liuqin-powerd.mod" "$here/liuqin-powerd.te"
semodule_package -o "$tmp/liuqin-powerd.pp" -m "$tmp/liuqin-powerd.mod"
if ! semodule -i "$tmp/liuqin-powerd.pp"; then
    echo "liuqin-powerd selinux: semodule -i failed; state writes will still be audited" >&2
    exit 0
fi

# Idempotent: -a on a fresh policy store, -m when the rule already exists.
if ! {
    semanage fcontext -a -t liuqin_powerd_state_t '/run/liuqin-powerd(/.*)?' 2>/dev/null ||
        semanage fcontext -m -t liuqin_powerd_state_t '/run/liuqin-powerd(/.*)?'
}; then
    echo "liuqin-powerd selinux: could not add the file-context rule" >&2
    exit 0
fi
