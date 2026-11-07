# overlays/rootfs/ — device-layer injection point (root.img assembly stage)

> 保留的历史 KDE 完整镜像离线接口，不代表当前 GNOME 镜像的组装方式；不写现机 root.img。

The KDE rootfs produced by `scripts/build-rootfs.sh --profile plasma` was
**device-neutral** on purpose: it contains Fedora userspace only. Everything
liuqin-specific — kernel, DTBs, firmware, ALSA UCM/topology, sensor stack,
fingerprint bits, power/boot helpers, KDE device defaults — is injected **after**
the rootfs export and **before** `root.img` is created.

This directory defines that interface so the image assembler can consume it
without touching the mkosi build.

## Contract: `rootfs.d/<NN>-<component>/`

Declare one directory per device-layer component, processed in **lexicographic
order** (`10-` … `90-`). Each component directory may contain:

```
rootfs.d/10-kernel-liuqin/
    rpms/                 *.rpm installed in filename order (kernel-liuqin, ...)
    files/                overlay tree copied 1:1 onto / (preserves modes)
    install.sh            optional, run chrooted after rpms+files, as root
                          (idempotent; no network; `set -euo pipefail`)
    README                what this component provides + source/license notes
rootfs.d/20-liuqin-firmware/
    rpms/
    files/                e.g. usr/lib/firmware/qcom/... (user-supplied only)
rootfs.d/30-liuqin-audio/        UCM2 + topology
rootfs.d/40-liuqin-sensors/      hexagonrpcd/libssc/iio-sensor-proxy drop-ins
rootfs.d/50-liuqin-desktop/      KDE/tablet config (kdeglobals, plasmalogin,
                                 kwin output defaults, systemd units)
```

Rules for the assembler (`scripts/build-image.sh`):

1. Copy `out/rootfs/rootfs/` → staging root, then for each `rootfs.d/*/` in
   order: `dnf --installroot=<staging> -y install rpms/*.rpm` (offline, local
   rpms, `--disablerepo='*'`), then `rsync -aHAX files/ <staging>/`, then
   `chroot <staging> /path/to/install.sh` if present.
2. Never put device-unique data in here (calibration, serials, MACs, persist
   blobs, fingerprint templates): those come from the user's own device at
   provisioning time.
3. Firmware with unclear redistribution rights must not be committed to the
   repo; reference it from a user-supplied `--firmware-dir` and record hashes.
4. After injection, generate the final root contract/manifest from the *staged
   tree* (do not reuse `out/rootfs/rootfs.files.sha256`) and run the
   `scripts/build-rootfs.sh --skip-build --out <staging>` validation where
   meaningful (kernel.absent will legitimately fail — the device kernel is now
   present; run the image assembler's own checks instead).

## What the assembler can rely on from the rootfs build

- `/etc/liuqin/image-contract` — device/labels/display/login-manager contract
  (read it, do not hardcode).
- `/etc/fstab` — `LABEL=LIUQIN_ROOT /` + `LABEL=LIUQIN_HOME /home` (the upstream
  installer rewrites it to the /home line only; keep both labels authoritative).
- `out/rootfs/rootfs.files.sha256` — `<sha256>  /abs/path` for every regular
  file (secrets excluded) for initramfs/root-contract generation. The same bytes
  are also emitted as `out/rootfs/rootfs.hashes` (boot-builder's expected name).
- `out/rootfs/rootfs.manifest` — machine-readable package manifest (`packages[]`
  with NEVRA/arch/size) plus artifact hashes; `build-info.json` records inputs,
  `target.display_manager_service` the actual `display-manager.service` target.
- `/etc/systemd/system/display-manager.service -> /usr/lib/systemd/system/
  plasmalogin.service` and `plasmalogin.service` enabled in the historical KDE
  profile: assert this alias in the boot/initramfs contract (do not assume sddm).
- `systemd-firstboot` is masked and absent from `sysinit.target.wants`: the image
  must boot unattended; keep that contract when regenerating the tree.
- No kernel/initramfs is present: inject `kernel-liuqin` first, then run dracut.
- Fedora ships device-relevant firmware as split, xz-compressed packages:
  `atheros-firmware` (WCN6855 WiFi/BT), `cirrus-audio-firmware` (CS35L41 speaker
  protection DSP), `qcom-firmware` (a730_sqe). They are in the rootfs.
  **Firmware pool check for the initramfs/image stage:** upstream liuqin
  firmware-prep (`tools/build-liuqin-firmware-prep.sh`, sha256-pinned) needs
  `a730_zap.mbn`, `gmu_gen70000.bin` and per-speaker CS35L41 calibration from the
  user's stock ROM/vendor_a — those are NOT in Fedora and must be provided by the
  device layer / user device; decide which of them the initramfs needs
  (e.g. GPU zap for early KMS) and add them to the initramfs firmware set.
  If the liuqin kernel lacks `CONFIG_FW_LOADER_COMPRESS_XZ`, decompress the
  needed `.xz` firmware during image assembly.
- Do not run dnf/chroot tooling directly on `out/rootfs/rootfs`; copy it to a
  space-free path first (dnf5 --installroot breaks on paths with spaces).

## Build-time alternative (rarely needed)

If a component must be present *while mkosi builds the rootfs* (e.g. a patched
Fedora package that other KDE packages depend on), use `mkosi/mkosi.packages/`
plus `scripts/build-rootfs.sh --package-dir mkosi/mkosi.packages
--extra-package <name>`. Keep the device-neutral default build pristine.
