# 内核维护入口

正在运行什么、A/B 和恢复文件只在启动专题维护。不要用目录名或相同内核版本字符串猜构建身份。

| 目录 | 内容 |
|---|---|
| `config/` | Fedora/ZRAM 配置片段和审计输入 |
| [experiments/linux-7.3.1](experiments/linux-7.3.1/README.md) | 独立实验分支：直接迁移 7.3.1，离线构建通过，未实机验证 |
| [project-patches](project-patches/README.md) | 默认构建自动应用的显示、蓝牙、rpmh 修复 |
| [device-extras](device-extras/README.md) | 当前设备显式使用的诊断/USB/音频输入；不会自动加入默认构建 |
| [patches](patches/README.md) | 从锁定上游导出的队列，不手改；不是另一套本地修复队列 |
| `fedora/` | 内核 RPM、kernel-install、启动更新及元数据工具 |

内核构建方法、RPM/更新缺口、启动组装按需选读。
上游克隆只读，工作副本在无空格目录。新构建须核对配置、模块和 GNU Build ID；本页不会自动触发构建或设备测试。
