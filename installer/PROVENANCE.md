# installer/ 来源与复用清单（PROVENANCE）

上游仓库：`upstream/xiaomipad-6pro-mainline`（yzddmr6/liuqin mainline），
tag `v0.6.0`（2026-10-08），本仓库锁定 commit
`f5a535f5c1c980f042b58cb77467ff8f02a5518e`（`v0.6.0-6-gf5a535f`）。
上游许可证：**MIT**（`upstream/xiaomipad-6pro-mainline/LICENSE`，
"Copyright (c) 2026 The liuqin mainline project contributors"）。
本目录所有源自上游的文件都保留 `SPDX-License-Identifier: MIT` 并加注来源 commit；
Fedora 改写处以 `# FEDORA:` 注释标出。

下表中的 `tools/…`、`device/…` 和 `tests/…` 指上游仓库内的路径；本仓库对应文件列在“本目录”一列。

**复用程度（按行）**：host 安装器 871 行中约 320 行是新增的 Fedora 门控/dry-run/测试钩子
（diff `+323 / -51`），其余为逐字上游代码；四个设备侧 shell 脚本与 C helper 只加了来源注释
（每个 +6~9 行 diff），`liuqin_layout.py` 只改了一处用户可见文案（+9 行 diff，含注释）；
`liuqin-rom-images.json` **字节级一致**。

| 上游文件 | 上游 sha256 | 本目录 | 本地 sha256 | 方式 |
|---|---|---|---|---|
| `tools/install-liuqin.py` | `0373aaa8…28ec` | `installer/install.py` | `2e38ddaf…aafc` | **改造**：新增默认本地 check、`--dry-run`（只读 fastboot + 全写入打印）、`--simulate-gpt`、`--yes-write-device` 写门控、bundle `fedora` 扩展校验、`make_fastboot`/`device_identity`/`device_capacity_checks` 重构；设备协议、padded boot、备份/GPT 格式、`finish_in_fastboot` 全部保持上游行为 |
| `tools/lib/liuqin_layout.py` | `d2056be3…3a34` | `installer/lib/liuqin_layout.py` | `4f89c989…14ee` | **逐字复用**：仅分区表 detail 文案 "(Ubuntu system)"→"(Fedora system)"，并加来源注释 |
| `tools/lib/liuqin-rom-images.json` | `67455b20…1007` | `installer/lib/liuqin-rom-images.json` | `67455b20…1007` | **逐字复用**（字节级一致） |
| `tools/lib/install-layout.sh` | `9770d90a…d1747` | `installer/lib/install-layout.sh` | `34bfa038…fdb8` | **逐字复用**（仅 +6 行来源注释） |
| `tools/lib/install-switch-store.sh` | `39eb1ef5…514d` | `installer/lib/install-switch-store.sh` | `34d2f5a3…b08` | **逐字复用**（仅 +6 行来源注释） |
| `tools/provision-liuqin-from-persist.sh` | `f5d1a78e…9c13` | `installer/lib/provision.sh` | `707a91c9…fa39` | **逐字复用**（仅 +9 行来源注释） |
| `tools/lib/install-root.sh` | `7a52fc07…d7ba` | `installer/lib/install-root.sh` | `23886e2d…b1e7` | **改造**（117 行 diff）：Fedora root contract 名、特权位/capability 校验替代 snap-confine、SDDM/graphical.target/machine-id 首启、SELinux 告警；分区/挂载/backup/store/fstab/provision 逻辑保持上游 |
| `device/charger-mode/liuqin-charger-mode-exit.c` | `f23607de…4cfa6` | `installer/lib/liuqin-charger-mode-exit.c` | `822f1ca7…d6e6` | **逐字复用**（仅 +6 行来源注释）；`build-runtime.py` 交叉编译成静态 `usr/sbin/liuqin-reboot` |

## 本目录新建（非上游复制）

| 文件 | 作用 |
|---|---|
| `installer/build-runtime.py` | Fedora aarch64 包树 → installer runtime；参考上游 `tools/lib/build-installer-runtime.py` 的清单机制（同样 7 个 ELF + `mke2fs.conf` + 静态 reboot），改用无第三方依赖的 ELF 读取器 |
| `installer/assemble-installer.py` | 生成 RAM 安装器 overlay + `installer-image.json`（boot-builder 接口） |
| （已删除）installer/make-root-contract.py | ADR-0004 D1：重复的 v1 契约生成器已删除；唯一生产者是 `tools/build-root-contract.py`（契约 v2 拓扑语义） |
| （已删除）installer/make-bundle.py | ADR-0004 D1：重复的 bundle 生成器已删除；唯一生产者是 `scripts/build-image.sh`，唯一验证者是 `scripts/verify-bundle.sh` |
| `scripts/build-installer.sh` | runtime/overlay 一键构建（podman Fedora 容器 / mkosi rootfs / RPM 目录三种来源） |
| `tests/installer/*` | 离线测试；`test-layout.py`、`test-layout-sh.sh`、`test-host.py` 由上游 `tests/installer-layout.py`、`tests/install-layout.sh`、`tests/installer.py` 适配（同样 MIT，注明来源）；`fake-fastboot` 是本项目新增模拟器 |

上游测试适配说明：`test-host.py` 删去了依赖设备层 `device/gnome-overlay/usr/local/sbin/liuqin-switch`
的联合 fixture（本仓库尚未集成设备层），其余断言保留并增加 dry-run 写门控与 GPT 回滚分支；
`test-install-root.sh` 是本项目新增（上游只有函数级 `tests/install-root.sh`，本仓库未复制）。
