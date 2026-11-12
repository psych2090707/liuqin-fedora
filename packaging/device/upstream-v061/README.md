# MiPPS v0.6.1 的 Fedora 文件层

来源：[liuqin Ubuntu v0.6.1](https://github.com/yzddmr6/xiaomipad-6pro-mainline/tree/v0.6.1/device/gnome-overlay)。
只导入认证 helper、两个 service 和一条 udev 规则。保留原代码声明；helper 为 GPL-2.0-only。
Fedora 仅改 `/usr/local/libexec/` 为 `/usr/libexec/liuqin/`，另提供电池认证 service 的 preset。

`scripts/build-device-rpms.sh` 将其作为独立子树加入 source tarball，relocator 最后覆盖这几个
文件；不修改 `upstream/`。不再携带旧的 allow-unverified-adapter drop-in。
默认要求当前接入的认证，先完成双电池认证，再稳定合同/数据角色，最后进行充电器认证。
非小米协议来源不切数据角色；拒绝切换、拔线、失败均停止本次适配器命令。

离线模拟验证见 `tests/upstream-refresh/mipps-role-first.py`，不是实机充电功率验收。
安装前应检查设备现有 `/etc/systemd/system` 覆盖和服务 mask；RPM 不应整包覆盖日用手工定制。
公开镜像现有禁用策略不在本次变更内；电池认证 helper 只服务初始化，不等于开启实机快充。
