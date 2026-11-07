# 可选功能

默认使用 GNOME 原生输入与外观。以下源文件和扩展随镜像提供，但默认不启用；启用前先保存工作，GNOME Shell 更新扩展代码后通常需要注销/登录。

## 定制屏幕键盘（实验性）

定制了布局、尺寸与快捷键，仍依赖 GNOME Shell 51 的私有接口，**尚未完善**，不把它作为可靠输入的唯一途径。保留实体键盘和原生输入方式。

```sh
gnome-extensions enable liuqin-tablet-keyboard@liuqin
# 撤销
gnome-extensions disable liuqin-tablet-keyboard@liuqin
```

源码在 `overlays/gnome-local/keyboard/`。GNOME 原生输入源默认用 Super+Space 切换；特殊 Ctrl+Space 配置未默认启用，避免抢占其他应用的快捷键。旧配置样例保存在 `/usr/share/liuqin/optional/20-liuqin-gnome-input`，不是已经启用的配置。

## 桌面外观

Light Style 可以让 GNOME Shell 跟随浅色外观，外观同步服务会把选择带到 GTK 应用和终端。启用前先装好 GTK3 主题：

```sh
sudo dnf install adw-gtk3-theme
```

然后开启扩展和同步：

```sh
gnome-extensions enable light-style@gnome-shell-extensions.gcampax.github.com
systemctl --user enable --now liuqin-appearance-sync.service
```

撤销：

```sh
systemctl --user disable --now liuqin-appearance-sync.service
gnome-extensions disable light-style@gnome-shell-extensions.gcampax.github.com
gsettings set org.gnome.desktop.interface color-scheme 'default'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita'
```

终端里的配色也可以在终端首选项中重新选择。Flatpak 应用使用自己的主题运行时，外观可能需要在应用端再调整。

## 触控笔电量界面

这是默认设备功能：扩展 `liuqin-stylus-battery@liuqin` 只读内核电量/充电状态，没有修改充电行为。笔不在位时隐藏；满电、充电和位置不合适的状态见 [硬件说明](HARDWARE.md)。

若不需要显示：

```sh
gnome-extensions disable liuqin-stylus-battery@liuqin
```

不建议自行开启 SLPI/旋转或未验收的指纹认证。它们不属于通过打开一个扩展开关就能解决的问题。
