#!/bin/bash
# Install the local SELinux type used by liuqin-powerd's state directory.
# Optional: the daemon works without it, it only removes a few AVC records per
# minute from the permissive audit log.  See README.md.
set -euo pipefail

for tool in checkmodule semodule_package semodule semanage; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "liuqin-powerd selinux: $tool missing; skipping optional module" >&2
        exit 0
    fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The image builder copies only install.sh into the chroot, so keep the module
# source here instead of relying on a sibling file.
cat >"$tmp/liuqin-powerd.te" <<'EOF'
module liuqin-powerd 1.0;

require {
    type kernel_generic_helper_t;
    type init_t;
    attribute file_type;
    class dir { add_name getattr remove_name search setattr write };
    class file { create getattr open read rename setattr unlink write };
}

type liuqin_powerd_state_t;
typeattribute liuqin_powerd_state_t file_type;

allow { kernel_generic_helper_t init_t } liuqin_powerd_state_t:dir { add_name getattr remove_name search setattr write };
allow { kernel_generic_helper_t init_t } liuqin_powerd_state_t:file { create getattr open read rename setattr unlink write };
EOF

checkmodule -M -m -o "$tmp/liuqin-powerd.mod" "$tmp/liuqin-powerd.te"
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
