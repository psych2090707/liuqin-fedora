# 软件包源码

当前设备使用原地维护，先选要改的组件，不重新生成完整系统。

| 目录 | 用途 |
|---|---|
| [gnome](gnome/README.md) | GNOME 按键/输入等支持包；并不覆盖全部个性化 |
| [device](device/README.md) | 固件、音频和基础设备服务 |
| `mobile/` | 指纹及传感器栈，见维护边界；不能启动 SLPI 做体检 |
| `boot-tools/` | 设备端启动重建资产，见接口 |
| [clock](clock/README.md) | 时间保存与开机恢复支持 |
| [libadwaita](libadwaita/README.md) | 设置/商店等 libadwaita 列表控件的 Adreno 马赛克范围规避；本地补丁，包升级会覆盖 |

内核 RPM 实现在 `kernel/fedora/`。构建入口见[脚本导航](../scripts/README.md)，版本/部署缺口看更新专题。源码变动不会自动更新已安装包，设备安装与激活按本轮授权安排。
