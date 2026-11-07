# 软件包源码

当前维护优先原地更新单个组件，不重新生成完整系统。

| 目录 | 用途 |
|---|---|
| [gnome](gnome/README.md) | GNOME 按键/输入等支持包；并不覆盖全部个性化 |
| [device](device/README.md) | 固件、音频和基础设备服务 |
| `mobile/` | 指纹及传感器栈；不要为体检启动 SLPI |
| `boot-tools/` | 设备端启动重建资产 |
| [clock](clock/README.md) | 时间保存与开机恢复支持 |
| [libadwaita](libadwaita/README.md) | 设置/商店等 libadwaita 列表控件的 Adreno 马赛克范围规避；本地补丁，包升级会覆盖 |

内核 RPM 实现在 `kernel/fedora/`。构建入口见[脚本导航](../scripts/README.md)。源码变动不会自动更新已安装包；设备安装与激活需要单独核对。
