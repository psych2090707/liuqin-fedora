# overlays/afk — device side of the AFK channel (TN0048)

> **保留的旧 KDE 部署实现，不适用于当前 GNOME 重装覆盖。** 下文安装/卸载仅解释历史代码，不能沿用到当前账户、网络、电源与密码库配置。当前入口见 AFK。本目录仍含 USB/取证的在用源文件，不能整体删除。

> **层次（2026-11-06）**：干净镜像的 USB NCM 产品功能在 `overlays/rootfs/rootfs.d/60-liuqin-usb/`，名字是 `liuqin-usb0-*`。本目录的 `afk-*` 只是维护层，不应进入干净镜像。若维护基座已经带 `liuqin-usb0-link.service`，`install.sh` 会跳过 `afk-usb0-address/dhcp`，只保留 AFK 工具；`90-afk.preset` 也只服务于维护镜像。

Everything here runs **on the tablet** (or is baked into its rootfs later).
The host side lives in [tools/afk](../../tools/afk/README.md); the full story is
docs/maintenance/afk-channel.md.

TN0074 增加了 USB device-role 核对：现有 address service 的 drop-in 先核对控制器角色，
udev 在 role/typec 变化时调度同一个服务，不新增轮询。仅当 Type-C 已报告 device、
本机 rescue gadget 已绑定时修正误落到 host 的控制器；不改 Type-C 协商、不覆盖真实 host。
原 address service 的 netdev 存在条件由 SLPI 标记条件替代，避免 netdev 消失时跳过修复。
依据、验证边界与单独回退见 TN0074。

```
overlays/afk/
  install.sh                  device-side installer (idempotent, backs up, --dry-run, --uninstall)
  files/                      file tree rooted at / ; install.sh copies it as-is
    etc/NetworkManager/conf.d/90-afk-unmanaged.conf   # NM must not manage usb0
    etc/afk/dnsmasq-usb0.conf
    etc/afk/usb0-firewall.nft                    (opt-in via --firewall)
    etc/ssh/sshd_config.d/90-afk.conf
    etc/systemd/journald.conf.d/90-afk-persistent.conf
    etc/systemd/system/afk-usb0-address.service       # ip addr replace 192.168.7.2/24 + up
    etc/systemd/system/afk-usb0-address.timer         # re-assert every 120s (safety net)
    etc/systemd/system/afk-usb0-dhcp.service
    etc/systemd/system/afk-boot-snapshot.service
    etc/systemd/system/afk-shutdown-snapshot.service
    etc/systemd/system/afk-firewall.service      (opt-in via --firewall)
    etc/systemd/system.conf.d/90-afk-watchdog.conf.off   (opt-in via --watchdog)
    etc/plasmalogin.conf.d/90-afk-autologin.conf   # Session=plasma.desktop (file name!)
    etc/xdg/krdpserverrc                         # KRDP: TLS identity + system-user auth
    etc/xdg/kscreenlockerrc                      # dev-only: no lock screen
    etc/xdg/powerdevilrc                         # Plasma 6 format: AC no DPMS/suspend
    home/user/.config/systemd/user/afk-krdp-preauth.service
    home/user/.config/systemd/user/app-org.kde.krdpserver.service.d/10-afk-preauth.conf
    home/user/.config/systemd/user/plasma-workspace.target.wants/{afk-krdp-preauth,app-org.kde.krdpserver}.service
    usr/local/sbin/afk-usb0-up                   # idempotent address pinning for the units above
    usr/local/sbin/afk-health                    # read-only health snapshot (host: afk.sh diag)
    usr/local/sbin/afk-shot                      # spectacle screenshot in the live session
    usr/local/sbin/afk-collect                   # tar.gz diagnostics (host: afk.sh logs)
    usr/local/sbin/afk-boot-snapshot             # per-boot / per-shutdown log snapshot
    usr/local/sbin/afk-krdp-preauth              # portal permission for unattended KRDP
```

## Historical one-shot install (not for the current device)

From the host, over the USB link:

```sh
tools/afk/afk.sh up                          # SSH reachable
tools/afk/afk.sh repo build                  # offline aarch64 RPMs (krdp, dnsmasq, openssl, dnf5)
tools/afk/afk.sh overlay-install --dry-run   # inspect
tools/afk/afk.sh overlay-install             # real install (+ --rpms auto-detected)
tools/afk/afk.sh reboot --wait 240           # autologin + KRDP user units apply after reboot
```

