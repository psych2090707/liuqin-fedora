# Liuqin Linux — Fedora Remix for Xiaomi Pad 6 Pro

为小米平板 6 Pro（**liuqin / SM8475**）适配的个人社区项目，使用 Fedora 45、GNOME 51 和 Linux 7.3.1。不是 Fedora、Red Hat 或小米的官方产品。

**首版是实验性预发布。新的完整安装组合仅完成离线检查，尚未独立验证从原厂 Android 开始的完整安装。** 已有单台维护设备运行这些核心组件的证据，不代表所有批次或容量都能正常安装。

## 开始安装

系统下载在本仓库 **[Releases](https://github.com/psych2090707/liuqin-fedora/releases)**。GitHub 自动提供的 “Source code” 压缩包是项目源码，**不是系统镜像**。

- 首版只提供 Linux 单系统的实验安装路径，会清除 Android 用户数据。先读 **[安装说明](INSTALL.md)**。
- 公开镜像不含再分发许可未确认的厂商固件。使用者必须自行准备指定固件，在自己的电脑上运行本地补齐工具；该工具同时让使用者设置自己的密码。
- 镜像账户为 **`user`**，家目录 `/home/user`。没有共享默认密码，不包含维护者个人文件、网络凭据、校准或指纹模板。
- Android/Fedora 双系统仅列为未来计划，**未经验证，首版安装包拒绝双系统模式**。

## 镜像包含什么

默认包括设备启动和显示适配、匹配的内核模块、无线/音频/触控支持、电源键和合盖策略、键盘套防误唤醒，以及触控笔坐标修复和电量/充电状态界面。厂商固件需本地补齐。

自定义屏幕键盘、输入快捷键和浅色主题/外观同步预装但默认关闭。输入定制仍未完善，默认使用原生 GNOME/IBus。见 [可选功能](OPTIONAL.md)。

## 使用前请了解

见 **[硬件状态](HARDWARE.md)**。目前仍包括控件色块、声音发闷、蓝牙睡醒失效、NVT 偶发恢复失败、自动旋转未解决和相机限制。完整内核自动更新/恢复链尚未验收；不要混用不同版本的 boot、模块或安装文件。

这是个人业余项目，按现状提供，不承诺保修、救砖、数据恢复、逐一远程协助或固定更新期限。软件许可证中的免责条款不能代替备份和谨慎操作，也不代表在所有情况下都能排除法律责任。风险与反馈要求见 [支持说明](SUPPORT.md)。

## 项目来源

- [构建说明](BUILD.md)、[对应源码与许可](SOURCES.md)
- [一般使用建议](GENERAL-RECOMMENDATIONS.md)
- 设备适配主要参考 [yzddmr6/xiaomipad-6pro-mainline](https://github.com/yzddmr6/xiaomipad-6pro-mainline)、[yzddmr6/linux-sm8450-liuqin](https://github.com/yzddmr6/linux-sm8450-liuqin) 和 [Seeker0472/liuqin-nixos](https://github.com/Seeker0472/liuqin-nixos)；Fedora 构建参考 [pipa-fedora-builder-43](https://github.com/rr1111/pipa-fedora-builder-43)。**pipa 是另一款设备，不能混用镜像。**

原创代码沿用 [MIT](LICENSE)；第三方代码和内核补丁保留其原许可，见 [NOTICE](NOTICE) 和 `LICENSES/`。公开仓库从审核后的当前成果开始，不包含维护者本地工作记录和旧 Git 历史。
