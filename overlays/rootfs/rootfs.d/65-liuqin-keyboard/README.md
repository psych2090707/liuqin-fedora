# 65-liuqin-keyboard — magnetic keyboard MCU wake policy

Desktop-neutral device layer for the Xiaomi Pad 6 Pro magnetic keyboard cover
(Nanosic WN8030, i2c name `liuqin-keyboard`, address `4-004c`).

The MCU pulses its wake line on every suspend entry. With wake enabled this
aborts deep suspend with `Wakeup pending` / `wake IRQ with no resume`, and can
end an otherwise good sleep. The behaviour was first recorded on the old KDE
image and was still observed on F45 / 7.3.1 in November 2026.

The rule disables only this device's `power/wakeup`:

```text
ACTION=="add|change", SUBSYSTEM=="i2c", ATTR{name}=="liuqin-keyboard", ATTR{power/wakeup}="disabled"
```

Consequences:

- pressing keys on the keyboard cover no longer wakes the tablet;
- the power key and the Hall lid switch still wake it, because they belong to
  `gpio-keys` and are not touched;
- opening/closing the cover still works as a wake/suspend signal.

This file used to live in `overlays/kde/`. It was not copied when the GNOME /
Fedora 45 image was assembled, so it disappeared with the new rootfs. Keep it
here (applied for every desktop profile) instead of under a desktop-specific
overlay.

Rollback: delete the rule (or set `power/wakeup` back to `enabled` for
`4-004c`) and reboot. The old KDE copy is available in git history before the
move, and the rule content is unchanged.
