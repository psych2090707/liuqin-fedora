# libfprint-tod：复用锁定 TOD 开源代码的 Fedora 构建

状态（2026-10-20）：**完成（verified-offline）** —— 源码核实 PASS、3 个 Fedora 44 aarch64 RPM
构建成功、离线验证 PASS（`packaging/mobile/fingerprint/verify-libfprint-tod.sh`）。
结论分级：**源码可复现构建/包可安装/TOD 可枚举 = `verified-offline`；指纹录入/解锁 = `pending-device`**。
没有实机录入/解锁证据时不得宣称可用。

## 1. 事实：Fedora 没有 TOD，但 TOD 源码是公开的 LGPL 开源代码

liuqin 指纹适配器 `fpc1264-oem.c` 需要 `pkg-config libfprint-2-tod-1`（TOD ABI）。
TOD 不是 liuqin 私有二进制，而是 Ubuntu 维护的 **libfprint 开源分支**：

| 项目 | 值 |
|---|---|
| 锁定来源（liuqin `SOURCE_LOCK.json`） | `https://archive.ubuntu.com/ubuntu/pool/main/libf/libfprint/libfprint_1.95.1+tod1.orig.tar.bz2` |
| SHA256 | `b04c55ce1b1f0bcf97ca6e9e3dfbcad931ac2e8f87c29548c93d1aa69d9f6c60` |
| Ubuntu 源包 | `libfprint 1:1.95.1+tod1-0ubuntu2`（dsc，PGP 签名，resolute/26.04 更新） |
| 上游公开仓库 | <https://gitlab.freedesktop.org/3v1n0/libfprint>，分支 `tod`，tag `v1.95.1+tod1` |
| 当前 tag 指向 | `17b3bfda0174c0034f9dc8b11d67339e46eb928b`（= `tod` 分支 HEAD） |
| 许可证 | **LGPL-2.1-or-later**（`COPYING` 为 LGPL-2.1；TOD 扩展文件头为 LGPL-2.1+，作者 Marco Trevisan/Canonical） |
| 性质 | 开源源码包（Ubuntu 维护的派生分支），**不是**许可不明的二进制 |

"复用其他发行版维护的开源源码、在 Fedora 重新构建 RPM" 与 "安装/再分发 Ubuntu 二进制 deb"
是两件事。本任务只下载上述**源码 tarball**（校验 SHA256），在 Fedora 44 aarch64 容器内重新编译，
不下载、不再分发任何 Ubuntu 二进制包。

## 2. 构建产物与 Fedora 官方 libfprint 的关系（设计决策）

Fedora 44 的 `libfprint 1.94.100` 是上游正式版，**没有 TOD 支持**：TOD 驱动加载
（`FP_TOD_DRIVERS_DIR`、`FP_DRIVERS_ALLOWLIST`）在 TOD fork 的 libfprint 里实现
（`libfprint/fp-context.c`、`libfprint/tod/tod-shared-loader.c`），不在 fprintd 里。
Ubuntu 的做法是让系统的 libfprint 就是 TOD fork（`libfprint-2-2` + `libfprint-2-tod1` 两个包，
同一源码）。本项目**不采用"替换 Fedora 系统 libfprint"**，而用**独立路径共存**：

| 项 | 系统 Fedora 包 | 本项目私有包 |
|---|---|---|
| 包名 | `libfprint` 1.94.100 | `libfprint-tod` 1.95.1+tod1 |
| 库路径 | `/usr/lib64/libfprint-2.so.2` | `/usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2` + `libfprint-2-tod.so.1` |
| 使用者 | Fedora `fprintd`、PAM、KDE | 仅 `liuqin-fprintd-oem`（私有 daemon，unit drop-in 设 `LD_LIBRARY_PATH`） |
| udev rules/hwdb/metainfo | 由 Fedora 包安装 | 不安装，避免文件冲突（`-Dudev_rules=disabled -Dudev_hwdb=disabled`） |

理由：Fedora `fprintd 1.94.5` 明确依赖 `libfprint-2.so.2()(64bit)` 与
`libfprint-2.so.2(LIBFPRINT_2.0.0)(64bit)`。若私有 TOD 包声明同名 soname provide 且本地 repo
优先级更高，dnf 可能选它来满足 fprintd 依赖，但该库不在默认 `ld.so` 路径上 → 系统 fprintd
运行时加载失败。因此：

