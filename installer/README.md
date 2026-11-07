# installer/ — Fedora liuqin 安装器

把上游 `xiaomipad-6pro-mainline` 的 liuqin 安装器（MIT，commit
`f5a535f5c1c980f042b58cb77467ff8f02a5518e`）Fedora 化。当前发布镜像使用
GNOME/GDM；设备侧脚本同时保留 `plasmalogin`（KDE）兼容路径，便于历史配方对照。
安装会清除 Android 用户数据，只支持 Linux 单系统布局。

## 目录

```
install.py                  host 侧安装器（上游 + Fedora 门控/dry-run）
lib/
  liuqin_layout.py          分区布局引擎（上游逐字复用）
  liuqin-rom-images.json    原厂 ROM 钉死表（上游逐字复用）
  install-layout.sh         设备侧 GPT 操作（上游逐字复用）
  install-root.sh           设备侧 root 安装（Fedora 改写：契约/显示管理器/特权位）
  install-switch-store.sh   dual 布局的 boot 镜像 store（上游逐字复用）
  provision.sh              从 persist 只读 provision（上游逐字复用）
  liuqin-charger-mode-exit.c  静态 liuqin-reboot 源码（上游逐字复用）
build-runtime.py            Fedora aarch64 包 → RAM 安装器 runtime（7 ELF + libs）
assemble-installer.py       runtime + 设备脚本 → RAM 安装器 overlay（boot-builder 接口）
PROVENANCE.md               来源、sha256、逐字/改造清单
```

## 用法

```sh
# 1) 本地校验（默认；不访问设备）
python3 installer/install.py --bundle out/bundle --check

# 2) 只读演练（fake fastboot 或真实设备只读 getvar；所有写入只打印）
python3 installer/install.py --bundle out/bundle --serial SERIAL \
  --backup ~/liuqin-backup --erase-userdata --layout linux-only --allow-unverified --dry-run

# 3) 确认备份和演练结果后实写
python3 installer/install.py --bundle out/bundle --serial SERIAL \
  --backup ~/liuqin-backup --erase-userdata --layout linux-only \
  --allow-unverified --yes-write-device

# 4) 构建 Fedora 安装器 runtime + overlay（首次用 podman 下载 Fedora 包，约 3 分钟）
scripts/build-installer.sh --download --assemble
#   或从已解包 Fedora rootfs / RPM 目录：
scripts/build-installer.sh --from-rootfs out/rootfs/rootfs --assemble \
  --contract out/rootfs/liuqin-fedora-root.contract
```

完整安装步骤和首次登录说明见 Release 附带的 `INSTALL.md`。
`installer.img` 由 boot-builder 流水线组装（`scripts/build-initramfs.sh` +
`scripts/build-bootimg.sh`）；本目录交付其 overlay（`out/installer/image-overlay/`，清单见
`installer-image.json`）。

## 测试

```sh
sh tests/installer/run-all.sh
```

覆盖：布局引擎、设备侧 GPT 脚本、host 套件（上游适配）、fake-fastboot dry-run 全流程与拒绝分支、
FUSE/ext4 级 `install-root.sh` e2e、bundle/contract/runtime/overlay 工具链。全部离线。
设备侧 e2e 在缺少 loop 驱动时使用 `fuse2fs` + `blockdev`/`mount` stub。
