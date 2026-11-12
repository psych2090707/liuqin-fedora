# tools/suspend-log — 待机/唤醒取证

本页记录源码、设备端接口和维护要点。安装/关闭步骤由使用者按目标系统自行确认。

**v2（2026-10-29）已修正 v1 观测缺陷，19 项离线测试通过，并已在维护设备上完成
部署与读回验证（四个文件哈希一致、记录服务显式重启、单条通知即时落盘、事件快照到位）。**
v1 的问题：Notify 最后一条要等下一条才落盘、只覆盖 FDO；IRQ 只看 post wake 名单；
duration 是总窗口；电池/DDR 查询先于 IRQ 快照；缺数据时会兜底成 `real_sleep=yes`。
v2 的行为见下方“v2 行为”。

## 文件

| 文件 | 说明 |
|---|---|
| `liuqin-suspend-log` | Python 3 采集器/报告器；安装到 `/usr/local/sbin/liuqin-suspend-log` |
| `liuqin-early-wake-log` | 显式启用时的同步桥接：封存归档/校验后才重新arm；无daemon/timer |
| `50-liuqin-suspend-log` | systemd-sleep 钩子；安装到 `/usr/lib/systemd/system-sleep/`（systemd 259 不读 `/etc`） |
| `liuqin-notify-log` | 用户会话记录器；安装到 `/usr/local/bin/`，写通知与屏幕/供电事件 |
| `liuqin-notify-log.service` | 用户服务；安装到 `~/.config/systemd/user/` |
| `deploy.sh` | 经现有 `tools/afk/afk.sh` 推送、安装、显式重启、读回哈希、`/tmp` 自测 |
| `../../tests/suspend-log/test_observers.py` | 离线 unittest，不需要平板 |

## 设备端接口

```sh
sudo liuqin-suspend-log pre suspend    # systemd-sleep 调用
sudo liuqin-suspend-log post suspend   # systemd-sleep 调用；生成报告
sudo liuqin-suspend-log latest         # 最新 report.txt
sudo liuqin-suspend-log screen-latest  # panel on/off 与挂起区间、通知关联
sudo liuqin-suspend-log list           # 事件 id + 总窗口/驻留估计/运行窗口
sudo liuqin-suspend-log show <id>      # 指定事件
sudo liuqin-suspend-log prune          # 只保留 --keep（默认 30）
```

状态目录默认 `/var/lib/liuqin-suspend-log`（0700）。测试或自测可用：

```sh
LIUQIN_SUSPEND_LOG_STATE=/tmp/liuqin-suspend-log-selftest \
  tools/suspend-log/liuqin-suspend-log pre suspend
```

## v2 行为

### liuqin-notify-log（用户服务）

- 用 `busctl --user monitor --json=short` 观察**方法调用**（FDO `Notify` 和 GTK
  `AddNotification`）。每条消息是一行独立 JSON，收到完整调用就立即写，不再等下一
  条消息、也不需要补发测试通知。
- `notifications.jsonl` 每行含 `protocol/app/summary/boot_id/realtime_ns/boottime_ns/
  monotonic_ns`（以及总线时间戳 `bus_realtime_ns`），时钟在**接收时**采样；不保存正文。
- `screen-events.jsonl` 订阅 UPower（系统总线）`OnBattery/LidIsClosed`、UPower 设备的
  `Online/State/Percentage/IsPresent`、Mutter `PowerSaveMode`、ScreenSaver
  `ActiveChanged/WakeUpScreen`，并在启动时写一次 `kind=snapshot` 初值。只保存上列属性，
  不 dump 整包、不轮询。
- 覆盖边界：GNOME Shell 内部创建的 MessageTray 源没有 FDO/GTK 调用，看不到；缺记录
  不等于没有事件。

### liuqin-suspend-log（采集器）

- `collect()` 先保存 IRQ/`wakeup_sources`/pm 状态与三套时钟，再读电池属性和
  `qcom_stats`；这些主动读取记录在 `query_windows` 里。`ddr_stats` 默认不读，
  需要时设 `LIUQIN_SUSPEND_LOG_DDR_STATS=1`。
- 电池快照包含 `charge_counter` 和 `voltage_ocv`。报告新增
  `power delta: <pre> -> <post> (+N raw fw units, ±X units/h over T)`：
  `qcom_battmgr` 直接暴露固件 `BATT_CHG_COUNTER`，驱动不做单位换算；本机实测约
  1 单位 ≈ 1 mAh（50% ≈ 3465，整数百分比每 1% ≈ 69 单位）。跨 boot 时只给原始差值，
  不推算速率。百分比是整数且醒后重算，睡眠耗电优先看这个差值。
