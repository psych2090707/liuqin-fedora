# 日常维护

下面的命令在平板的终端中运行。`sudo` 会要求输入自己的登录密码；示例中的 `软件包名` 和 `服务名` 请换成实际名称。

## 软件源

Fedora 默认自动选择镜像站。下载慢时可以指定一个更合适的镜像。Fedora 45 使用 DNF5，系统提供的源文件位于 `/usr/share/dnf5/repos.d/`，自己的设置可以放在 `/etc/dnf/repos.override.d/`，以后也方便恢复。

以科大镜像为例，先创建目录：

```sh
sudo mkdir -p /etc/dnf/repos.override.d
sudoedit /etc/dnf/repos.override.d/90-local-mirror.repo
```

如果这个文件已经存在，先另存一份备份。将以下内容写入文件并保存：

```ini
[fedora]
baseurl=https://mirrors.ustc.edu.cn/fedora/releases/$releasever/Everything/$basearch/os/
metalink=

[updates]
baseurl=https://mirrors.ustc.edu.cn/fedora/updates/$releasever/Everything/$basearch/
metalink=
```

`$releasever` 和 `$basearch` 保持原样，DNF 会自动填入系统版本和架构。然后刷新缓存、查看当前启用的源：

```sh
sudo dnf makecache --refresh
dnf repo list --enabled
```

想恢复自动选择镜像，删除自己新建的这个覆写文件后再次刷新缓存即可；若修改的是原有文件，则恢复备份。换其他镜像站时，按该站的 Fedora 帮助页替换地址。参考 [科大镜像说明](https://mirrors.ustc.edu.cn/help/fedora.html)。

添加第三方源时，优先使用软件作者给出的 Fedora 安装说明，并确认支持 Fedora 45 和 aarch64。源会影响以后更新到的软件版本，只添加自己需要的源，保留签名检查。

## 常用软件命令

```sh
dnf search 软件包名             # 搜索
sudo dnf install 软件包名       # 安装
dnf info 软件包名              # 查看介绍和版本
sudo dnf remove 软件包名        # 卸载，确认前看清连带删除列表
sudo dnf upgrade --refresh      # 更新当前系统
sudo dnf clean packages         # 清理下载的软件包缓存
```

本项目的内核需要 boot 和模块配套，升级内核前请看对应版本的项目说明；当前自动内核更新和恢复流程尚未完整验收。Fedora 大版本升级也需要另外核对设备适配。

## Flatpak

桌面应用也可以通过 Flatpak 安装。在 [Flathub](https://flathub.org/setup/Fedora) 按说明添加软件源后，常用命令是：

```sh
flatpak remotes
flatpak search 关键词
flatpak install flathub 应用ID
flatpak update
flatpak uninstall 应用ID
```

如果软件商店一直卡在刷新，可先查看 `flatpak remotes --show-disabled`。本项目在 Fedora 45 上遇到过 Fedora Flatpaks 元数据刷新卡住；遇到相同情况时，可临时关闭对应远程：

```sh
sudo flatpak remote-modify --system --disable fedora
sudo flatpak remote-modify --system --disable fedora-testing
```

恢复时将 `--disable` 改为 `--enable`。这些命令只适用于列表中已有的对应远程。

## 查看服务

```sh
systemctl --failed                    # 查看失败的系统服务
systemctl status 服务名               # 查看某项服务的状态
sudo systemctl restart 服务名         # 重启指定服务
```

排查桌面用户服务时，在 `systemctl` 后加 `--user`，例如 `systemctl --user --failed`。

## 查看日志和空间

```sh
journalctl -b -p err                  # 本次启动的错误日志
journalctl -b -u 服务名               # 某项服务本次启动的日志
journalctl -k -b                      # 内核日志
df -h                                # 查看磁盘可用空间
journalctl --disk-usage               # 查看日志占用
uname -r                             # 查看内核版本
cat /etc/os-release                  # 查看系统版本
```

反馈问题时，附上现象、系统版本和相关日志即可。分享前看一遍内容，隐去自己的账号、网络地址和其他私人信息。
