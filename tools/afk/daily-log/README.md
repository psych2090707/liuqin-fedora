# 日常低干扰日志

TN0074 实现 TN0072 L0。复用已有持久 journal/PON 归档；不复制 journal/dmesg，不触发睡眠、
联网探测或指纹认证，不读取按键/应用内容/debugfs，不写 RTC 或持有 inhibitor。

`sample.py` 是单次采样器，随 `liuqin-device-support` 源码配方交付。
系统服务用 Python 显式执行，timer 需单独获准启用；不会随 RPM 安装自动启用。
本轮实机使用同源三个文件直接安装、逐文件 SHA256 读回；未重建或重装整个支持包。

- 启动两分钟后开始，完成后每五分钟一次，合并精度一分钟，`WakeSystem=false`。
- 单次超时十秒，不自动重启；D-Bus/命令单次超时 0.4 秒。
- `/var/lib/liuqin-daily-log/` 700、文件 600；每段 8 MiB、总计 64 MiB。
- 按全局段序号及 boot ID 排序，每 boot 内序号连续；墙钟回退不影响保留次序。
- 磁盘可用小于 512 MiB 时停止追加且不删除旧证据；正常轮转只删除本工具最旧段。
- 断写末行保留，下次插入换行后继续；摘要跳过并报告坏行。最后一条未落盘的序号可能重用，
  本工具不承诺断电前最后一条已持久化；不每五分钟额外调用 fsync。
- 电源字段按内核 ABI 原单位保留：charge 为 µAh、energy 为 µWh、current 为 µA、voltage 为 µV，
  电池 temp 为 0.1°C；thermal 为 m°C，内存沿用 `/proc/meminfo` 的 kB。缺字段不补零。
- DRM DPMS 是驱动报告，不等于已证明屏幕物理熄灭。fprintd 状态只查 systemd，不激活服务。
- 现有 journal 的 1 秒同步原样保留，仍有 UFS 写入开销。

手动只读查看一次（不写日志）：

```sh
python3 -B tools/afk/daily-log/sample.py --stdout
```

导出样本后，在电脑做离线摘要；可选传入已有 journal JSON。`--output` 独占创建 600 文件，
最大 16 MiB，不覆盖已有摘要。设备常驻仅写 64 MiB 样本；如将摘要放回设备，另限一份 16 MiB，合计 80 MiB。

```sh
python3 -B tools/afk/daily-log/summarize.py out/tn0074-daily-log-input/samples --output /tmp/liuqin-daily-summary.json
python3 -B tools/afk/tests/test-daily-log.py
```

摘要按 boot/单调时钟统计完整 PM entry/exit、缺序/坏行/墙钟回退和
`ΔBOOTTIME−ΔMONOTONIC`。端点不能证明整个区间的亮屏或充电状态，故区间暂列混合/未知；
不能从缺采样推断睡眠或崩溃，不能证明 AOSD/CXSD，也不外推精确电流/续航。
事件只保留固定类别、boot ID、单调时间，不复制用户应用的消息正文。

安装、备份、回退和本轮实机依据见 TN0074。
定时器语义依据 [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)。
