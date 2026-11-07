# 构建与检查入口

| 目标 | 入口 |
|---|---|
| GNOME 配置支持包 | `build-gnome-rpm.sh`，载荷来自 `overlays/gnome/` |
| 指纹/设备/时间支持包 | `build-mobile-rpms.sh`、`build-device-rpms.sh`、`build-clock-rpm.sh` |
| 内核与启动输入 | `build-kernel.sh`、`build-kernel-rpm.sh`、`build-initramfs.sh`、`build-bootimg.sh`、`build-boot-tools-rpm.sh` |
| 上游来源与环境 | `fetch-upstream.sh`、`env-check.sh`；上游克隆只读 |
| 已有产物的离线检查 | `ci.sh --skip-build`、`verify-bundle.sh`；会依赖保留产物，不是文档检查 |

`build-rootfs.sh`、`build-image.sh`、`build-installer.sh`、`make-release-assets.sh` 和 rebase 工具保留的是完整镜像/研究接口，不因存在而成为当前安装、发布或升级任务。
参数以脚本帮助和对应指南为准。缺依赖时先查环境，不自动安装宿主软件、修改网络或恢复旧缓存。
