# GNOME 原地维护包

`liuqin-gnome-support` 管理 GNOME 的输入环境、中文配置及部分按键/锁屏配置，不依赖 KDE。
当前用户选择与使用问题看桌面专题，包内默认值不等于设备当前值。

## 输入和构建

**完整载荷来自 [overlays/gnome](../../overlays/gnome/README.md)**，包含原 TN0077 的合盖安全配置和 TN0078 的中文配置；构建不再读取任务目录。

构建入口：`scripts/build-gnome-rpm.sh <全新输出目录>`，复用已有 rootful Fedora 44 ARM64 builder 和 binfmt。只构建这个软件包，依赖不齐则失败，不安装宿主软件或改网络。

包无激活脚本，不自动切换 GDM、启服务、改 PAM、挂起或重启。设备安装和必要的 dconf/服务刷新按当次授权实施，不能以 RPM 安装成功代替功能确认。

## 还有什么没有被这个包管理

| 内容 | 维护源码 |
|---|---|
| 电源设置应用、按键 wrapper、合盖服务与窄授权规则 | `overlays/gnome-local/power/` |
| v6 屏幕键盘、基础布局与资源 | `overlays/gnome-local/keyboard/` |
| 外观桥接与 Ptyxis 双面配色 | `overlays/gnome-local/appearance/` |

详见[独立定制](../../overlays/gnome-local/README.md)。这些从旧任务提取，但没有悄悄纳入 RPM 或重新部署；不整体重装旧覆盖层来同步。
**已装 1.0-3 包中的显示 helper 早于后来手动部署的闭盖保护版本，不直接 reinstall 该旧包**，以免覆盖现场。仓库 overlay 已含后续 helper，下一次正式打包仍需验证新包和激活范围。

历史部署与回退见 TN0083。旧回退依赖当时的 PAM、display-manager 和备份，不能整库恢复 dconf、删除钥匙环或重新启用已移除的 KDE。
当前登录/钥匙环见桌面，内核自动更新缺口见更新。旧 mkosi 完整镜像仍是 KDE 配方，不是本机维护入口。