`install-overlay.sh` builds the tarball, scp's it to `/tmp`, and runs
`sudo bash /tmp/afk-overlay/afk-overlay-*/install.sh` on the device. When the
public key is not installed yet it authenticates with the dev password through
`SSH_ASKPASS` (non-interactive) and switches to the key automatically once the
installer has written `authorized_keys`.

By default the installer runs **detached on the tablet** (`setsid --fork`,
output in `/var/log/afk/install-<ts>.log`) and the host polls for its exit code:
on a first install NetworkManager may own the current usb0 address, so making
the device unmanaged can drop the SSH session midway — a detached run survives
that and still reports the result. Use `--foreground` to attach it to the
terminal (e.g. for `--dry-run`, which never touches the network).

## Direct device-side install (no host tooling)

```sh
# copy the tarball to the tablet by any means, then:
tar -xzf afk-overlay-*.tar.gz -C /tmp
sudo bash /tmp/afk-overlay-*/install.sh --dry-run
sudo bash /tmp/afk-overlay-*/install.sh --rpms /path/to/rpms
```

Options (see `install.sh --help`): `--rpms DIR`, `--repo URL`, `--skip-packages`,
`--watchdog`, `--firewall`, `--no-password-auth`, `--restart-dm`, `--dry-run`,
`--uninstall`.

### What the installer changes, in order (**network-first**)

1. copies `files/` to `/`, backing up every replaced file to
   `/var/lib/afk/backup/<utc-ts>/` first;
2. **immediately makes the USB link reliable**: marks `usb0` unmanaged in
   NetworkManager, starts `afk-usb0-address.service` (pins 192.168.7.2/24) and
   its 120s safety-net timer, and `systemctl enable`s both *before* any risky
   step — so even if the package/certificate/RDP steps below fail, SSH over USB
   stays reachable and the installer can simply be rerun;
3. installs the missing packages (`rpm -Uvh` from the offline bundle, one
   transaction; or `dnf5 --repofrompath` if a repo is given);
3. appends the host public key to `/home/user/.ssh/authorized_keys`, adds the
   user to `systemd-journal,adm` (unprivileged log collection), generates the
   KRDP TLS identity (`/home/user/.local/share/krdpserver/krdp.{crt,key}`);
4. creates `/var/log/journal` + `/var/log/afk`, enables `afk-usb0-dhcp`,
   `afk-boot-snapshot`, `afk-shutdown-snapshot`, `systemd-pstore`, restarts
   journald and flushes the journal;
5. `sshd -t` then `systemctl reload sshd` (never restarts it, so the installing
   SSH session survives);
6. **last**: reloads NetworkManager and activates `afk-usb0` (this can bounce
   the installing SSH session; `install-overlay.sh` waits for it to return).

Re-running copies files and enables units again; it can overwrite newer account,
desktop and network policy. It is not harmless on the migrated device.

**Never touched**: `/etc/liuqin-fedora-root`, `/etc/liuqin-fedora-root.contract`,
`/etc/liuqin/image-contract` — the initramfs admission gate validates them on
every boot. The installer has an explicit `is_protected_path()` guard, and the
chroot test asserts their SHA256 is unchanged across install and uninstall.

If the install is interrupted after step 2, the device is still reachable over
USB (NM unmanaged + address unit enabled); just rerun `overlay-install`.

## Uninstall / rollback

```sh
tools/afk/afk.sh overlay-uninstall            # device: install.sh --uninstall
# or on the device:
sudo bash /tmp/afk-overlay-*/install.sh --uninstall
```

It disables the overlay units, removes every path recorded in
`/var/lib/afk/files.manifest`, restores the newest backup tree over `/etc`,
and reloads sshd/NetworkManager.  Kept on purpose: `/var/lib/afk`,
`/var/log/afk` (evidence) and the KRDP TLS identity — delete them manually if
you want a clean slate.

To disable just the AFK layer without uninstalling, comment out
`/etc/plasmalogin.conf.d/90-afk-autologin.conf` (autologin off) and
`systemctl --user disable app-org.kde.krdpserver.service` as the device user.

