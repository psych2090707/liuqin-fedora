# GNOME 原地维护包

`liuqin-gnome-support` 管理 GNOME 的输入环境、中文配置及部分按键/锁屏配置，不依赖 KDE。
包内默认值不等于设备当前值。

## 输入和构建

**完整载荷来自 [overlays/gnome](../../overlays/gnome/README.md)**，包含合盖安全配置和中文配置；构建不再读取任务目录。

构建入口：`scripts/build-gnome-rpm.sh <全新输出目录>`，复用已有 rootful Fedora 45 ARM64 builder 和 binfmt。只构建这个软件包，依赖不齐则失败，不安装宿主软件或改网络。

包无激活脚本，不自动切换 GDM、启服务、改 PAM、挂起或重启。RPM 安装成功不能代替功能确认。

## 还有什么没有被这个包管理

| 内容 | 维护源码 |
|---|---|
| 电源设置应用、按键 wrapper、合盖服务与窄授权规则 | `overlays/gnome-local/power/` |
| 定制屏幕键盘、基础布局与资源（版本/现场加载情况见桌面专题） | `overlays/gnome-local/keyboard/` |
| 外观桥接与 Ptyxis 双面配色 | `overlays/gnome-local/appearance/` |

详见[独立定制](../../overlays/gnome-local/README.md)。这些从旧任务提取，但没有悄悄纳入 RPM 或重新部署；不整体重装旧覆盖层来同步。
**已装旧包中的显示 helper 可能早于后来手动部署的闭盖保护版本，不要直接 reinstall 旧包**，以免覆盖现场。仓库 overlay 已含后续 helper，下一次正式打包仍需验证新包和激活范围。

旧回退依赖当时的 PAM、display-manager 和备份，不能整库恢复 dconf、删除钥匙环或重新启用已移除的 KDE。旧 mkosi 完整镜像仍是 KDE 配方，不是当前维护入口。

## libwacom 内屏笔自动映射

[补丁](patches/libwacom-2.19.0-liuqin-spi-digitizer.patch)让 libwacom 识别真实的 SPI 总线，并为
liuqin 的 `NVTCapacitivePen` 提供内置数位板条目。GNOME 使用内置设备标志匹配内屏，
沿用自己的方向矩阵。数据条目面向本项目设备，匹配 SPI、零厂商/产品 ID 和精确输入设备名。

用 [Fedora 2.19.0-2.fc45 源 RPM](https://kojipkgs.fedoraproject.org/packages/libwacom/2.19.0/2.fc45/src/libwacom-2.19.0-2.fc45.src.rpm)
的 spec 和原始源码。在 spec 的 `Source0` 后声明补丁，保留 `%autosetup -S git`，
本地 Release 为 `2%{?dist}.liuqin1`。在独立 F45 ARM64 容器中运行
`dnf builddep` 和 `rpmbuild -bb`。模拟器中的 `%meson_test` 可加 `--timeout-multiplier 6`。
成对安装同版本的 `libwacom` 和 `libwacom-data`，新 GNOME 会话会载入它们。
替换前核对更新版本是否已支持同一 SPI 设备。问题、实机验证和回退
