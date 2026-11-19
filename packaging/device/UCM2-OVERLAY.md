# Project UCM2 overlay

These files override the UCM2 copy taken from the read-only upstream checkout
(`upstream/xiaomipad-6pro-mainline/device/gnome-overlay/usr/share/alsa/ucm2`).
`scripts/build-device-rpms.sh` extracts the upstream tree, copies this
directory on top, and packs the result as `ucm2.tar`. The upstream checkout
is never modified.

Layout mirrors the UCM2 root (`/usr/share/alsa/ucm2`):

- `conf.d/sm8450/Xiaomi-Pad-6-Pro.conf`: two `SectionUseCase` entries.
- `Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf`: default stereo profile.
- `Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi-Quad.conf`: four-channel profile.

Both profiles guard the per-amp `ASPRX1/2 Slot Position` ctls with
`ControlExists`, so the UCM still opens on a kernel without the quad-slot
patch (it then behaves as plain stereo instead of falling back to Dummy
Output).

Development copies and test scripts live in `tasks/audio-quad-channel/`.
Keep this directory in sync when changing the profiles.
