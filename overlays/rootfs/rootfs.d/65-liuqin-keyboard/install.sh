#!/bin/bash
# Fail the image build if the desktop-neutral keyboard wake rule is missing or
# malformed.  This rule is deliberately outside overlays/kde and
# overlays/gnome: it is a keyboard-MCU hardware quirk, not a desktop setting.
set -euo pipefail

rule=/etc/udev/rules.d/71-liuqin-keyboard-nowake.rules
test -f "$rule"
grep -q 'SUBSYSTEM=="i2c"' "$rule"
grep -q 'ATTR{name}=="liuqin-keyboard"' "$rule"
grep -q 'ATTR{power/wakeup}="disabled"' "$rule"
chmod 0644 "$rule"

# qemu-user cannot run the target systemd 262 verifier reliably (some
# filesystem syscalls return ENOSYS).  The offline image builder verifies the
# installed file with the host udevadm after this chroot step instead.
if [ "${LIUQIN_IMAGE_OFFLINE:-0}" != 1 ] && command -v udevadm >/dev/null 2>&1; then
    udevadm verify "$rule"
fi
