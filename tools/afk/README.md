# AFK：现有 USB SSH 通道工具

当前维护方法与安全边界见 docs/maintenance/afk-channel.md。先用现有连接，**不重新部署旧 KDE 覆盖层**。
设备为 GDM→GNOME，账户 `laplus`；用户名、密码和地址覆盖在私有 `afk.env`，不要把历史默认值当成当前凭据。

```sh
tools/afk/afk.sh run 'id; systemctl --failed'
tools/afk/afk.sh status
tools/afk/afk.sh doctor
```

## 当前有用的组成

| 文件/目录 | 作用 |
|---|---|
| `afk.sh`、`lib/common.sh` | SSH、sudo、传输、状态；传入命令决定是否修改设备 |
| `afk.env.example`、`keys/` | 私有配置格式和密钥工具；示例不是现机配置 |
| `daily-log/` | 已部署低频采样，按其 README 读取/汇总 |
| `gpu-hang/` | 已部署 GPU 取证，只记录不修复 |
| `capture-crash.py`、`crash-forensics/` | 跨启动采集与早期归档；取证边界 |
| `build-repo.sh`、`serve-repo.sh` | 必要时离线 RPM 传输；旧默认包表是 KDE 初次部署输入 |

## 保留但不用于当前日常续接

- `setup` 只生成本地配置/密钥/状态目录，不再打包或推荐部署旧覆盖层；不是只读环境检查。
- `up`/`dhcp` 可能修改电脑 USB 网络或启动服务，先遵守宿主网络保护规则。
- `overlay-install`/`overlay-uninstall` 与 `build-overlay.sh` 保留原始 KDE 部署实现和回归输入，不作为 GNOME 修复方法。
- `shot`/`rdp` 是旧 KWin/Spectacle/KRDP 路线，不支持当前 GNOME；工具不会因缺少 KRDP 建议恢复旧桌面。
- `tests/device-acceptance.sh`、`tests/chroot-install-check.sh` 检查旧开发覆盖层，不是现机全自动验收。
- `tests/offline-check.sh` 只离线检查；不得重载宿主 NetworkManager 来“验证配置”。

快照/取证的针对性回归见 `tests/test-snapshot-retention.py`、`tests/test-crash-forensics.py`、`tests/test-daily-log.py`。
不为文档清理运行覆盖层安装、chroot、整机模拟或硬件测试。原始部署全文见 历史 AFK 设计。
