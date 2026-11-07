# liuqin sensor stack (Fedora packaging)

This package carries the Fedora adaptation of the liuqin sensor overlay from
`yzddmr6/xiaomipad-6pro-mainline` (`device/sensors-overlay/`, pinned sources in
`device/sensors/sources.manifest`).

## Source / provenance

- libssc 0.4.4, commit 0cf77b93b55752da34dca2dcecc06fca8665184b
- iio-sensor-proxy 3.9, commit 0085ddf8ecb173a1c5fcf2344aa40e561125354f
- hexagonrpc 0.5.0 (git 598b591ae9da6a6cfe2ca5ea78998019ca6395ea)
- 6 liuqin patches: see /usr/share/doc/liuqin/sensor-stack-patches.manifest
  (2 hexagonrpc, 4 iio-sensor-proxy; libssc is unpatched)

## Fedora path adaptations vs upstream Ubuntu overlay

| upstream (Ubuntu) | this package (Fedora) |
|---|---|
| `/usr/local/sbin/liuqin-*` | `/usr/libexec/liuqin/*` |
| `/usr/libexec/iio-sensor-proxy` drop-in `ExecStart=/usr/local/libexec/liuqin-iio-sensor-proxy` | `ExecStart=/usr/libexec/iio-sensor-proxy` (we ship the patched iio-sensor-proxy as a replacement RPM) |
| session refresh waits for `org.gnome.Shell` | waits for `org.kde.KWin` (KDE target; unverified on liuqin, see docs/maintenance/mobile-stack-packages.md) |
| ROM sensor registry copied at image build | **operator action**: `liuqin-sensor-registry-import <dir>`; per-device data never packaged |

## Enablement (do not auto-enable units that need hardware)

```
systemctl enable liuqin-slpi.service
systemctl enable liuqin-sensor-proxy-refresh.service
systemctl --global enable liuqin-sensor-proxy-session-refresh.service
```

`liuqin-sensor-stack.target` is started by the udev rule on `/dev/fastrpc-sdsp`
(SYSTEMD_WANTS), not by static enablement. iio-sensor-proxy is deliberately not
boot-started (upstream claim-timing evidence).
