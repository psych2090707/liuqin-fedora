# MiPPS v0.7.0 的 Fedora 文件层

来源：[liuqin Ubuntu v0.7.0](https://github.com/yzddmr6/xiaomipad-6pro-mainline/tree/7661d6a1e9d44faff548770ab917185f864470e9/device/gnome-overlay)。
只导入认证 helper、两个 service 和一条 udev 规则。保留原代码声明；helper 为 GPL-2.0-only。
Fedora 仅改 `/usr/local/libexec/` 为 `/usr/libexec/liuqin/`，另提供电池认证 service 的 preset。

`scripts/build-device-rpms.sh` 将其作为独立子树加入 source tarball，relocator 最后覆盖这几个
文件；不修改 `upstream/`。不再携带旧的 allow-unverified-adapter drop-in。
先完成双电池认证，再等待本次接入的 PD 协商稳定，最后进行充电器认证。
小米认证最多重试三次；非小米来源不切数据角色，认证失败后可评估标准 PPS（包括 3 A）。
当前 unit 明确允许该标准 PPS 回退；普通固定 PD 不打开该路径。拔线清除本次接入结论。
程序可以等待慢协商直到拔线，systemd 不再用旧 30 秒启动超时将其提前杀掉。
目录沿用历史名称 upstream-v061，避免改变既有打包接口；内容版本以本页来源为准。

离线模拟验证见 `tests/upstream-refresh/mipps-role-first.py`，不是实机充电功率验收。
安装前应检查设备现有 `/etc/systemd/system` 覆盖和服务 mask；RPM 不应整包覆盖日用手工定制。
公开镜像现有禁用策略不在本次变更内；电池认证 helper 只服务初始化，不等于开启实机快充。
