# packaging/device — liuqin 设备层 Fedora RPM

本目录把 [yzddmr6/xiaomipad-6pro-mainline](https://github.com/yzddmr6/xiaomipad-6pro-mainline)
v0.6.0 中**发行版中立**的设备层打包为 Fedora aarch64 RPM。上游 checkout 只读，
所有路径迁移/改写都发生在打包阶段，并在 `relocate-device-support.sh` 中逐条列出。

入口：`scripts/build-device-rpms.sh`（在 Fedora 45 容器里 rpmbuild）。
文件映射、许可与验证范围见本目录各 spec 的注释。

| 文件 | 作用 |
|---|---|
| `liuqin-firmware.spec` | 197 文件固件闭包（本地私有、不可再分发）→ `/usr/lib/firmware`，带 sha256 清单校验与冲突迁移 |
| `liuqin-audio.spec` | AudioReach topology（m4 + alsatplg 从源码构建、bin sha256 锁定）+ ALSA UCM2 |
| `liuqin-device-support.spec` | systemd/udev/polkit/chrony + 电源键/充电/背光/WLAN MAC/BT 地址/双启动 helper；含低频日常日志源码配方（timer 不自动启用） |
| `relocate-device-support.sh` | 把上游 `/usr/local/...` 布局迁移到 Fedora FHS，并改写 unit/udev/polkit/desktop 引用 |
| `helpers/liuqin-power-key-action` | Fedora/KDE 版电源键动作（替换上游 GNOME/Mutter 实现） |
| `elf-check.py` | 离线校验 aarch64 静态 ELF（构建期硬性检查） |
| `container/build-inner.sh` | 容器内 rpmbuild 驱动 |
| `container/postprocess.py` | SHA256SUMS + 本地 repo + build-info.json |
| `container/verify-install.py` | 临时 root 安装验证、payload/权限/符号链接/架构/systemd 校验 |

构建（宿主机需要 rootful podman、passwordless sudo、`aarch64-linux-gnu-gcc`、代理环境变量）：

```sh
scripts/build-device-rpms.sh                 # 全部三个包
scripts/build-device-rpms.sh --only firmware # 单个包
scripts/build-device-rpms.sh --rebuild-image # 重建构建容器镜像
```

产物：`out/rpms/*.rpm` + `SHA256SUMS` + `build-info.json` + `validation-report.json` +
`repodata/`（本地 dnf 仓库，供镜像组装阶段 chroot 安装）。
