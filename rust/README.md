# liuqin-powerd

Unified power-key, lid and resume policy for the Xiaomi Pad 6 Pro (liuqin).
This replaces the separate `liuqin-power-keyd` (C) and `liuqin-lid-policy`
(Python) services with one state machine.

## Layout

```text
crates/liuqin-power-core/   pure state machine, no I/O, unit tested
crates/liuqin-powerd/       evdev + UPower/logind + Mutter + sysfs daemon
```

The daemon runs as the single desktop user (`User=laplus`, UID 1000 on the
device and in the stock image) with the `input` group.  The unit sets
`LIUQIN_UID=1000` explicitly because systemd's `%U` specifier expands to the
manager UID (0) in a system service, not to `User=`.  It does not grab the power key, so Mutter can still see the wake event.
Policy decisions are made from the physical panel state (`bl_power`, DRM
`dpms`/`enabled`) and only then from the settings file; a dark, visible screen
makes the first short press wake/recover the display instead of running
`SHORT_ACTION`.

## Toolchain

The host's Arch `rust`/`cargo` package is left untouched.  Cross builds use the
official Rust 1.99.1 toolchain installed once under `/opt/rust-1.99.1`:

```sh
# already installed on this host; reinstall only after a disk rebuild
# https://static.rust-lang.org/dist/2026-10-15/
#   rustc-1.99.1-x86_64-unknown-linux-gnu.tar.xz
#   cargo-1.99.1-x86_64-unknown-linux-gnu.tar.xz
#   rust-std-1.99.1-{x86_64,aarch64}-unknown-linux-gnu.tar.xz
#   rustfmt-1.99.1-x86_64-unknown-linux-gnu.tar.xz
#   clippy-1.99.1-x86_64-unknown-linux-gnu.tar.xz
```

The target linker is configured in `.cargo/config.toml`
(`aarch64-linux-gnu-gcc`).  The aarch64 std component is part of the pinned
toolchain; do not install a second aarch64 std into the host's Arch sysroot.

## Build and test

```sh
scripts/build-powerd.sh
```

This runs `cargo fmt --check`, the core tests, and the release aarch64 build.
The artifact is `rust/target/aarch64-unknown-linux-gnu/release/liuqin-powerd`
and is git-ignored; `scripts/build-image.sh` requires it when assembling a
daily image.

## Device files

| Source | Device path |
|---|---|
| `rust/target/.../release/liuqin-powerd` | `/usr/local/libexec/liuqin-powerd` |
| `overlays/gnome-local/power/etc/systemd/system/liuqin-powerd.service` | `/etc/systemd/system/liuqin-powerd.service` |
| `overlays/gnome-local/power/etc/systemd/system-preset/90-liuqin-power.preset` | `/etc/systemd/system-preset/90-liuqin-power.preset` |
| `overlays/gnome-local/power/etc/liuqin/power-policy.conf` | `/etc/liuqin/power-policy.conf` |
| `overlays/gnome-local/power/usr/local/bin/liuqin-power-settings` | `/usr/local/bin/liuqin-power-settings` |

The old `liuqin-power-keyd.service`, `liuqin-lid-policy.service`, the C daemon
and the Python/shell helpers remain installed for rollback.  The preset now
enables only `liuqin-powerd.service` and explicitly disables the two old units,
so a first boot cannot run two policy owners.

## Read-only check

```sh
/usr/local/libexec/liuqin-powerd --probe
```

It prints one JSON line with the lid, power source, session-bus, Mutter mode,
physical panel state and GNOME power-button action, then exits.  It does not
act on the device.

`--ensure-on` and `--ensure-off` run the same idempotent display path the
daemon uses, then exit.  `--ensure-on` first sets `PowerSaveMode=0`, waits for
the panel, and only forces one `3 → 0` cycle if it is still dark after two
seconds.  These flags are for maintenance and were used for the 2026-11-07
device check.

## Dry run

```sh
/usr/local/libexec/liuqin-powerd --dry-run
```

Reads evdev/UPower/logind/Mutter/sysfs and logs the decisions without touching
the panel, locking or suspending.  It writes a separate
`power-state-dryrun.json`; stop it with `Ctrl-C` or `SIGTERM`.
