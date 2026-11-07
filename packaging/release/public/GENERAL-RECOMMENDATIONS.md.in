# 日常使用建议

第一次进入桌面，可以先在“设置”里选好语言、时区和显示缩放。liuqin 的屏幕比较细，缩放调到自己看着舒服，触屏操作也会轻松一些。接上键盘套后，再试试打字、触控板和合盖，熟悉这台平板在 Linux 下的使用方式。

## 中文输入

镜像使用 GNOME 自带的 IBus，已经包含中文拼音组件。在“设置 → 键盘”里添加中文输入源，之后用 Super+Space 切换；Super 就是键盘上的 Windows 键。

主要用触屏时，可以在辅助功能中打开屏幕键盘。项目还提供了一套定制键盘布局，适合想尝试更多快捷键的人；它目前还不完善，启用方法放在 [可选功能](OPTIONAL.md)。

## 字体

镜像自带 Noto 中文字体，日常阅读可以直接使用。经常写代码的话，也可以试试 Cascadia Code，在“优化”中把它选作等宽字体，终端会更整齐。

喜欢浅色桌面的用户可以看看 [桌面外观](OPTIONAL.md#桌面外观)。那里介绍了 Light Style 和外观同步的开启方法，也保留了恢复默认外观的步骤。

## 常用应用

整理文献可以考虑 [Zotero](https://flathub.org/apps/org.zotero.Zotero)，日常沟通可以按需安装 [微信](https://flathub.org/apps/com.tencent.WeChat)。这两个社区 Flatpak 包都提供 ARM64 版本。先在软件商店里搜索需要的应用；想使用更多 Flatpak 应用时，可以按 [Flathub 的说明](https://flathub.org/setup/Fedora) 添加软件源。

写代码、远程管理或者使用命令行 AI 工具，都可以在系统装好后慢慢补齐。首版把重点放在平板本身，常用软件留给每个人按自己的习惯选择。

## 软件商店卡住时

先确认网页能否正常打开。如果一直停在“正在刷新”，可以查看 Flatpak 的远程列表：

```sh
flatpak remotes --show-disabled
```

本项目在 Fedora 45 上遇到过 Fedora Flatpaks 的元数据刷新卡住，暂时关闭对应远程后恢复正常。若你的现象相同，可以先尝试：

```sh
sudo flatpak remote-modify --system --disable fedora
sudo flatpak remote-modify --system --disable fedora-testing
```

以后需要恢复时，把 `--disable` 换成 `--enable` 即可。Flathub 使用另一套远程配置，可以继续按原来的方式使用。

如果平时需要代理，还要留意软件商店是否能使用它。浏览器可能已经配置好代理，而负责下载系统软件的后台服务仍在直连；这种情况需要按自己所用的代理工具单独设置。

## 系统更新

普通应用可以通过软件商店或 dnf 更新。项目内核的更新方法会随版本说明提供；升级前先看对应说明，尤其是 boot 和内核模块的配套要求。当前尚未完整验收自动内核更新和恢复流程，首版先按手动维护的方式使用。
