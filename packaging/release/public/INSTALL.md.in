# 安装 liuqin Fedora Remix

适用于**已解锁 Bootloader 的小米平板 6 Pro（`liuqin`）**。首版只提供 Linux 单系统安装，会清除 Android 用户数据并改写分区表，安装后从 Fedora 启动。

> 这是一个实验性组合：完成了离线检查，但**尚未独立完成从原厂 Android 开始的完整实机安装验收**。Windows 上的 USB 网络、真实刷机、首次启动和恢复流程还没有实机证明。

## 开始前

1. Windows 11 或 Linux 电脑、可靠的 USB 数据线、充足电的平板。
2. 平板已解锁 Bootloader，能在 Fastboot 下被电脑识别。
3. 把照片、应用数据和其他重要文件备份到平板之外。分区/GPT 备份不能恢复被清空的个人文件。
4. 阅读并确认你有权在本机使用本版本锁定的厂商固件。

Windows 不需要 WSL 或 Linux 虚拟机。安装入口会在需要时把 Python、Android platform-tools 和 zstd 放到你的用户目录，不要求管理员权限，也不修改系统 PATH。Python 和 zstd 压缩包用固定 SHA256 校验，platform-tools 用 Google 仓库发布的校验值。

## 安装入口

同一套命令，Windows 用 `install-liuqin.ps1` 引导，Linux 直接运行 `liuqin-install.py`。在源码仓库里，这两个文件分别位于 `installer/windows/install-liuqin.ps1` 和 `installer/liuqin-install.py`；在 Release 解包目录里它们在根部。

```powershell
powershell -ExecutionPolicy Bypass -File install-liuqin.ps1 doctor
```

```sh
python3 liuqin-install.py doctor
```

完整流程（Windows 把 `python3 liuqin-install.py` 换成上面的 PowerShell 入口）：

```sh
python3 liuqin-install.py doctor --bundle prepared --serial SERIAL
python3 liuqin-install.py fetch --repo https://github.com/psych2090707/liuqin-fedora --out install
python3 liuqin-install.py firmware --base install/image --out firmware --accept-firmware-terms --stock-audio stock-audio
python3 liuqin-install.py prepare --base install/image --firmware firmware --out prepared
python3 liuqin-install.py install --bundle prepared --layout linux-only \
  --serial SERIAL --backup backup-SERIAL --erase-userdata --allow-unverified --dry-run
```

`fetch` 默认选择最新发布（包括预发布版）；`--tag vX.Y.Z` 指定版本，`--stable` 只选稳定版。`--out` 绑定一个版本，换版本时必须换新目录，安装器会拒绝混用。

这个解包目录应包含 `liuqin-install.py`、`install.py`、`prepare-image.py`、`liuqin_layout.py`、`liuqin-rom-images.json`、`install-liuqin.ps1` 和 `install-liuqin.cmd`。缺少任何一个时应重新下载 Release，不要从别处补文件。


本次 alpha.2 还需要从 liuqin 原厂 HyperOS OS2.0.6.0.VMYCNXM 的 vendor 分区提取五份扬声器调音文件，放进 `stock-audio/`。文件名与摘要见 [STOCK-AUDIO.md](STOCK-AUDIO.md)；缺少时安装入口停止，不会静默使用错误的笔记本调音。此要求不改变 alpha.1 的旧包。

`prepare` 会让你为平板用户 **`user`** 设置密码。`prepared/` 含本机固件和密码散列，只留作自用，不要上传。

确认备份和演练输出后，才执行实写：

```sh
python3 liuqin-install.py install --bundle prepared --layout linux-only \
  --serial SERIAL --backup backup-SERIAL --erase-userdata --allow-unverified --yes-write-device
```

`--allow-unverified` 表示你了解该组合尚未完成完整实机验收，不是跳过检查。没有 `--yes-write-device` 时安装器只演练。

## 安装后

用 **`user`** 和准备阶段设置的密码登录。root 密码登录和 SSH 默认关闭，sudo 使用你的用户密码。

先验证显示、触屏、键盘套和 Wi-Fi，再检查电源键、合盖与唤醒。首次启动和恢复仍需实机确认。

## 出问题时

- 保留安装输出、`backup-SERIAL/` 和 `liuqin-install-report.json`。
- 分区表无法识别或校验失败时停止，不要手动改分区、猜设备路径或换镜像硬试。
- 恢复 GPT 只恢复分区表，刷回 boot 只恢复启动镜像；都不能恢复已覆盖的个人数据。
- 启动镜像回退不等于完整系统回滚；软件包、系统配置和个人文件需要各自的备份。

更完整的项目说明见仓库 <https://github.com/psych2090707/liuqin-fedora>；Agent 执行边界见仓库根 `AGENTS.md`。
