# 配置与定制源码

| 目录 | 角色 |
|---|---|
| [gnome](gnome/README.md) | GNOME 支持 RPM 的载荷，构建脚本从这里取文件 |
| [gnome-local](gnome-local/README.md) | 独立维护的电源/合盖、屏幕键盘、外观源码；尚未全部打包 |
| [afk](afk/README.md) | USB 维护通道来源；旧覆盖层含 KDE 默认，不能整体重装到当前 GNOME |
| `kde/` | 历史桌面配置及部分仍有设备规则出处的输入；不代表备用桌面，不能批量恢复或删除 |
| [boot](boot/README.md) | canonical DTB/ABL 注入适配 |
| [rootfs](rootfs/README.md) | 旧完整镜像的离线组装来源 |

源文件和模板不是现机配置读回。当前电源键无行为等用户反馈见桌面专题，设备配置修改另行安排、授权和核验。
