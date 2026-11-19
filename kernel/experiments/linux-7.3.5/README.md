# Linux 7.3.5 liuqin 候选

本目录使用 [kernel.org 的 7.3.5](https://www.kernel.org/) 和本机 7.3.1 日用内核的配置、补丁及 initramfs。
默认构建同时应用 [Ubuntu liuqin v0.8.0](https://github.com/yzddmr6/xiaomipad-6pro-mainline/releases/tag/v0.8.0) 的适用内核增量。
两套候选独立版本名，模块各自配套。当前启动状态、升级收益与实测边界见升级结果。

## 构建

取得 `source.json` 指定的官方归档，放到 `out/kernel-stable-upgrade/downloads/` 或用 `LIUQIN_731_ARCHIVE` 指定。
可按 [kernel.org 的方法](https://www.kernel.org/signature.html)核验解压后 tar 流的签名。脚本在重放前核对归档 SHA256。
工作目录用无空格的绝对路径，首次构建须为空。使用 `--prepare-only` 只重放源码及生成配置。

```sh
JOBS=16 LIUQIN_731_WORK=/tmp/liuqin-735-ubuntu-v080 \
  bash kernel/experiments/linux-7.3.5/build.sh

# 便于单独验证稳定版和既有补丁，需要使用独立工作目录
LIUQIN_731_ADDON= JOBS=16 LIUQIN_731_WORK=/tmp/liuqin-735-local-baseline \
  LIUQIN_731_OUT="$PWD/out/kernel-stable-upgrade/baseline" \
  bash kernel/experiments/linux-7.3.5/build.sh
```

`patches/series` 保存本机队列顺序，重复补丁直接引用原文件。只有与稳定版相交的 APM 和充电口温度需要重写补丁。
Iris 电源关闭顺序已随 7.3.4 进入内核。11-17 的 SLPI 节点和面板方向由本目录记录在内核输入和启动参数中。
启动参数继续阻止内核自动启动 SLPI，沿用平板上已经部署的旧固件与逐文件摘要守卫。
`ubuntu-v080/patches/series` 是第二阶段。撤回这一阶段时使用上面的稳定版单独构建及其模块。

## 组装启动件

下例组装临时启动件，需要锁定的 [7.3.1 基础 ramdisk](../linux-7.3.1/README.md) 和本机原厂 ROM 分析输入。
只在确需制作持久候选时，将 `LIUQIN_731_SLOT_SUCCESS_MARKING=1` 加到第一条命令，并为两条命令指定不同的输出目录。
同一个输出目录只保留一种用途的镜像，避免把临时镜像当成持久启动件。

```sh
out="$PWD/out/kernel-stable-upgrade"
LIUQIN_RAM_RELEASE=7.3.5-liuqin-upstream2 LIUQIN_731_DIST="$out/kernel/dist" \
  LIUQIN_731_RAM_OUT="$out/initramfs-ram" \
  python3 kernel/experiments/linux-7.3.1/prepare-ram.py
scripts/build-bootimg.sh --strict-kernel --kernel-out "$out/kernel" \
  --ramdisk "$out/initramfs-ram/liuqin-7.3.5-ram.cpio.gz" \
  --cmdline-file kernel/experiments/linux-7.3.5/bootargs.txt \
  --dtb-source stock-rom --stock-rom-dir out/stock-rom --out "$out/boot-ram"
```

输出的 `build-info.json`、`SHA256SUMS` 与 `dist/modules.sha256` 记录内核、配置和配套模块。
上机时通过 `/sys/kernel/notes` 验证 GNU Build ID。平板写入与恢复按启动与恢复的授权范围执行。
