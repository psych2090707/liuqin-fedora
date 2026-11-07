# installer/ — Fedora liuqin 安装器

把上游 `xiaomipad-6pro-mainline` 的 liuqin 安装器（MIT，commit
`f5a535f5c1c980f042b58cb77467ff8f02a5518e`）Fedora 化。首次安装已在 TN0047 执行过；当前保留的是旧 KDE 安装器与离线回归输入，**本机不再重装/重新分区**。旧 `--keep-home` 不保护当前 root 内的 HOME。
当前边界见 docs/build/installer.md，历史流程见 归档。

## 目录

```
install.py                  host 侧安装器（上游 + Fedora 门控/dry-run）
lib/
  liuqin_layout.py          分区布局引擎（上游逐字复用）
  liuqin-rom-images.json    原厂 ROM 钉死表（上游逐字复用）
  install-layout.sh         设备侧 GPT 操作（上游逐字复用）
  install-root.sh           设备侧 root 安装（Fedora 改写：契约/SDDM/特权位）
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

# 不列实写命令：本机禁止重装；历史 flag 不是当前授权。

# 4) 构建 Fedora 安装器 runtime + overlay（首次用 podman 下载 Fedora 包，约 3 分钟）
scripts/build-installer.sh --download --assemble
#   或从已解包 Fedora rootfs / RPM 目录：
scripts/build-installer.sh --from-rootfs out/rootfs/rootfs --assemble \
  --contract out/rootfs/liuqin-fedora-root.contract
```

`installer.img` 由 boot-builder 流水线组装（`scripts/build-initramfs.sh` +
`scripts/build-bootimg.sh`）；本目录交付其 overlay（`out/installer/image-overlay/`，清单见
`installer-image.json`），并已用该流水线实际组装出结构验证镜像 `out/installer/installer.img`
（23.3 MB，`device_ready=false`，见 docs/build/installer.md §9.1）。

## 测试

```sh
sh tests/installer/run-all.sh
```

覆盖：布局引擎、设备侧 GPT 脚本、host 套件（上游适配）、fake-fastboot dry-run 全流程与拒绝分支、
FUSE/ext4 级 `install-root.sh` e2e、bundle/contract/runtime/overlay 工具链。全部离线。
本机内核无 loop 驱动，设备侧 e2e 用 `fuse2fs` + `blockdev`/`mount` stub（详见
docs/build/installer.md §9/§10）。
