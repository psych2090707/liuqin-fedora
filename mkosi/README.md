# mkosi/ — liuqin Fedora ARM64 desktop rootfs configuration

默认配方是 **Fedora 45 Workstation / GNOME 51 + GDM**；`plasma.conf` 是保留的历史 KDE
对照，不再作为日用系统的默认入口。设备当前仍是 Fedora 44 / GNOME，完整候选的组装结果见
F45 结果。

Cross-arch mkosi tree (x86_64 host → aarch64 target, `Format=directory`,
`Bootable=no`). Driver: `scripts/build-rootfs.sh`; docs: `docs/build/rootfs-build.md`.

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

Release override: `scripts/build-rootfs.sh --release 45` (see docs for the
Fedora 45 GA switch checklist). Device RPMs/overlays are injected at root.img
assembly time: `overlays/rootfs/README.md`.
