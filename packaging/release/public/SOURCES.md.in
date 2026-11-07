# 对应源码

Release 同时提供系统下载和源码材料。安装系统只需要基础镜像分卷；想研究、修改或重新构建时，再下载下面的源码附件。

## 项目代码

本仓库包含本版使用的构建脚本、设备配置和本地补丁。公开历史从首次整理后的版本开始，上游版权、文件级许可和来源说明保留。

## 内核

`linux-7.3.1.tar.xz` 是对应的原始完整源码。项目的 7.3.1 补丁、配置和构建脚本在 `kernel/experiments/linux-7.3.1/`；两者一起用于重建本版设备内核。Linux 内核和衍生补丁遵循 GPL-2.0 及各文件标明的许可。

## 本地组件

`sources-local.tar.zst` 收录移动栈的原始源码/补丁、设备工程的开源部分、AudioReach topology、BusyBox 源码和配置、AOSP mkbootimg，以及 Rust 依赖和本地构建材料。每个组件继续保留自己的版权和许可证。固件二进制、设备校准和私人数据不在这份附件中。

## Fedora 软件包

`sources-fedora.tar.part-*` 提供镜像中 GPL/LGPL 软件对应版本的源 RPM。合并后是普通 tar 包，可解出 `.src.rpm`、`sources.json` 和 `SHA256SUMS`。清单记录准确文件名、官方下载位置及本版核对的摘要。

源 RPM 通常包含上游源码、Fedora 补丁和 spec 配方。具体使用 `rpm2cpio`、`rpmdevtools` 或 Fedora 的 RPM 构建工具查看和重建；这些源包无需安装到平板上。

## 许可

根目录 [LICENSE](LICENSE) 用于项目原创代码。内核、GNOME 衍生资源、传感器栈、指纹组件和其他第三方材料各自保留原许可；[NOTICE](NOTICE)、`LICENSES/` 及相应源码里的声明给出详细信息。

厂商固件仍归其所有者。使用者在自己的电脑上补入固件后生成的 `prepared/` 安装包留作自用，不属于本项目公开下载的附件。
