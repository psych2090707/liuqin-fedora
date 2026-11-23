# tools/suspend-log — 待机/唤醒取证

本页记录源码、设备端接口和维护要点。安装/关闭步骤由使用者按目标系统自行确认。

**v3（2026-11-13）改用持久事件序号轮转，日期回退不再决定删除顺序。** 旧的无序号记录
默认保留且顺序标作未知；不能凭文件名重猜先后。现机部署、备份与验证见
时钟与日志保护结果。

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
sudo liuqin-suspend-log pin <id> --reason '重要故障，等待导出复核'
sudo liuqin-suspend-log protect-existing --reason '保留当前证据'
```

状态目录默认 `/var/lib/liuqin-suspend-log`（0700）。测试或自测可用：

```sh
LIUQIN_SUSPEND_LOG_STATE=/tmp/liuqin-suspend-log-selftest \
  tools/suspend-log/liuqin-suspend-log pre suspend
```

## 保留规则（v3）

- `event-sequence.json` 与每个事件的 `sequence.json` 决定顺序；先持久化计数器再分配事件，
  中断可以留下缺号，不能回退复用。写入、保护和清理命令共用非阻塞文件锁。
- 普通完整事件保留最近 30 个；无序号、未完成、坏报告、`orphan-pre.json` 或有
  `protected.json` 的记录不参加自动淘汰。序号重复、计数器丢失/损坏/倒退时暂停删除并报错。
- 没有 post 的上一次 pre、跨启动配对、明确的挂起失败、early-wake 采集错误自动保护；
  `pin` 可手动保护其他重要事件，连同目录内的 dmesg、原始快照与 early-wake 一起保留。
  不宣称程序能自动识别所有重要故障；系统 journal 和应用独立日志不由这个 marker 控制。
- `--keep 0` 为紧急停止自动淘汰。旧事件无可靠顺序时，`latest` 提示用 `list/show`，
  不把任意一个旧文件名当作最新；出现首个带序号的完整事件后恢复正常 latest。
- 状态目录达到 256 MiB、或所在文件系统可用小于 512 MiB 时，停止新一轮采集并报错，
  不删除受保护记录腾空间。已有 pending 的 post 仍尝试完成保存，故容量上限允许一轮收尾余量。
  重要记录需先导出并核对备份，再由维护者明确决定清理；没有自动解除保护或上传。

## 采集行为（沿用 v2）

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
- `platform` 账本（11-22 起）：pre/post 各存 `regulator_summary`、`clk_summary`、
  `interconnect_summary`、`pm_genpd_summary`、runtime PM 活跃设备列表，以及 DT 里
  `regulator-always-on` 的节点。报告只打印计数、无消费者的常开轨和 always-on 数量，
  原始文本留在事件 JSON 里，用来回答“睡着时还有哪些轨/时钟/投票是开着的”。
- 电池快照包含 `charge_counter` 和 `voltage_ocv`。报告显示
  `power delta: <pre> -> <post> (+N sysfs units, ±X units/h over T)`，保留原内核的数值。
  本机旧 7.3.1 的计数以 mAh 为单位，11-18 的 7.3.5 `cafe98f3…` 已换成 µAh。
  既有报告可能仍标 `raw fw units`，跨构建先按 Build ID 确认单位。跨 boot 时工具只显示原始差值，
  不算速率。供电、端点刷新和可比较范围见取证方法。
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
- **明确opt-in例外**：`/etc/liuqin/early-wake-auto=1` + 默认state + ordinary suspend + root 时，collector调用桥接写内核debugfs `arm`，不是电源策略。自测/自定义state永不触碰真实接口；旧sealed未保存时先补救，否则拒绝重新arm。post在主动采集前保存重复读一致的status/events，fsync后写capture manifest和已保存指针；失败不阻止睡眠。各event内的early-wake子目录随本事件保留/保护。
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
