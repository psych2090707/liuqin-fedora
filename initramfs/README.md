# initramfs/ — Fedora 化后的 liuqin 第一阶段启动镜像源文件

本目录是 `scripts/build-initramfs.sh` 的输入（staging 源），产物是
`out/boot/initramfs/liuqin-firstboot.cpio.gz`，最终进入 `boot-liuqin-dev.img`。
**不是** dracut initramfs：liuqin 没有 EFI/GRUB，ABL 直接加载 Android boot image，
内核把本目录的 `/init` 当作 PID 1。

## 来源与许可

| 文件 | 来源 | 许可 | 说明 |
|---|---|---|---|
| `init` | `upstream/xiaomipad-6pro-mainline` v0.6.0 `initramfs/init`（sha256 `935517a5…`） | MIT | 保留 UFS fail-closed / slot / charger / root 解析主逻辑，只改发行版绑定点，见下 |
| `etc/mdev.conf` | 同上（sha256 `82ce6c10…`） | MIT | 原样拷贝 |
| `etc/issue` | 本项目新写 | MIT | 诊断提示文字（说明无鉴权 telnet 风险） |
| `fedora-profile.diff` | `diff -u upstream/…/initramfs/init init` 生成 | — | 供审计的完整差异，**不要手改**，用下方命令重新生成 |

上游只读克隆不参与提交；重建上游见 `scripts/fetch-upstream.sh`。

## 相对上游的改动（全部由 `grep -n FEDORA init` 标出）

1. **新增 root profile `fedora`**：`/etc/liuqin-root-profile` 内容为 `fedora\n`；
   root marker 为 `/etc/liuqin-fedora-root`（内容 `liuqin-fedora-root-v1\n`，22 字节）；
   契约头为 `LIUQIN_FEDORA_ROOT_CONTRACT_V2`，契约文件
   `/etc/liuqin-fedora-root.contract` 由 `tools/build-root-contract.py --profile fedora`
   从 rootfs manifest 生成后嵌入。
2. **按明确指定的桌面生成拓扑门禁**：默认仍为 KDE，GNOME 必须显式 `--desktop gnome`。下面列的是旧 KDE 清单，不是当前设备依赖：
   - 可执行：`/usr/lib/systemd/systemd`、`/usr/bin/plasmalogin`、`/usr/bin/plasmashell`、
     `/usr/bin/kwin_wayland`、`/usr/libexec/kscreenlocker_greet`（至少一个可执行位）；
   - 常规文件：`/usr/lib/systemd/system/plasmalogin.service`、`/usr/share/liuqin/kernel.release`、
     `/usr/share/liuqin/kernel-modules.manifest`；
   - 符号链接：`/usr/sbin/init → ../lib/systemd/systemd`、
     `default.target → /usr/lib/systemd/system/graphical.target`、
     **`display-manager.service → /usr/lib/systemd/system/plasmalogin.service`**（保留断言，目标为 plasmalogin）；
   - `chroot … /usr/lib/systemd/systemd --version` 必须可执行；
   - kernel 身份：`/usr/share/liuqin/kernel.release` 与 `/proc/sys/kernel/osrelease`
     不同时只警告；严格一致性由更新工具核对，不拦截正常 RPM 更新窗口。
   - TN0083 新增可选的 Fedora GNOME 完整清单（v2 语法）与过渡标记；标记存在时，
     按唯一启用的 KDE/GDM 入口选择清单，双入口或所选清单不完整即拒绝。
      接口与当前过渡/GNOME-only 边界见 启动文档。
3. **switch_root 前的 stage-1 守护进程清理**不再要求真实 root 内有
   `/usr/local/bin/busybox`：有则沿用上游 chroot 方式，否则扫描已迁移的
   `/proc` 结束 `telnetd/udhcpd`。
4. `gnome`/`native`/`legacy` profile 保持上游行为不变，便于对照与回退。

发行版自有文件（systemd、plasmalogin、plasma）**不做哈希固定**，只做拓扑/模式检查：
否则 `dnf upgrade` 会变成"下次开机失败"。v2 仅 root 角色 marker 固定内容；
日常配置和设备载荷不 pin 内容（规则在 `tools/build-root-contract.py`）。

## 重新生成审计差异

```sh
diff -u upstream/xiaomipad-6pro-mainline/initramfs/init initramfs/init \
  > initramfs/fedora-profile.diff || true
```

## 构建

```sh
# BusyBox（固定版本源码交叉编译，见 tools/build-busybox.sh）
tools/build-busybox.sh

# 契约 + initramfs（示例 manifest 用于离线结构验证；真实对接见 docs/maintenance/boot-initramfs.md）
scripts/build-initramfs.sh \
  --rootfs-manifest tools/examples/fedora-root.manifest.example \
  --allow-missing-firmware \
  --out out/boot
```

详细流程、输入矩阵、风险与后续接口见 docs/maintenance/boot-initramfs.md。
