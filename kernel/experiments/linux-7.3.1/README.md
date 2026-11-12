# Linux 7.3.1：liuqin 设备内核适配

本目录是当前发布镜像使用的 7.3.1 设备内核输入：补丁、配置、离线构建脚本和归集工具。它不替换仓库的默认通用内核流程；构建和启动身份以 Release 说明及本目录输出的 `build-info` 为准。

Ubuntu 0.6.1 修复的独立离线移植使用 [refresh profile](refresh/README.md)，在原队列后追加
15 组补丁、使用不同 release。已 RAM 启动核对身份，人工功能/短睡眠待验收，不替换下面的既有验收。

## 输入

- `source.json`：准确的 kernel.org 7.3.1 tarball SHA256、原产品锁与社区参考 revision。
- `patches/series`：对纯净 7.3.1 按顺序应用的 12 组设备适配、1 份独立上游修复、1 份 7.3 音频回归修复、1 份笔坐标倍率修复、1 份 early-wake 诊断记录器，以及笔电量只读/显示两份补丁（共 18 组），不是给旧 6.17 树的增量。
- `0013-upstream-dsi-pll-system-muxes.patch`：首次 PHY enable mux 漏写修复；保留上游提交线索和本机寄存器证据，撤除条件见补丁头。
- `0016-liuqin-early-wake.patch`：把 6.17 的只读 early-wake 记录器移植到 7.3.1（`arm`/`status`/`events`，默认 idle、不记录）；挂在 suspend、GIC、IPCC、pmic_glink 的只读钩子上，用于诊断“醒了但不对”的早返回。
- `0015-input-touchscreen-novatek-liuqin-pen-scale.patch`：笔报告与手指同用 1/10 像素单位，原默认 `pen_coord_scale=1` 把所有笔坐标钳到面板右下角；实测后默认改为 `NVT_COORD_SCALE`（10）。
- `0017-power-supply-qcom-battmgr-liuqin-pen-status.patch`：把 liuqin 原厂的笔 MAC、TX 电流/电压、SOC、双霍尔和反向充电状态以只读属性加到 `sm8475_raw`，不改充电行为。
- `0018-power-supply-qcom-battmgr-liuqin-pen-supply.patch`：在 `0017` 基础上注册标准 `qcom-battmgr-pen` 电源设备（`scope=Device`），用 MAC/霍尔判断在位、TX 判断充电、SOC=100 判断充满；供 UPower/GNOME 显示。第一次检测到笔时才动态注册，避免 UPower 启动时因 `present=0` 不枚举；`NOTIF_XM_PROPERTY` 用 `mod_delayed_work` 提前，笔在位 60 秒、不在位 5 分钟兜底。已 RAM 验证并用于发布镜像。
- `0001-board-and-bindings.patch` 中的显示保留区使用 `linux_splash@b8000000`：让 ABL 的 `UpdateSplashMemInfo()` 先调用 `DisableDisplay()`，Linux 冷初始化面板。若改回 `splash_region`，ABL 会保留活动显示，7.3 需要额外的 GDM 前置 OFF/ON，且正常槽启动会卡在 GDM。
- `0014-legacy-tdm-sink.patch`：补回 7.3 删除的旧 AudioReach TDM sink 处理；厂商 ADSP 固件仍要求 topology 使用 `0x0700100E`，缺失时 `APM_CMD_GRAPH_START` 在 `TERTIARY_TDM_RX_0` 失败。只接受 48 kHz、24-bit、4 声道、32-bit slot 的扬声器元组。
- `patch-manifest.json`：各组文件清单和补丁 SHA256，原代码版权声明保留。
- `seed.config`：基线配置；`experiment.config` 负责独立版本名、QCE/RNG、新版 bool 规范化及 fbdev 控制台（关闭已触发 restore 告警的 DRM log）。
- `modules/pon/`：保留的只读取证模块，在新内核环境单独重编。

复用 [liuqin-nixos](https://github.com/Seeker0472/liuqin-nixos/tree/eadaad6e032dbc0c3fc96347d5cf5bc78715827c) 的 7.2.5 设备补丁，
本次编译基线始终为 7.3.1。未采用其 NixOS 用户态、安装器、U-Boot、私有固件或 DP 寄存器捕获数据。
Linux 衍生补丁遵循原 GPL-2.0/逐文件许可，helper 为 MIT；相机表等来源沿用其
[NOTICE](https://github.com/Seeker0472/liuqin-nixos/blob/eadaad6e032dbc0c3fc96347d5cf5bc78715827c/NOTICE)。不含固件、校准或个人数据。

## 复现离线构建

沿用系统交叉 GCC/binutils、make、git、dtc、kmod/depmod、Python 和已有内核构建依赖，无需 Nix/RPM 或系统配置修改。
官方归档放在 `out/kernel-7.3.1/downloads/linux-7.3.1.tar.xz`；脚本先校验 SHA256，本身不联网。
归档缺失时仅下载 `source.json` 指定的官方 URL。

```bash
# 项目根执行；WORK 必须是新的、无空格且不在 upstream/ 的目录。
LIUQIN_731_WORK=/var/tmp/liuqin-linux-7.3.1-rebuild \
LIUQIN_731_OUT="$PWD/out/kernel-7.3.1/rebuild" \
JOBS=10 bash kernel/experiments/linux-7.3.1/build.sh
```

加 `--prepare-only` 只重放补丁、生成配置/启动头。输入变化时须换新 WORK；脚本不会清空无标记旧目录。
配置片段先复制到无空格路径，模块仅安装到 WORK staging，不安装到宿主或平板。
输出 Image/raw DTB、匹配模块/压缩包、完整配置、vmlinux/符号、来源和哈希。
构建时间和工具链变化可能改变二进制；本目录验证补丁重放及源码/配置一致性，不承诺跨环境二进制一致。
`collect.py` 只归集完成的构建，不部署，也不生成 Android boot image。

## 边界

release 固定为 `7.3.1-liuqin-exp1`，不与旧模块目录重名；FPC 保持原 SPI 接口，PON 单独重编，不能混用 6.17 模块。
SLPI 在 DT disabled 且自动启动默认关闭；设备禁用标记保留。
`prepare-ram.py` 从锁定的 boot ramdisk 增加匹配模块和 `activate-ram.sh`，只在 tmpfs 提供模块/FPC 视图，跳过 slot-success 写入；固件和 root 契约保持原字节。可用 `LIUQIN_731_DIST` 和 `LIUQIN_731_RAM_OUT` 指向独立构建输出和 initramfs 目录，避免覆盖旧证据。
`display-cycle.py` 保留为诊断/恢复工具，但默认 initramfs 不再安装 GDM 前置循环；正常启动改由 `linux_splash` 让 ABL 先关闭显示。它等待 msmdrmfb、核对实际内核 notes、拒绝已存在的 userspace DRM master，结果写本次 `/run/liuqin-ram-display.json`。该步骤不能据 ioctl 成功代替用户出图验收。
RAM 镜像须用 canonical ABL DT 和原启动参数组装，实际 Build ID 核对后才能归属测试结果。本目录没有刷写或切槽命令。
