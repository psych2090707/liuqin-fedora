# 60-liuqin-usb — 产品层 USB NCM 链路与 DHCP

这层只提供 **产品功能**：让 initramfs 创建的 USB NCM gadget 在正式系统里继续可用。

- `usb0` 固定为 `192.168.7.2/24`；
- 平板在 `usb0` 上运行 dnsmasq，只做 DHCP，给主机发 `192.168.7.10–19`；
- 不发 router/DNS，主机不会把默认路由指到平板；
- NetworkManager 不接管 `usb0`；
- USB role / Type-C 变化时重新拉起链路服务。

这里**不包含**任何 `afk-*` 维护通道内容（SSH 维护配置、boot snapshot、KRDP、afk-health 等）。
AFK 是独立的维护叠加层（`overlays/afk/`），只在维护镜像或维护设备上应用。

## 文件

| 路径 | 作用 |
|---|---|
| `usr/libexec/liuqin/liuqin-usb0-up` | 幂等地把 usb0 设为 `192.168.7.2/24` 并 up |
| `etc/systemd/system/liuqin-usb0-link.service` | 调用上面的脚本，`Before=network.target sshd.service` |
| `etc/systemd/system/liuqin-usb0-dhcp.service` | dnsmasq，只做 `usb0` 的 DHCP |
| `etc/liuqin/usb0-dnsmasq.conf` | DHCP 范围与 lease 路径 |
| `etc/NetworkManager/conf.d/90-liuqin-usb0-unmanaged.conf` | NM 不接管 usb0 |
| `etc/udev/rules.d/72-liuqin-usb-role.rules` | USB role/Type-C 变化时重启 link 服务 |
| `etc/systemd/system-preset/90-liuqin-usb.preset` | **首启保活**，见下 |

## 首启 preset 陷阱（和电源服务同一类）

Fedora 首启执行 `systemctl preset-all`，`99-default-disable.preset` 是 `disable *`。
只 `systemctl enable` 的 unit 会在首启被关掉。因此本层必须带：

```text
/etc/systemd/system-preset/90-liuqin-usb.preset
```

`install.sh` 会在镜像阶段执行 `systemctl preset` 并断言两个 unit 是 `enabled`；
如果 preset 缺失或失效，构建直接失败。

## 与 AFK 维护层的边界

- 产品镜像只装本层；`afk-*` 不出现。
- AFK 维护层如果建立在已有 `liuqin-usb0-link/dhcp` 的镜像上，只应添加维护工具，
  不要再装自己的 USB 地址/DHCP unit，避免两个 DHCP 服务器。
- 旧 F44 的 `afk-usb0-*` 只作为维护层遗留；不要复制进产品层。
