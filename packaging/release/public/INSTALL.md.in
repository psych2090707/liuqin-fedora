# 安装 liuqin Fedora Remix

首版提供实验性的 Linux 单系统安装。安装会清除 Android 用户数据，最后使用 Fedora 启动。**这个新组合完成了离线检查，尚未独立完成从原厂 Android 开始的完整实机安装验收。** 适合能自行准备恢复材料、愿意参与测试的 liuqin 用户。

如果平板已经装过 Linux，或者改过分区，先停在本地检查这一步。首版安装路径面向安装器能够识别的原厂布局；重新安装现有系统需要另外核对，尤其要弄清个人文件存在哪里。

## 准备工作

需要一台 Linux 电脑、可靠的 USB 数据线，以及已解锁 Bootloader 的 Xiaomi Pad 6 Pro（liuqin）。准备好 Python 3.11 或更新版本、OpenSSL、zstd 和 Android platform-tools 中的 fastboot。给平板充足电，先把照片、应用数据和其他重要文件备份到平板之外。

还要准备适合自己设备的原厂恢复材料。安装器保存的分区/GPT 备份有特定用途，无法恢复已经被覆盖的 Android 用户文件。备份目录和本地准备出的安装包都留在自己电脑上。

首版只支持 `linux-only`。Android/Fedora 双系统留作后续计划，当前安装包会拒绝 `dual` 模式。

## 下载镜像

在本版本 Release 下载全部 `*-base.tar.part-*` 分卷和 `BASE.SHA256`。源码附件供开发者使用，安装时可以稍后再下载。

把所有分卷放在同一个新目录中，先按实际文件名设置 `BASE`，再合并和校验：

```sh
BASE="$(ls *.tar.part-* | sed 's/\.part-.*$//' | sort -u | head -n 1)"
[ -n "$BASE" ] && [ "$(ls *.tar.part-* | sed 's/\.part-.*$//' | sort -u | wc -l)" = 1 ] \
  || { echo "expected exactly one base archive"; exit 1; }
cat "$BASE".part-* > "$BASE"
sha256sum -c BASE.SHA256
mkdir image
tar -xf "$BASE" -C image
```

校验应全部显示 `OK`。若缺少分卷或文件损坏，重新下载相应文件后再继续。

## 准备固件

公开镜像省去了再分发许可未确认的厂商固件。你需要有权在自己的 liuqin 上使用这些固件，并准备与本版本一致的目录；工具会逐项核对 SHA256。

本版匹配设备上游固定版本 `f5a535f5c1c980f042b58cb77467ff8f02a5518e` 的 `device/firmware/usr/lib/firmware`。设备拥有者可以根据该项目的使用条件，从上游准备这份目录：

```sh
git clone --filter=blob:none --no-checkout https://github.com/yzddmr6/xiaomipad-6pro-mainline.git liuqin-firmware-input
git -C liuqin-firmware-input sparse-checkout init --cone
git -C liuqin-firmware-input sparse-checkout set device/firmware
git -C liuqin-firmware-input checkout --detach f5a535f5c1c980f042b58cb77467ff8f02a5518e
```

也可以自行从有权使用的材料准备同样的文件。这里的说明不替代固件所有者的许可条件；请阅读上游目录的 README 和 NOTICE。

## 生成本地安装包

在电脑上运行：

```sh
python3 image/prepare-image.py prepare \
  --base image \
  --firmware liuqin-firmware-input/device/firmware/usr/lib/firmware \
  --out prepared
```

工具先校验镜像和固件，然后请你为平板上的 **`user`** 设置密码。它会生成 `prepared/`，里面的 boot、安装环境和系统文件互相配套。准备过程只处理电脑上的文件，结束时还没有改动平板。

`prepared/` 已包含你本地提供的固件和密码散列，请留作自用。以后换版本时重新准备一份新目录，避免混用文件。

先做一次本地检查：

```sh
python3 image/install.py --bundle prepared --check --layout linux-only
```

## 连接平板

让平板进入 Fastboot，在电脑上用 `fastboot devices` 找到自己的设备。下面命令中的 `SERIAL` 都要换成这台平板的实际序列号；有多台 Android 设备时尤其要确认。

安装器临时引导 RAM 安装环境后，电脑会看到一条 USB 以太网连接。通常让它自动获取地址即可：安装环境会分配 `192.168.7.10` 到 `192.168.7.19`，平板地址是 `192.168.7.2`。若没有自动获取到地址，再把这条 USB 连接手动设为 `192.168.7.1/24`，保留电脑原来的上网连接。安装器会根据路由选择电脑地址，也可以显式传入 `--host-address`。

先运行只读演练：

```sh
python3 image/install.py --bundle prepared --layout linux-only \
  --serial SERIAL --backup backup-SERIAL --erase-userdata \
  --allow-unverified --dry-run
```

需要 Fastboot 权限时，在这一条命令前加 `sudo`。演练会读取设备型号、解锁状态和分区容量，打印拟执行的操作。看清它将清除哪些数据、备份放在哪里、写哪个启动槽。

`--allow-unverified` 表示你知道该组合尚未通过完整实机安装验收；它不会替你证明兼容性。演练遇到不支持的布局、型号不符或容量检查失败时，应先查原因。

## 开始安装

确认备份和恢复材料已经准备好，演练结果也符合预期后，使用同样的参数开始实写：

```sh
python3 image/install.py --bundle prepared --layout linux-only \
  --serial SERIAL --backup backup-SERIAL --erase-userdata \
  --allow-unverified --yes-write-device
```

备份目录必须是尚不存在的新目录。安装器会要求确认清除数据，并检查备份、设备信息和写入结果。请保持 USB 连接和供电，等待它报告完成。

## 第一次登录

使用用户名 **`user`** 和刚才设置的密码登录。root 密码登录和 SSH 默认关闭，sudo 使用你的用户密码。

先试显示、触屏、键盘和 Wi-Fi，再检查电源键、合盖和唤醒。触控笔电量扩展会在检测到笔后显示状态。首次设置语言、时区和常用软件，可以接着读 [日常使用建议](GENERAL-RECOMMENDATIONS.md)。

如果没有正常进入系统，保留安装输出和电脑上的备份。按具体故障核对恢复方法；只恢复 boot、只切 A/B 或只恢复 GPT，各自能恢复的内容不同。反馈时可以参考 [项目支持说明](SUPPORT.md)。
