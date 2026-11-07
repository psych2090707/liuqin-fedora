# 构建说明

公开仓库保留维护中的源码、配置、补丁和构建脚本。Release 的源码附件提供本版使用的上游源码和本地构建材料，版本以附件清单为准。

## 构建内核

本版采用 kernel.org 的 Linux 7.3.1，加上 `kernel/experiments/linux-7.3.1/patches/series` 中的设备补丁。准确来源和原始归档摘要在该目录的 `source.json`，最终配置及 GNU Build ID 记录随版本提供。

把 Release 附件 `linux-7.3.1.tar.xz` 放到 `out/kernel-7.3.1/downloads/`。在装有 aarch64 交叉 GCC/binutils、make、dtc、kmod 和 Python 的 Linux 电脑上，按目录 README 构建。工作目录需要无空格，且独立于只读上游克隆。

## 构建用户空间

`mkosi/` 默认使用 Fedora 45 / GNOME；基础账户默认 `user`。完整镜像由 `scripts/build-image.sh` 注入内核/设备包和配置，公开默认值通过 `--public-image --user user` 选择。

电源服务先用 `scripts/build-powerd.sh` 构建；它还会运行状态机测试。相应 Rust 工具链和依赖锁见 `rust/`。设备和移动栈软件包的配方在 `packaging/`，构建入口在 `scripts/`。

构建完整系统需要 rootful Podman、mkosi 和 qemu-user/binfmt。这些用于交叉构建，离线构建脚本不会因此刷写平板。镜像输出、工作目录和依赖缓存应放在独立的新目录，保留原有备份。

## 准备公开包

维护者先在本机生成完整候选并验证，再用 `tools/release/prepare-image.py export` 生成去固件的基础包。公开版只包含经过筛选的源码、基础镜像和对应源码附件；带入本地固件或密码的安装包留在使用者电脑上。

这一阶段记录原始 boot 结构和被移除文件的路径、摘要及元数据。使用者的 `prepare` 操作按这份清单恢复文件，保留数字属主、权限、ACL、capability 和 SELinux 扩展属性，并设置个人密码。

## 检查产物

已有检查覆盖 ext4 一致性、必要目录、内核与模块匹配、Android v2 结构、两份 ramdisk 的契约，以及去固件/补齐的完整文件比较。实际产物回归入口为：

```sh
python3 tests/release/test-public-image.py --help
python3 tests/installer/test-dry-run.py
```

测试只操作临时文件和模拟 Fastboot。实机首次安装、唤醒、续航和恢复测试仍须分别记录，不能由离线通过代替。
