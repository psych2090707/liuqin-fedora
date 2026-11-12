# 维护与诊断工具

| 要做什么 | 入口 | 边界 |
|---|---|---|
| 通过 USB SSH 读取平板 | [AFK](afk/README.md) | 先用现有连接；up/dhcp/覆盖层安装可能改配置 |
| 查最近睡醒/亮屏记录 | [suspend-log](suspend-log/README.md) | 按需读取；日志不能单独证明睡眠足够省电 |
| 查日常/跨启动快照 | [低频日志](afk/daily-log/README.md)、[GPU watcher](afk/gpu-hang/README.md) | 保留已有取证，不用空 pstore 排除故障 |
| 基础诊断或日志包 | `diagnose.sh`、`collect-logs.sh` | 先查副作用；基础检查不等于功能验收，采集会写报告 |
| 复用现有 boot 的内核做 RAM 候选 | [repack-kernel-boot.py](repack-kernel-boot.py) `--help` | 钉住基线 boot SHA256，要求 release/config/模块/原始 DTB 配套；验证其他载荷和头不变；只离线组装，不操作设备 |
| 持续上传已审核的 Release 草稿 | [release/upload.py](release/upload.py) `--help` | 固定版本/提交/附件清单；保留摘要匹配的附件，只重试未完成项；显式 `--publish` 才在全部核验后公开，不支持单附件内部断点 |

旧安装续跑工具已退役。本地工具忽略目录与 `tools/afk/afk.env.example` 对应的实际配置是不提交的本地内容，不打印私人凭据，也不因目录整理擅动。
