# 对应源码

Release 同时提供系统下载和源码材料。安装系统只需要基础镜像分卷；想研究、修改或重新构建时，再下载下面的源码附件。

## 项目代码

本仓库包含本版使用的构建脚本、设备配置和本地补丁。公开历史从首次整理后的版本开始，上游版权、文件级许可和来源说明保留。

## 内核

`linux-7.3.5.tar.xz` 是对应的原始完整源码。使用 `kernel/experiments/linux-7.3.5/build.sh` 重建本版设备内核，补丁序列也会引用仓库中沿用的 7.3.1 设备适配。Linux 内核和衍生补丁遵循 GPL-2.0 及各文件标明的许可。

## 本地组件

`sources-local.tar.zst` 收录移动栈的原始源码和补丁、设备工程的开源部分、AudioReach topology、BusyBox、AOSP mkbootimg、Rust 依赖，以及本版时钟与 libwacom 软件包的构建输入。其中 `kernel-final.config` 与 `kernel-build.json` 记录实际发布内核。各组件保留原有版权和许可证。

## Fedora 软件包

本版沿用 alpha.2 的 Fedora 基础软件包版本，新增的相机插件与原 PipeWire 来自同一个源 RPM。既有 GPL/LGPL 源 RPM 继续由 [alpha.2 源码分卷](https://github.com/psych2090707/liuqin-fedora/releases/tag/v0.1.0-alpha.2) 提供。下载该页的 `sources-fedora.tar.part-*` 和 `SOURCES.SHA256`，合并为 `sources-fedora.tar` 后校验，解包可获得源 RPM 及逐件校验清单。

源 RPM 通常包含上游源码、Fedora 补丁和 spec 配方。具体使用 `rpm2cpio`、`rpmdevtools` 或 Fedora 的 RPM 构建工具查看和重建；这些源包无需安装到平板上。

## 许可

根目录 [LICENSE](LICENSE) 用于项目原创代码。内核、GNOME 衍生资源、传感器栈、指纹组件和其他第三方材料各自保留原许可；[NOTICE](NOTICE)、`LICENSES/` 及相应源码里的声明给出详细信息。

厂商固件仍归其所有者。使用者在自己的电脑上补入固件后生成的 `prepared/` 安装包留作自用，不属于本项目公开下载的附件。
