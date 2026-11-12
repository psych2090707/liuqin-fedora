# 0.6.1 上游修复：7.3.1 离线候选

本目录在原 18 组适配之后追加 15 组独立补丁。来源、采用/重复判断及实测边界见
任务结果。不是旧 6.17 补丁的直接重放。
现有默认构建和日用 A/B 不变；只有明确调用本目录才启用这个 profile。

```sh
# 根目录执行；WORK 必须是新的、无空格的绝对路径。
LIUQIN_731_WORK=/tmp/liuqin-upstream-rebuild \
LIUQIN_731_OUT="$PWD/out/upstream-refresh/rebuild" \
JOBS=8 bash kernel/experiments/linux-7.3.1/refresh/build.sh
```

来源归集在 `patch-manifest.json`，有序队列在 `patches/series`；每个文件保留来源和适配说明。
准确 release 为 `7.3.1-liuqin-upstream1`，与旧版模块目录隔离。
配置保留原基线；`bootargs.txt` 仅增加 `mem_sleep_default=s2idle`，不顺手移除显示/启动保护参数。
SLPI 仍 disabled，原厂每机固件、笔电量、旧 TDM sink、early-wake 记录器继续保留。

## 逐项撤回

从 `patches/series` 移除相应行，在新的 WORK/OUT 重新构建，留下撤回后的队列及 Build ID。
不要修改已构建目录里的补丁，也不要把不同候选的模块混装。

- `0001` 恢复 IPCC，`0002` 电源通知不作唤醒源，`0014` GENI 中断过渡，以及 s2idle 启动参数
  是首组兼容性组合。若撤回其中之一，需重新评估整组；不能只恢复 IPCC 屏蔽再沿用充电结论。
- `0003` GPU HFI/转储等待与 `0004` GPU 终止失败恢复分别可撤；`0004` 按 7.3 DMA fence 锁、
  VM 与 perf-counter API 适配，只有确认 GPU 不再访问缓冲才结束 pending fence。
- 音频生命周期/录音、蓝牙 IBS、USB PCS、UCSI 注册/connector、DSI、Iris、GLINK endpoint、
  NVT 原始诊断接口各自有独立补丁；撤除列表不能改变 SLPI 禁用和每机校准。

完整回退优先使用保留的旧启动件；任何分区写入、切槽仍须当次授权及核验。
RAM 启动后重启回旧持久镜像不会撤回另行安装的用户态包，用户态需独立备份/恢复。

## 离线候选组装

用 `../prepare-ram.py` 指向新 dist 和独立输出，可以生成配套模块的 tmpfs ramdisk。
它按构建身份生成 activation 脚本，核对原 ramdisk 哈希，保留固件/root 契约。默认（RAM 测试）跳过
slot-success 写入并放 `/etc/liuqin-kernel-ram-test`；**持久用镜像必须设 `LIUQIN_731_SLOT_SUCCESS_MARKING=1`
生成 ramdisk**，否则每次启动都会扣一次 A/B 重试次数（2026-11-11 教训）。
再用 `scripts/build-bootimg.sh` 的 stock-rom 路径、匹配内核输出及本目录 `bootargs.txt` 组装。
具体已生成产物及哈希只在任务结果中记录。本目录不包含 fastboot/刷写动作。
