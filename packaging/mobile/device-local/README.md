# 本机旧启动链的 SLPI 配置

这里保留 2026-11-17 本机实际部署的服务覆盖源码，**不自动装入通用 RPM 或公开镜像**。
完整来源、固件清单、启动件、备份和实机范围集中在
自动旋转结果。

`20-old-slpi-firmware.conf` 对应本机
`/etc/systemd/system/liuqin-slpi.service.d/20-old-slpi-firmware.conf`。
本机仍保留 `/etc/liuqin-slpi-disabled`，这份覆盖明确用旧固件清单与逐文件 SHA256 校验替代原条件。
只有 manifest 存在且校验通过，服务才会启动；不能仅凭标记存在就认为 SLPI 仍被禁用。

固件来自用户自己 `modem_a` 的 `SLPI.HY.5.0-00192-WAIPIO-1`，与本机 2023 年启动链配套。
24 个文件放在 Linux 的固件优先目录 `/usr/lib/firmware/updates/qcom/sm8475/liuqin/`，
原新版文件保留。二进制和每机 registry 不入 Git；manifest 由这份已核验输入生成，
安装到 `/etc/liuqin/slpi-old-firmware.SHA256SUMS`，不可用别机文件或新版固件替换后绕过校验。

配套启动件启用 SLPI DT 节点，保留 `slpi_auto_boot=0`，并增加标准
`video=DSI-1:1800x2880@120,panel_orientation=right_side_up`。
正常开机由现有服务启动传感器，不需要临时绑定或手动命令。
显示布局只迁移原生分辨率与旋转，保留当前设置中的缩放值；**不安装开机强制缩放脚本**。
之后更换缩放仍使用 GNOME 设置，其保存的用户配置是正常来源。

需要恢复禁用时，先暂停代理和取数程序，再停止 SLPI，撤除这份条件覆盖并 reload systemd；
原标记随后重新生效。只重新创建标记不能覆盖这份 drop-in 的放行条件。
再按结果中的固定清单撤回新增固件/manifest、还原原显示布局；如需恢复 boot，
使用对应完整备份并按当次授权读回核验。**只恢复 boot 不会恢复固件与布局。**