- `libfprint-tod` 用 `%__provides_exclude_from` **屏蔽** `libfprint-2.so.2` 的自动 provide
  （只保留私有的 `libfprint-2-tod.so.1`）；
- `liuqin-fpc1264-tod`（适配器包）`AutoReqProv: no` + 显式 `Requires: libfprint-tod`，
  避免自动 soname 依赖被 Fedora libfprint 满足；
- 私有库目录不进 `/etc/ld.so.conf.d`，只有 `liuqin-fprintd-oem.service` 通过 drop-in
  `LD_LIBRARY_PATH` 加载。

ABI 兼容性证据（离线）：TOD fork 版本 1.95.1+tod1，`libfprint-2.so.2` soname 与符号版本
`LIBFPRINT_2.0.0` 与 Fedora 1.94.100 相同；`libfprint-2-tod.so.1` 单独 soname/符号版本
`LIBFPRINT_TOD_1.*`。现有 `fprintd-oem` 二进制（按 Fedora libfprint 1.94 头文件构建）在
`LD_LIBRARY_PATH` 指向私有 TOD 构建时应能直接加载 —— 以实际符号检查为准（见 §4 验证）。
如果符号检查发现缺口，最小修复是让 `fprintd-oem` 按 TOD devel 头文件重建，而不是改 TOD 源码。

## 3. 包清单（本次新增）

| RPM | 内容 | 安装位置 |
|---|---|---|
| `libfprint-tod-1.95.1+tod1-1.liuqin.fc44.aarch64` | TOD fork 私有副本：`libfprint-2.so.2*`、`libfprint-2-tod.so.1*` | `%{_libdir}/liuqin-fingerprint/libfprint-tod/` |
| `libfprint-tod-devel-…` | 私有头文件 + 私有 pkg-config（`libfprint-2-tod-1.pc`） | `%{_includedir}/liuqin-fingerprint/`、`%{_libdir}/liuqin-fingerprint/pkgconfig/` |
| `liuqin-fpc1264-tod-1.0-1.liuqin.fc44.aarch64` | `libfprint-tod-fpc1264-oem.so`、`fpc-oem-print`、`liuqin-fprintd-oem.service.d` drop-in | `/usr/libexec/liuqin-fingerprint/{tod/,}` |

构建入口（网络可用时）：

```sh
scripts/build-mobile-rpms.sh fingerprint-tod
```

脚本从 `upstream/.../device/fingerprint/oem/SOURCE_LOCK.json` 读取 URL+SHA256，
下载/校验后在 `out/rpms-mobile/` 产出上述 RPM，并更新 `SHA256SUMS`/`build-info.json`。
不联网时可用已缓存的 `out/rpms-mobile/src/tarballs/libfprint_1.95.1+tod1.orig.tar.bz2`
（脚本仍会校验 SHA256）。

实际产物（2026-10-20，均 aarch64，sha256 全文见 `out/rpms-mobile/SHA256SUMS`）：

| RPM | 大小 | sha256（前 16 位） |
|---|---|---|
| `libfprint-tod-1.95.1+tod1-1.liuqin.fc44` | 418673 B | `9c8fceb02bcf01b0…` |
| `libfprint-tod-devel-1.95.1+tod1-1.liuqin.fc44` | 37719 B | `85579f4e8bc32699…` |
| `liuqin-fpc1264-tod-1.0-1.liuqin.fc44` | 42385 B | `70dc2cacdfa88460…` |

构建日志：`out/fingerprint-tod/logs/build-tod3.log`。首次构建在 Fedora 默认 LTO 下失败
（TOD 符号版本脚本与 `-flto` 冲突，Ubuntu 亦关闭 LTO），spec 内 `%define _lto_cflags %{nil}` 修复；
另注意 `-Ddrivers=` 空值会触发 meson `Key  is not in the dictionary`，必须 `-Ddrivers=all`。

## 4. 离线验证与边界

验证脚本：`packaging/mobile/fingerprint/verify-libfprint-tod.sh`（主机编排，arm64 容器内执行；
另一 throwaway 容器把 `/dev/null` 绑定为假 `/dev/fpc1020`）。
**最终结果：`VERIFY: PASS`**（`out/fingerprint-tod/logs/verify-tod5.log`；
明细 `out/fingerprint-tod/verify/{rpm-verify,probe-verify}.log`）。

关键实测输出：

