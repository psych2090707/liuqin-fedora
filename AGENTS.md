# Working on liuqin Fedora Remix

This repository builds an experimental Fedora 45 / GNOME 51 image for the
Xiaomi Pad 6 Pro (liuqin, SM8475). Read README.md, HARDWARE.md and INSTALL.md
first.

## For installation agents

- Use only the release artifacts and the exact commands in INSTALL.md. Check
  the artifact SHA256 before unpacking.
- Prefer the single entry: `liuqin-install.py` on Linux, `install-liuqin.ps1`
  on Windows. Run doctor, fetch, firmware, prepare and `--dry-run` before any
  write; read `liuqin-install-report.json` instead of guessing from prose.
- Verify the model is liuqin, the bootloader is unlocked and the layout is the
  supported stock single-system layout before any write.
- Never invent a device path, slot switch or partition change. Stop and ask
  the user when the layout, capacity, model or checksum differs.
- Require a fresh backup and a rehearsal (`--dry-run`) before
  `--yes-write-device`. Stop if the tablet cannot reach the host bundle
  server; that check runs before any partition change.
- Do not operate graphical menus or change host networking or firewall
  settings without the user's explicit permission.
- Windows USB networking, real flashing, first boot and recovery are not yet
  hardware-verified; say so instead of claiming success.
- Report the exact command, artifact SHA256 and observed output; never claim a
  device test that was not performed.

## For contributors

- Consult upstream sources before changing device support.
- Keep hardware evidence specific to the exact artifact and kernel Build ID.
- Do not flash, repartition, switch slots or erase data without explicit
  authorization, backups and readback checks.
- Preserve the SLPI disable safeguard.
- Never publish device calibration, serials, persist data, fingerprint
  templates or credentials; keep vendor firmware and prepared bundles private.
- Do not modify read-only upstream clones.
- Use scoped offline tests; document unverified behaviour as unverified.
