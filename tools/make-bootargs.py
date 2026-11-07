#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Derive a daily-use liuqin cmdline without changing hardware workarounds."""
import argparse
from pathlib import Path


def daily_bootargs(text, fbdev_client=True, simpledrm=False):
    """Return the quiet daily cmdline derived from the pinned upstream one.

    fbdev_client=False omits drm_client_lib.active=fbdev: the msm fbdev client
    logs "framebuffer is not in virtual address space" and leaves the panel
    black for the compositor.
    simpledrm=True drops initcall_blacklist=simplefb_driver_init so the kernel
    can take over the bootloader framebuffer and Plymouth can splash before
    msm binds (the blacklist exists to keep text diagnostics visible).
    """
    words = text.split()
    remove = {"earlycon", "keep_bootcon", "console", "initcall_debug",
              "ignore_loglevel", "loglevel", "quiet", "rhgb", "splash",
              "gnome.is_vm", "systemd.show_status", "drm_client_lib.active"}
    words = [word for word in words if word.split("=", 1)[0] not in remove]
    if simpledrm:
        # Keep earlycon's renderer out of the way of simpledrm/fbdev.
        words = [word for word in words
                 if word != "initcall_blacklist=simplefb_driver_init"]
    # Keep a real console (the daily kernel has no CONFIG_NULL_TTY). ABL
    # appends loglevel=6, so /init also silences printk before native KMS takes
    # over. Without earlycon/drm_log no diagnostic renderer bypasses Plymouth.
    for word in ("gnome.is_vm=0", "console=tty0", "quiet", "rhgb",
                 "systemd.show_status=false"):
        if word not in words:
            words.append(word)
    if fbdev_client and "drm_client_lib.active=fbdev" not in words:
        words.append("drm_client_lib.active=fbdev")
    return " ".join(words) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(daily_bootargs(args.source.read_text()))
