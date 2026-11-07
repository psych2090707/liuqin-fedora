# mkosi/ — liuqin Fedora ARM64 desktop rootfs configuration

默认配方是 **Fedora 45 Workstation / GNOME 51 + GDM**；`plasma.conf` 是保留的历史 KDE
对照，不再作为发布镜像的默认入口。

Cross-arch mkosi tree (x86_64 host → aarch64 target, `Format=directory`,
`Bootable=no`). Driver: `scripts/build-rootfs.sh`.

```
mkosi.conf                    base: Fedora 45 / arm64 / platform packages
mkosi.profiles/gnome.conf     Fedora Workstation environment + tablet packages
mkosi.profiles/plasma.conf    retained historical KDE Plasma profile
mkosi.skeleton/               files copied before packages (fstab, hostname,
                              /etc/skel GNOME monitors.xml, display config)
mkosi.postinst.chroot         runs inside the image: dev user, services,
                              login manager, greeter config, image hygiene
mkosi.packages/               build-time local RPM drop-in (see its README)
mkosi.tools/                  auto-built Arch tools tree (gitignored cache)
```

Artifacts land in `out/rootfs/` (gitignored): the rootfs tree, the
machine-readable `rootfs.manifest`, `rootfs.files.sha256`, `build-info.json`,
validation output and build logs.

Release override: `scripts/build-rootfs.sh --release 45`. Device RPMs/overlays are injected at root.img
assembly time: `overlays/rootfs/README.md`.