## Packages needed (offline repo, see tools/afk/build-repo.sh)

| package | why |
|---|---|
| `krdp`, `krdp-libs` | RDP server, version-locked to the rootfs' Plasma 6.7.5 |
| `freerdp-libs`, `libwinpr` | pulled in by krdp (RDP protocol) |
| `dnsmasq` | serves 192.168.7.10-19 to the host so it needs no root/static config |
| `openssl` | pre-generated KRDP TLS identity (rootfs has libs but no CLI) |
| `dnf5`, `dnf5-plugins`, `libdnf5*` | optional: lets the device install more packages over the USB HTTP repo |

`krfb`/`libvncserver` (VNC plan B) and `ydotool` are in
[tools/afk/packages-extra.txt](../../tools/afk/packages-extra.txt) but not
installed by default.

## Baking into the mkosi rootfs later (without touching mkosi files now)

The overlay is deliberately a plain file tree + installer, so promoting it into
the image build is mechanical.  When the Lead decides to bake it:

1. copy the tree into the mkosi skeleton, e.g.
   `cp -a overlays/afk/files/. mkosi/mkosi.skeleton/`
   (mkosi applies `mkosi.skeleton` as a root-filesystem overlay during the build);
2. **do not** copy `install.sh`; instead add the enablement steps to
   `mkosi/mkosi.postinst.chroot` (chrooted, offline, no running services):
   * `systemctl enable afk-usb0-dhcp afk-boot-snapshot afk-shutdown-snapshot systemd-pstore`
   * `mkdir -p /var/log/journal && chmod 2755 /var/log/journal`
   * `rpm -q krdp dnsmasq openssl` (or list them in `mkosi/mkosi.profiles/plasma.conf`)
   * the user-unit symlinks are plain files under `/home/<user>/.config`, created
     in the chroot with the right owner (mkosi preserves numeric ownership —
     mirror the existing `mkosi.postinst.chroot` dev-user block);
3. inject the **public** key at build time (never the private key):
   e.g. a build-time `install -D -m600 <pubkey> /home/$DEV_USER/.ssh/authorized_keys`
   fed from `tools/afk/keys/id_ed25519_afk.pub` (a build input, not a committed
   device fact);
4. `--watchdog` / `--firewall` / `--no-password-auth` are install-time choices;
   if baking, pick one policy per image profile instead of per install;
5. keep this as a **dev-only** profile: autologin + no lock screen +
   `PasswordAuthentication yes` must not be the default for a release image.

Nothing in this task writes `mkosi/` or `installer/` — the steps above are a
recipe for whoever owns those directories.

## Notes / pitfalls encoded in the files

* `usb0` survives `switch_root` (configfs kernel state) but NetworkManager will
  attach a DHCP-client profile to it; the explicit manual profile with
  `never-default=true` prevents both the address loss and the tablet becoming a
  router for the host.
* The FRAM stage's `udhcpd` is gone after switch_root — `afk-usb0-dhcp.service`
  restores host auto-configuration (`192.168.7.10-19`), DHCP only (`port=0`),
  no router/DNS options.
* `sshd -t` is run before any reload because a broken drop-in would otherwise
  lock the only remote channel out; `AllowUsers user` and `PermitRootLogin no`
  are deliberate.
* KRDP needs the KDE RemoteDesktop portal permission, otherwise someone has to
  click a sharing dialog on a tablet nobody is touching.  `afk-krdp-preauth` +
  the ordering drop-in encode the upstream `flatpak permission-set` recipe.
* `plasmalogin` autologin needs `Session=plasma.desktop` (the file name from
  /usr/share/wayland-sessions/); sddm-style `Session=plasma` silently disables
  autologin ("Unable to find autologin session entry").
* Plasma 6.7 reads `powerdevilrc`, not the old `powermanagementprofilesrc`;
  the AFK overlay therefore ships the `[AC][Display]` / `[AC][SuspendAndShutdown]`
  layout so the panel is never blanked while unattended.
* persistent journald is what makes `afk.sh logs` useful *after* the reboots the
  AFK channel itself triggers; `systemd-pstore` keeps kernel-crash records.
* the hardware watchdog is opt-in (`.conf.off`) because a wrong watchdog on a
  device with no console can reboot-loop the tablet.
