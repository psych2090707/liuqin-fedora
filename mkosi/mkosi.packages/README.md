# mkosi.packages/ — build-time local RPM drop-in (device layer)

Any `*.rpm` placed here is picked up by mkosi as a local repository
(`PackageDirectories=`/`mkosi.packages/` default) and can be installed with
`Packages=` / `--extra-package`. This is the **build-time** injection point.

The canonical device-layer contract for the root.img assembly stage is
`overlays/rootfs/rootfs.d/` — see `overlays/rootfs/README.md`. Prefer that for
kernel-liuqin / liuqin-firmware and other device RPMs so the rootfs stays
device-neutral and reproducible by itself.
