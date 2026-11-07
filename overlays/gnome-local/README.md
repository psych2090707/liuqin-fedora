# GNOME 独立定制的维护源码

本目录集中以前分散的维护输入。与 `overlays/gnome/` 的 RPM 载荷分开，**保持原有打包范围**。
电源键/合盖已切换为 Rust `liuqin-powerd`；旧 C/Python 文件仍作为回退保留。

## 首启 preset 陷阱（必读）

Fedora 首次启动会执行一次 `systemctl preset-all`。`/usr/lib/systemd/system-preset/99-default-disable.preset` 的内容是 **`disable *`**，所以：

- 镜像里用 `systemctl enable` 建立的启用链接，**不能保证首启后还在**；
- 只有被 `90-*.preset` 明确 `enable` 的服务才会保留；
- preset 文件按文件名排序，**第一个匹配行生效**，所以 `90-liuqin-power.preset` 会先于 `99-default-disable.preset`。

实机曾踩到这个坑：镜像里 `liuqin-lid-policy.service` 和 `liuqin-power-keyd.service` 都有启用链接，但首启日志出现 `Applying preset policy` / `Populated /etc with preset unit settings` 后，两个服务都变成 `disabled`，合盖整夜没有挂起。

因此：

- `power/etc/systemd/system-preset/90-liuqin-power.preset` 是**功能的一部分，不是可选文件**；
- 新增或改名任何需要开机自启的 liuqin 服务时，必须同步更新这个 preset；
- `scripts/build-image.sh` 会在镜像构建阶段执行 `systemctl preset` 并断言 `is-enabled`，缺失时直接失败，避免再次静默回归；
- 只改单元文件、只跑 `systemctl enable`、或只检查“文件存在”都不算完成。

| 目录 | 内容 | 来源 |
|---|---|---|
| `power/` | 电源设置应用、旧按键 wrapper、旧合盖服务、配置样例、窄范围 polkit 规则、`liuqin-powerd.service` 与 preset | 旧实现（回退用）；Rust 统一服务 unit/preset 的程序在 `rust/` |
| `keyboard/extension/` | v6 扩展与完整依赖：基础布局、快捷键、布局资源、三份 CSS | v6 包装与布局复用，以及核对过的 v4 基础文件；原始 `extension.js` 在此叫 `base-layout.js` |
| `keyboard/build/` | 小型布局生成器和资源打包脚本 | 只生成键盘资源，不构建系统 |
| `appearance/` | 亮暗桥接程序、用户服务、Ptyxis 双面配色 | 独立维护 |
| `stylus/` | GNOME 51 触控笔电量扩展；读 `qcom-battmgr-pen` sysfs，顶栏显示电量/充电状态 | 2026-11 新增 |

## 不能从这些源码推断什么

- **短按行为曾出现混乱，可能夹杂慢唤醒，合盖/打开也受影响**。现在由 `liuqin-powerd` 统一处理，但实机短按/合盖/唤醒仍需逐项验收；不能仅凭源码或服务 active 判体验通过。
- `power/etc/liuqin/power-policy.conf` 是维护默认值：`SHORT_ACTION=suspend`、`LID_ACTION=suspend`、`LID_RESUSPEND=1`。屏幕灭时第一下只唤醒，屏幕亮时才执行 `SHORT_ACTION`；合盖睡眠中短按保持屏幕灭。短按/盖子/恢复仍不能合并判通过。**关键前提是挂起前先调用 `org.gnome.ScreenSaver.Lock`、确认 `GetActive` 后再 suspend；`liuqin-powerd` 保留了这条路径，删掉会重现 GDM greeter 抢占和“半屏内核日志”。**
- `power/` 没有复制旧整套安装脚本；旧脚本会改现场设置，不能作为本目录的部署方式。
- `liuqin-powerd` 是 aarch64 Rust 二进制，构建方式见 [rust/README.md](../../rust/README.md)；镜像构建要求先运行 `scripts/build-powerd.sh`。
- 键盘 JS/资源已集中，布局生成器没有运行或改写资源；`expected.sha256` 校验的是布局数据。
- 壁纸、Light Style 和设备端备份不在仓库里凭空补造。

若要改设备，先针对目标写出精确文件、当前值、备份、激活、读回和恢复步骤，再执行；当前无一键重新部署入口。

## 离线检查

```sh
scripts/build-powerd.sh
python3 tests/desktop-admission/test-lid-policy.py
python3 tests/desktop-admission/test-lid-service.py
node tests/desktop-admission/test-layout-reuse.mjs
```

这些只验证 Rust 核心状态机/构建、旧 Python 状态机、私有测试总线和布局复用逻辑，
不证明现场按键或续航正常。