- `fprintd-oem` 的 **47** 个 `fp_*` 未定义符号 + `LIBFPRINT_2.0.0` 版本全部由重建的 TOD 库提供
  → 现有 `fprintd-oem` 二进制无需重建；
- 适配器所需全部 **17** 个版本化 `fpi_*` TOD 符号由 `libfprint-2-tod.so.1` 提供；
- 真实 `rpm -Uvh` 事务安装 6 个指纹 RPM 成功；系统 `/usr/lib64/libfprint-2.so.2` 仍归
  Fedora `libfprint`；私有库不在 ld.so cache；`systemd-analyze verify` 解析 unit+drop-in 通过；
- 假 `/dev/fpc1020` 下 `FpContext` 枚举：`PROBE_DEVICE_COUNT=1`、
  `DRIVER=fpc1264_oem NAME=FPC1264 OEM on liuqin`；allowlist 负控制 → 0；
  对照（不设私有 `LD_LIBRARY_PATH`）Fedora libfprint 1.94.100 → 0 设备、不加载 TOD；
- 卸载测试：`rpm -e` 两个运行包后私有文件全部移除，Fedora libfprint/fprintd 不受影响。

检查项：

1. RPM 均为 aarch64；所有 ELF 为 ARM aarch64；
2. 私有库 soname = `libfprint-2.so.2` / `libfprint-2-tod.so.1`，且**不**出现在
   `/usr/lib64/` 标准路径；无 `libfprint-2.so.2` 的 RPM provide；
3. 私有 pkg-config 能编译上游 `build-tod.sh` 的两条命令（适配器包构建即证明）；
4. 适配器 `.so` 导出 `fpi_tod_shared_driver_get_type`，设备 id `fpc1264_oem`；
5. 移植 `fprintd-oem` 的未定义符号全部能在私有 TOD libfprint 中找到（版本匹配）；
6. 用 `FpContext` + `FP_TOD_DRIVERS_DIR`/`FP_DRIVERS_ALLOWLIST`（假 `/dev/fpc1020`
   字符设备节点）枚举到 `fpc1264_oem` 设备 —— 证明 TOD 加载链在无硬件时可工作；
7. `systemd-analyze verify --root=…` 解析 unit + drop-in。

**边界（不得夸大为实机结论）**：
- 以上全部是 `verified-offline`。`/dev/fpc1020` 是**离线假节点**，不是真实设备；
- 指纹解锁需要：真实 FPC1264 模块（`fpc1264_spi_diag.ko`，需匹配内核）、
  TA 固件从用户自有 `modem_a` 提取、Gatekeeper/RPMB 认证、实机录入验收；
- SELinux：首版镜像 permissive（build pipeline），enforcing 下私有路径 + `LD_LIBRARY_PATH`
  的 domain 策略尚未验证（`pending-device`）；
- udev/polkit：`liuqin-fingerprint-support` 已有 polkit 动作/规则与 PAM；
  适配器不新增 udev 规则（虚拟设备由 `/dev/fpc1020` 存在性 + `FP_LIUQIN_FPC1264_OEM_ENABLE` 门控）；
- 系统 `fprintd`（Fedora）仍用 Fedora libfprint，不会看到 FPC1264；指纹登录走私有 daemon，
  与上游 liuqin 设计一致。

## 5. 许可证

- libfprint TOD 源码：LGPL-2.1-or-later（`libfprint-tod` 包 `%license COPYING`）；
- FPC1264 适配器两个 C 文件：文件头 SPDX `LGPL-2.1-or-later`（上游 README 的
  "OEM C/PAM BSD-2-Clause" 是笼统表述，README 自身声明 file-level license 优先；
  实际以文件头为准，包内同时附 LGPL-2.1 全文）；
- liuqin 仓库其余内容 MIT；TA 固件/私有凭据不入包（用户设备自备）。

## 6. 遗留与下一步

- 当前没有连接设备，指纹录入/解锁仍 `pending-device`，不阻挡第一版桌面；
- 实机阶段：`liuqin-fpc-stable-module.service` 加载匹配内核模块 → 用户 `modem_a`
  提取 TA 固件 → 私有 daemon 起 → `fprintd-enroll`/PAM 验收；
- 版本升级：TOD 源码升级需同时更新 `SOURCE_LOCK.json`（上游仓库）与本目录文档中的
  URL/SHA256；RPM 版本跟随 `1.95.1+tod1`。
