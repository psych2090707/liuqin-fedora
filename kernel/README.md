# 内核维护入口

本目录存放 liuqin 的 Linux 7.3.1 设备适配、Fedora 内核 RPM 与启动更新工具，以及从锁定上游导出的补丁队列。发布的镜像和启动文件以 Release 说明为准；不要用目录名或相同内核版本字符串猜构建身份。

| 目录 | 内容 |
|---|---|
| `config/` | Fedora/ZRAM 配置片段和审计输入 |
| [experiments/linux-7.3.1](experiments/linux-7.3.1/README.md) | 当前发布的 7.3.1 适配：补丁、配置与离线构建脚本 |
| [project-patches](project-patches/README.md) | 默认构建自动应用的显示、蓝牙、rpmh 修复 |
| [device-extras](device-extras/README.md) | 额外的诊断/USB/音频输入；不自动加入默认构建 |
| [patches](patches/README.md) | 从锁定上游导出的队列，不手改 |
| `fedora/` | 内核 RPM、kernel-install、启动更新及元数据工具 |

内核构建方法见仓库根目录的构建说明和 [experiments/linux-7.3.1](experiments/linux-7.3.1/README.md)；启动镜像与更新接口见 `fedora/README.kernel-liuqin`。
上游克隆只读，工作副本放在无空格目录。新构建须核对配置、模块和 GNU Build ID；本页不会自动触发构建或设备测试。
