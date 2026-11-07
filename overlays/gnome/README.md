# 当前 GNOME 配置源输入

本目录由 `scripts/build-gnome-rpm.sh` 打包为 `liuqin-gnome-support`，用于原地维护；旧 KDE 整机配方不会自动安装它。
本目录默认值是镜像/包内默认，不等于使用者之后在桌面里做的选择。

## 文件职责

| 输入 | 作用 |
|---|---|
| `etc/dconf/db/local.d/20-liuqin-gnome-input` | 中文输入/IBus 配置 |
| `etc/systemd/logind.conf.d/96-liuqin-gnome-lid.conf` | 合盖安全配置 |
| `etc/environment.d/60-liuqin-input.conf` | GNOME IBus 会话环境 |
| `etc/profile.d/zz-liuqin-wayland-input.sh` | 登录 shell 按桌面分流；兼容分支不代表 KDE 核心仍在 |
| `etc/dconf/db/local.d/10-liuqin-gnome-power` | 原生电源键 action=`nothing`，配合独立策略防双处理 |
| `etc/dconf/db/local.d/20-liuqin-gnome-lock` | 包内锁屏默认；不覆盖用户当前主动关闭的选择 |
| `etc/systemd/logind.conf.d/95-liuqin-power-keys.conf` | 不让 logind 抢电源键 |
| `etc/systemd/system/liuqin-power-keyd.service.d/30-gnome-action.conf` | 历史 GNOME helper 接口，当前由更后的 policy drop-in 覆盖 |
| `usr/libexec/liuqin/gnome-power-key-action` | 保留 GNOME 屏幕状态判断与跨锁屏周期保护；提供幂等 `ensure-off`/`ensure-on`，仍由 policy wrapper 调用 |

按键/合盖 policy helper 和 lid watcher 的维护源码在 `overlays/gnome-local/power/`，**不在这个包里**。实际状态以现场 `power-policy.conf` 和 `systemctl is-enabled` 为准。
屏幕键盘 v6、主题桥接和 GTK 渲染规避也有独立来源。见 [维护包职责和输入表](../../packaging/gnome/README.md)。

## 激活与验证边界

包没有 scriptlet，不自动切换登录管理器、启服务、改 PAM、挂起或重启。需要改设备时另列目标、备份、激活和读回步骤。
**首启 preset 陷阱**：`90-liuqin-power.preset` 现在 `enable liuqin-powerd.service` 并 `disable` 旧的 `liuqin-lid-policy`/`liuqin-power-keyd`；只 `systemctl enable` 会被 Fedora 首启的 `preset-all`（`99-default-disable.preset` = `disable *`）关掉。详见 [gnome-local README](../gnome-local/README.md)。
不要重跑旧迁移脚本，也不要用“默认锁屏 true”否定用户当前选择；原生 suspend 是另一套路径，当前由 Rust `liuqin-powerd` 统一处理，挂起前仍先显式锁屏。旧 helper 保留仅作回退。
