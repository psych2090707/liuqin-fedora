# libadwaita 列表控件马赛克补丁

2026-11-05 在 **F44 / libadwaita 1.9.4** 部署并验证过的范围规避，针对背景色马赛克，不是 Mesa/Freedreno 根因修复。**2026-11-06 当前已为 F45，镜像使用官方 libadwaita 1.10.0-2，用户确认色块重新出现；不能写成本补丁仍安装或已失效。** 先核对 F45 原生修复候选与实际包内容，当前停点见渲染结果。

## Fedora 45：未预打旧补丁，现已确认仍有色块

Fedora 45 / GNOME 51 镜像使用**官方** libadwaita 1.10.0 + GTK 4.24.1，刻意不预打本补丁：
GTK 4.24 的列表项/渲染器/图集/缓存重构没有自动使本机现象消失。用户希望后续重新评估原生修复；
先核对具体提交、Fedora 是否回补及触发条件，再决定有界对照。本补丁保留为局部回退候选，
没有在本轮重编或部署。下面的构建/回退命令是 F44 历史示例，F45 使用时必须重新核对源包和上下文，不能仅替换版本字符串就假定有效。

## 现象和范围

- 用户确认：不是“缺口”，是与背景同色的小方块/马赛克；开关、选中行、列表行滚动时都可能出现。
- 有证据：设置、应用商店、GNOME Tweaks、文本编辑器的**首选项**。
- 未复现：Nautilus 文件列表、文本编辑器正文滚动、普通纯文本路径。
- 共同点：**libadwaita 的偏好设置/列表/开关/选中行**；不是所有 GL 应用。
- 因此按应用列表打补丁会漏；本补丁放在 libadwaita 库本身，所有链接 libadwaita 的宿主应用（包括以后新装的）自动生效。Flatpak 应用使用自己的运行时，不覆盖；需要时另设 Flatpak override。

## 补丁做什么

`adw-fd-flush.patch` 在 `src/adw-main.c` 增加库加载构造器：

```c
__attribute__((constructor))
static void
liuqin_fd_flush_init (void)
{
  g_setenv ("FD_MESA_DEBUG", "flush", FALSE);
}
```

`FD_MESA_DEBUG=flush` 是 Mesa/Freedreno 的调试开关，强制每次绘制后刷新。它掩盖了当前驱动的 GPU 写入可见性/同步问题；构造器只影响链接 libadwaita 的进程，Mutter 和非 libadwaita 应用不被设置。

## 来源、构建和安装

- 源包：Fedora 44 `libadwaita-1.9.4-1.fc44.src.rpm`（`dnf download --source libadwaita`）。
- 在 spec 的 `%autosetup` 后应用：

  ```sh
  patch -p1 < %{_sourcedir}/adw-fd-flush.patch
  ```

- 构建：

  ```sh
  rpmbuild -bb --define "_topdir /var/tmp/adwbuild" --nocheck \
    /var/tmp/adwbuild/SPECS/libadwaita.spec
  ```

- 安装（同 NEVRA，替换现有包）：

  ```sh
  sudo rpm -Uvh --replacepkgs \
    /var/tmp/adwbuild/RPMS/aarch64/libadwaita-1.9.4-1.fc44.aarch64.rpm
  ```

- 备份（平板 `/var/tmp/liuqin-libadwaita-backup/`）：
  - 官方 `libadwaita-1.9.4-1.fc44.official.aarch64.rpm`，SHA256 `911fa671e1d0809a9c2dbcbee86e8b6acd14385b1ce4eac9e35a11177e3d3bab`。
  - 本补丁包 `libadwaita-1.9.4-1.fc44.patched.aarch64.rpm`，SHA256 `d7a66f90b98c18a6c34b5086a850905936f35af7f7640639b28c4f8e895e89e8`。

- 回退：

  ```sh
  sudo rpm -Uvh --replacepkgs \
    /var/tmp/liuqin-libadwaita-backup/libadwaita-1.9.4-1.fc44.official.aarch64.rpm
  ```

  然后重新打开设置/商店；库已映射的旧进程需重启，必要时注销或重启平板。回退后马赛克会回来，这是预期。

## 验证边界

- 2026-11-05 在默认 Mutter 配置、无应用包装器、无全局环境变量的情况下重启并登录后：
  - 设置 → 搜索滚动无背景色方块；
  - 应用商店滚动 30 秒无方块，用户确认流畅度可以；
  - `GNOME Tweaks` 和文本编辑器首选项属于同一 libadwaita 路径，未逐页长测，不能写成全部页面已验收。
- 应用级 `FD_MESA_DEBUG=flush` 对照中，设置页 presentation 中位约 `8.4 ms`（约 120 Hz），与未加 `flush` 时相同；补丁版使用同一开关，未单独重复帧时间采样。商店只做用户流畅度确认，没有单独 FPS 采样。
- 没有在 Nautilus、纯文本文档、非 libadwaita 应用上全局加 `flush`；这些路径本来未复现，不能据本补丁宣称整个 GPU 栈已修好。
- 平板上的 Mesa 仍为 `26.2.6-1.fc44`，GTK 为 `4.22.5-2.fc44`；本补丁没有改变它们。

## 维护注意

- **升级 libadwaita 会覆盖本补丁**；升级后需重新打补丁或等上游修复。不要只检查包版本，必须确认 `/usr/lib64/libadwaita-1.so.0` 含该构造器，并重跑设置/商店滚动。
- `FD_MESA_DEBUG=flush` 是调试开关，不是长期稳定接口。关注重负载应用帧数、电耗和发热；如出现明显退化，优先寻找更窄的 Mesa 修复，而不是扩大 `flush` 范围。
- 根因仍未确认：本轮测试中 Mesa 26.2.6、Mutter 不发送 UBWC modifier、libadwaita 1.9.3、GTK 圆角描边回移、syncobj fd 探针都没有修好；只有 `FD_MESA_DEBUG=flush` 有效。后续上游若给出同步/缓存修复，应删除本补丁并用官方包验证。
- 补丁只作用于**宿主** libadwaita；Flatpak 应用自带运行时，不会读取本补丁。若以后在 Flatpak 中看到同一现象，应另设 Flatpak 环境覆盖并单独验证，不能把宿主补丁当成已覆盖。
- 构建依赖和源包不提交；本目录只保留补丁和可复现步骤。完整排查见任务结果。
