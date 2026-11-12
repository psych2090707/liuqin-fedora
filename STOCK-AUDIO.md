# 原厂扬声器调音

本版修复了通用固件把平板误配为 Acer 笔记本低音扬声器的问题。修复需使用 liuqin 原厂四声道 Music 调音；这些厂商文件的再分发许可未确认，因此公开镜像不附带文件，使用者在自己的电脑上补齐。

从自己有权使用的 **liuqin HyperOS OS2.0.6.0.VMYCNXM** ROM 的 `vendor_a` 分区 `/firmware/` 取出以下五个原始文件，直接放进电脑的 `stock-audio/` 目录：

- `TL-cs35l41-dsp1-spk-prot.bin`
- `TR-cs35l41-dsp1-spk-prot.bin`
- `BL-cs35l41-dsp1-spk-prot.bin`
- `BR-cs35l41-dsp1-spk-prot.bin`
- `cs35l41-dsp1-spk-prot.wmfw`

准确 SHA256 在 `image.json` 的 `stock_audio_source.files` 中。安装入口检查全部文件，并按四个扬声器的名称放入镜像；不需要原厂 `*-cali.bin`，也不要复制其他设备的 persist 校准。

```sh
python3 liuqin-install.py firmware --base install/image --out firmware \
  --accept-firmware-terms --stock-audio stock-audio
```

Windows 使用相同参数，入口换成 `powershell -ExecutionPolicy Bypass -File install-liuqin.ps1`。缺少文件或摘要不同会停止，不会静默使用笔记本调音。

## 从 ROM 提取（Linux）

已有成熟工具可完成提取：Android `simg2img` 解 Android sparse，AOSP `lpunpack` 解析动态分区，Linux EROFS 驱动只读挂载。它们不需要连接或改写平板。先从 fastboot ROM 的 tgz 解出 `images/super.img`，在空间足够的独立目录执行：

```sh
simg2img images/super.img super.raw.img
mkdir vendor-out vendor-mount stock-audio
lpunpack -p vendor_a super.raw.img vendor-out
sudo mount -t erofs -o loop,ro vendor-out/vendor_a.img vendor-mount
cp vendor-mount/firmware/{TL,TR,BL,BR}-cs35l41-dsp1-spk-prot.bin stock-audio/
cp vendor-mount/firmware/cs35l41-dsp1-spk-prot.wmfw stock-audio/
sudo umount vendor-mount
```

Windows 安装入口可以使用已提取的文件；**目前不自动在 Windows 提取 super/EROFS**，需要先在 Linux 提取，或用自己已有的可靠提取工具获得同样的原始文件。原 ROM 及本地补齐后的 `firmware/`、`prepared/` 留作自用，不上传为项目附件。

工具依据：[AOSP simg2img](https://android.googlesource.com/platform/system/core/+/master/libsparse/simg2img.cpp)、[AOSP lpunpack](https://android.googlesource.com/platform/system/extras/+/master/partition_tools/lpunpack.cc)、[Linux EROFS](https://docs.kernel.org/filesystems/erofs.html)。
