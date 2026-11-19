# 上游修复：7.3.1 分组候选

2026-11-15：用户授权分步移植 0.7.0。现有 19 组之后追加第一组稳定性小修：
`0020` 音频时钟注册前保存驱动数据、`0021` GPU submit 虚拟连续分配、
`0022` GPU 终止失败后的 close 可退出、`0023` 电池通知请求锁与 GLINK 消费者清理。
`0021` 保留 7.3 的防溢出计算；`0023` 同时保护本机笔和新主线方向更新 work。
每个独立补丁均可从 series 撤回；撤回后需重新构建匹配模块，不复用既有 boot。
第一组完整编译和 boot 离线核验通过；Build ID `64f51b67…` 已 RAM 启动，原 A 对照声音相近；用户暂缓音频并要求继续。
这是待验候选，现用 A 仍是第 19 组；阶段、验证与人工停点看任务结果。

`0024-liuqin-disable-unused-qce.patch` 作为可选补丁保留，不在默认 series：
用第 19 组同 Image/模块/ramdisk、仅 DT status 不同的两次 RAM 启动，确认关闭节点后
平台设备消失，但加密通道/EBI 的初始化带宽保留值没有下降；未证明节电作用。
详细身份与否定结果见任务结果。

`0025` 传递 Type-C source 状态；`0026` 将实际充电口温度转发到固件，仅在外接电源/OTG
期间采样，同时处理电源在线边沿。保留 ADC 延迟获取、IIO 正成功返回、笔/方向/生命周期；
没有假热测试接口或额外热档守护进程。`0027` 整合本机 `0016` 通知暂存：只提前排队查询
外接电源状态，完整硬件操作仍等恢复；编译通过不等于睡眠插拔已验收。
完整候选已离线构建并读回，用户暂停在实机测试前；准确身份和恢复任务的步骤看任务结果。

`0028` 规避 2026-11-15 首次 RAM 启动撞上的启动竞争：`PMIC_RTR_ADSP_APPS` 端点
（5.3 s）早于 `pmic_glink` 平台设备（13.0 s）出现，rpmsg 核心在探测失败时销毁端点且不重试，
导致整个启动期电池/Type-C 服务缺席（顶栏红色感叹号电池）。改法是按
[Linaro 的 workaround](https://gitlab.com/Linaro/arm64-laptops/linux/-/commit/46a6b15977c0af848516f5ccc771908d28ffc766)
把 rpmsg 驱动注册移到平台设备探测成功之后；上游在 2026-07 提出的 `-EPROBE_DEFER`
改法因 rpmsg 核心仍会销毁端点，单独使用无效。该竞争与 0025–0027 的充电改动无关，
原 A 也可能偶发命中。合入条件与撤除条件见补丁头，实测结果见任务结果。

`0029`–`0035` 是 2026-11-15 晚按用户要求合并成的第二批：触控首帧（`0029`）、
FastRPC 可冻结等待（`0030`）、DPU 恢复时补回核心时钟 OPP 投票（`0031`）、
GPU 依赖的 CX 档位（`0032`）、板级显示/串口/GPU 供电票（`0033`）、
CPU/LLCC 带宽监测（`0034`）、CPU 容量与动态功耗系数（`0035`）。
其中 `0031` 对应的上游“删除 suspend 里 `dev_pm_opp_set_rate(dev, 0)`”在本机 7.3.1
不存在，不需要再搬；`0032` 保留本机原有 12 个 GPU OPP，只补 CX 依赖，不改频率表。
这一批要求同一次 RAM 验证后再决定是否落盘，不能把“构建通过”当硬件结论。

2026-11-12：为 s2idle 睡死调查追加第 16 组 `0016-pmic-glink-sleep-defer.patch`
（上游 pmic_glink 通知暂存 RFC patch 1 的 7.3.1 适配），构成新候选；11-11 已交付的
持久 A 仍是 15 组，两者不要混装。
2026-11-13：追加第 17 组 `0017-camcc-park-rcgs.patch`（上游 704930b1a253，
2026-11-08 合入），修复摄像头会话结束后 RCG 停在已关闭 PLL 的问题；第 18 组
`0018-camss-csid680-clear-top-irq.patch` 在 CSID 复位前清 TOP 中断状态，修复
第二次会话/录像 `CSID reset timeout` 后管线卡死。两组已随相机修复写入 A。

本目录在原 18 组适配之后维护分组 refresh（前 19 组已用于当前 A；
2026-11-15 追加稳定性及充电候选，0024 仅可选）。准确队列看 series。来源、
采用/重复判断及实测边界见任务结果。
不是旧 6.17 补丁的直接重放。现有默认构建和日用 A/B 不变；只有明确调用本目录
才启用这个 profile。

`0019-liuqin-quad-slot-map.patch` 已部署（2026-11-13 晚，随后续内核包进入持久 A）：给 CS35L41 暴露
`ASPRX1/2 Slot Position` mixer 控制，让 UCM 在普通立体声（全部 0/1）和
四声道（TL 0/1、TR 1/0、BL 2/3、BR 3/2）之间切换。内核 slot 控制本身和
两种 profile（普通立体声 0/1、真 4.0）的自动客观验收都已通过；此前
“普通立体声 BL/BR 不响”和“上混被否决”已确认是失效静音控制加录音削顶
造成的测量假象。持久系统上两种 profile 均已复验通过。详见
四声道调研；不要写入持久
启动。候选 UCM/脚本在同一任务目录，尚未集成进设备包。

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
