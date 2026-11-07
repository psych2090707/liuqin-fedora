#!/bin/sh
# SPDX-License-Identifier: MIT
# Sourced only by this candidate's initramfs, after root admission.
# Every added file lives on tmpfs; underlying root/modules/config stay intact.
ram_modules_activate() {
    [ "$(uname -r)" = 7.3.1-liuqin-exp1 ] || return 1
    [ -d "$storage_newroot/usr/lib/modules" ] || return 1
    [ -d "$storage_newroot/run" ] || return 1
    mkdir -p /liuqin-ram-tmp || return 1
    # SELinux policy is not loaded in stage 1, so context= is rejected here.
    # Label only this tmpfs module view later, after systemd loads the policy.
    mount -t tmpfs -o mode=0755 tmpfs /liuqin-ram-tmp || return 1
    cp -a /liuqin-ram/modules/. /liuqin-ram-tmp/ || return 1
    mount -o bind /liuqin-ram-tmp/lib/modules "$storage_newroot/usr/lib/modules" || return 1
    mount -t tmpfs -o mode=0755 tmpfs "$storage_newroot/run" || return 1
    mkdir -p "$storage_newroot/run/systemd/system/liuqin-fpc-stable-module.service.d" || return 1
    cat >"$storage_newroot/run/systemd/system/liuqin-fpc-stable-module.service.d/90-ram-kernel.conf" <<'UNIT'
[Service]
ExecStartPre=/usr/bin/chcon -R -t modules_object_t /usr/lib/modules/7.3.1-liuqin-exp1
ExecStart=
ExecStart=/usr/sbin/modprobe fpc1264_spi_diag
UNIT
    cp /liuqin-ram/identity.json "$storage_newroot/run/liuqin-kernel-ram-test.json" || return 1
    log "RAM TEST: matching modules and FPC override are tmpfs-only"
}
if ! ram_modules_activate; then
    umount "$storage_newroot/run" 2>/dev/null || true
    umount "$storage_newroot/usr/lib/modules" 2>/dev/null || true
    umount /liuqin-ram-tmp 2>/dev/null || true
    log "RAM TEST: module activation failed; refusing root handoff"
    return 1
fi
