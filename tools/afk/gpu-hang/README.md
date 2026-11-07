# GPU 锁死取证常驻服务（TN0081）

liuqin 上 GPU 锁死时机器**不会死机**：内核、SSH、用户态都还活着，只是画面无法合成、
屏幕和输入看起来全无反应。这种故障既不会 panic、也不会复位，常规崩溃收集器一无所获；
等人发现时 dmesg 早已被复读冲掉（TN0081 实测 63 分钟内 1852 次 hangcheck，60k 行内核日志）。

本目录的 `gpu-hang-watch.py` 是常驻、只读、低开销的取证器：盯着内核日志，一旦出现
GPU fault / hangcheck lockup / GMU 超时，立刻把**当时仍然存活的 GPU 状态**落盘，
包括只有活着才能读到的 debugfs 内容。

## 抓什么

| 文件 | 内容 | 为什么需要 |
|---|---|---|
| `gpu-state.yaml` | `/sys/kernel/debug/dri/0/gpu`：每个 ringbuffer 的原始命令流、GMU log/HFI、寄存器、shader block、debugbus | 唯一能事后还原 CP 执行到哪的现场 |
| `drm-clients.txt` | `/sys/kernel/debug/dri/0/clients` | 当时有哪些 DRM 客户端 |
| `fdinfo-drm.txt` | 持有 `/dev/dri/*` 的进程逐个 `fdinfo`（`drm-engine-*`、`drm-memory-*`） | 把 GPU 占用归因到具体进程 |
| `kernel-context.txt` | 触发前最近 400 行内核日志（内存环形缓冲） | 不会被 dmesg 轮转冲掉的前置线索 |
| `dmesg.txt` / `journal-kernel.txt` | 完整内核日志 | 交叉核对 |
| `journal-session.txt` / `journal-user.txt` | 近期会话与用户日志 | 出事前应用侧动作 |
| `dstate-stacks.txt` | 不可中断任务的内核栈 | 看谁卡在 GPU 等待上 |
| `ps.txt` / `meminfo.txt` / `sysfs.txt` | 进程、内存、GPU 频率、屏背光、温区 | 排除内存/温控/背光等旁因 |

`events.csv` 记录每次事件（含未触发完整抓取的先兆事件）；`LAST-HANG.txt` 指向最近一次完整抓取。
先兆事件（GMU HFI 超时、`gmu_set_oob` 超时、ringbuffer 无空间）也会抓一次，
它们常常**早于**锁死若干分钟——TN0081 里 `14:09:52` 的 HFI 超时比 `14:24:44` 的致命超时早了 15 分钟。

## 开销与保留

- 空闲时只阻塞读 `dmesg --follow`，无轮询、无定时器、无网络。
- 完整抓取 60 秒冷却；已经抓到 hang 后 10 分钟内的先兆事件不再重复抓，
  避免长时间锁死时把最早那份首次故障快照挤掉。
- 先兆类抓取另有 5 分钟冷却。
- 保留最多 40 份、总计 512 MiB；超出时**先删先兆快照、再删最旧的 hang 快照**，
  且 `LAST-HANG.txt` 指向的那一份永不被删；磁盘可用低于 512 MiB 时拒绝抓取而不删旧证据。
- 输出目录 `/var/log/liuqin-gpu-hang/`（0750，root）。

## 用法

```sh
systemctl status liuqin-gpu-hang-watch
python3 -B /usr/libexec/liuqin/gpu-hang-watch.py status     # 已抓到什么
python3 -B /usr/libexec/liuqin/gpu-hang-watch.py capture --reason "手动"
```

手动 `capture` 用于：正在卡死时立刻取样、或复现前留一份基线。
取证目录可直接 `tools/afk/afk.sh pull <path>` 取回电脑。

## 边界

- 只读系统，不修改任何状态、不重启、不写 sysfs；除日志目录外不产生写入。
- 不是修复手段：它只负责把现场留下来。GPU 一旦锁死仍只能重启恢复。
- 内核 panic 或整机复位时来不及落盘；那种情况仍走 pstore/journal 路径。
- debugfs 读数在极端卡死时可能超时，收集器有 25 秒上限，超时会被记录而不是拖住服务。

部署与实机验证见 TN0081。