- `duration_s` 仍是 pre/post 采集总窗口；另存 `suspend_estimate_s`
  （ΔBOOTTIME − ΔMONOTONIC）和 `awake_window_s`，时钟缺失/跨 boot 时全部为 `null`。
- `real_sleep` 只按 `suspend success` 是否增加判定，缺统计或跨 boot 记 `unknown`，
  不再用“窗口 ≥5 s”兜底。
- IRQ 差值保留全部变化项，wake 标记分 `wake_enabled_pre` / `wake_enabled_post`；
  醒后名单撤销不会把该 IRQ 从报告里删掉。
- 结论不再自动归因 PON/AOSS；无首因时明确写“现有观测未指认”。
- `screen-latest` 按同 boot 的挂起区间分类：`resume`（含 >5 s 的慢恢复，会单独标注）、
  `screen-only`（区间内没有 suspend exit）、`unknown`（缺前一个熄屏或 journal 覆盖不足）。
  通知只在**先于**亮屏时标为候选，亮屏之后到达的通知标“not a cause”。

## 数据与安全

- 不直接写电源配置/启动分区，只写状态目录；电池 sysfs 读取仍可能向固件发请求，
  所以放在被动快照之后并记录时间窗，不能称为零扰动采样。
- **明确opt-in例外**：`/etc/liuqin/early-wake-auto=1` + 默认state + ordinary suspend + root 时，collector调用桥接写内核debugfs `arm`，不是电源策略。自测/自定义state永不触碰真实接口；旧sealed未保存时先补救，否则拒绝重新arm。post在主动采集前保存重复读一致的status/events，fsync后写capture manifest和已保存指针；失败不阻止睡眠。各event内的early-wake子目录随最近30轮清理。
- `cmdline` 中的 `androidboot.serialno`、`androidboot.cpuid`、`hwid.*`、
  `androidboot.oled_wp`、`msm_drm.oled_wp` 在落盘前替换为 `<redacted>`。
- 状态目录 root-only；通知/屏幕事件日志为用户 0600；都不自动上传、不提交仓库。
- 采集器异常时退出码仍为 0，避免 systemd-sleep 因取证失败而卡住；钩子另有 8 秒
  `timeout`。
- `pre` 写 `pending.json` 并 `fsync`；`post` 读取后生成 `events/<id>/`，然后删除
  `pending.json`。若没等到 `post`（异常复位），下轮 `pre` 会把旧 pending 作为
  `orphan-pre.json` 留在事件目录，不会静默丢弃。

## 报告文件

```text
/var/lib/liuqin-suspend-log/
├── pending.json                 # 仅睡前存在
└── events/<bootid8>-<boottime>/
    ├── pre.json                 # 睡前完整快照（缺 pre 时不生成）
    ├── post.json                # 醒后完整快照
    ├── report.json              # 差值 + 自动判读
    ├── report.txt               # 人读版
    ├── dmesg-post.txt           # 醒后完整 dmesg 尾部
    └── early-wake/             # 显式启用时；同轮原始封存 + 身份/hash
        ├── status.txt
        ├── events.jsonl
        └── capture.json
```

## 开发自测

```sh
python3 -B -m unittest discover -s tests/suspend-log -p 'test_*.py' -v
rm -rf /tmp/tn-suspend-selftest
tools/suspend-log/liuqin-suspend-log --state-dir /tmp/tn-suspend-selftest pre suspend
tools/suspend-log/liuqin-suspend-log --state-dir /tmp/tn-suspend-selftest post suspend
tools/suspend-log/liuqin-suspend-log --state-dir /tmp/tn-suspend-selftest latest
```

自测不会睡眠，`real_sleep=unknown`（或 `no`）正常；只有 success 增加的真实睡眠才
显示 `yes`。

## 边界

工具的自动归档链有既有实测；普通 IRQ/source 差值仍是间接线索，PM IRQ 为空不排除全部路径，首个 IRQ 也不自动等于叫醒者。`screen-latest` 是区间关联，不覆盖 Shell 内部通知。升级内核不保证保留额外诊断输入；源码位于 `kernel/device-extras/`，不在默认修复队列中。

`early-wake-decode.py` 是离线解码器的维护副本，内容未变；只在匹配同一事件的记录、双时钟和驻留数据后解释，不自动认定物理唤醒来源。
