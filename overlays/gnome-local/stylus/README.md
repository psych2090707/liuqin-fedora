# 触控笔电量 GNOME 扩展

在 GNOME 51 顶栏显示小米触控笔（Xiaomi Smart Pen）的电量和充电状态。

**2026-11-07 状态**：已在维护设备上系统级安装并启用；
顶栏显示 `🖊 100%`，UPower 也列出 `battery_qcom_battmgr_pen`。
低电量/充电中 ⚡ 和菜单进度条的实际外观尚未在低电量下确认。

数据来自内核 `qcom-battmgr-pen` 电源设备：

```text
/sys/class/power_supply/qcom-battmgr-pen/
  present   capacity   status
```

它依赖内核实验补丁 `0017` + `0018`。没有补丁时目录不存在，扩展会自动隐藏，不会报错。

## 显示逻辑

| 内核状态 | 顶栏/菜单 |
|---|---|
| `status=Charging` | 🖊 + ⚡ + 百分比；菜单“充电中” |
| `status=Full` 或 100% 且未充电 | 🖊 + 百分比；菜单“已充满” |
| `status=Not charging` | 🖊 + 百分比；菜单“未在充电（请调整位置）” |
| `present=0` 或目录不存在 | 隐藏 |

顶栏用主题的 `document-edit-symbolic` 作笔形图标，充电时在百分比前加一个 ⚡；
菜单里显示笔名、状态和一条按电量填充的进度条。

注意：

- 100% 时固件可能短暂补电，状态会在 `Charging` / `Full` 之间切换，属正常。
- “未在充电（请调整位置）”表示霍尔检测到附近有笔，但反向供电没有建立；
  偏吸、横移等可能出现这个状态。
- 磁铁反接/倒吸和拿开在固件侧都表现为“没有笔”，扩展不会显示；
  这时需要用户自己确认笔是否放反。

## 安装（系统级）

```sh
sudo install -d /usr/share/gnome-shell/extensions/liuqin-stylus-battery@liuqin
sudo install -m644 \
  overlays/gnome-local/stylus/extension/metadata.json \
  overlays/gnome-local/stylus/extension/extension.js \
  overlays/gnome-local/stylus/extension/stylesheet.css \
  /usr/share/gnome-shell/extensions/liuqin-stylus-battery@liuqin/
gnome-extensions enable liuqin-stylus-battery@liuqin
```

新安装的扩展如果顶栏没有立即出现，注销再登录一次即可；不需要重启系统。
**更新 `extension.js` 后也必须注销/登录**：GNOME Shell 会缓存已加载的 JS，
`gnome-extensions disable/enable` 不会重新读取文件。

## 验证

```sh
gnome-extensions info liuqin-stylus-battery@liuqin
cat /sys/class/power_supply/qcom-battmgr-pen/present
cat /sys/class/power_supply/qcom-battmgr-pen/capacity
cat /sys/class/power_supply/qcom-battmgr-pen/status
```

把笔吸上/拿开，顶栏应在 30 秒内出现/消失；菜单里的状态应随充电状态变化。
内核侧优先使用固件 `NOTIF_XM_PROPERTY` 通知，只在笔在位时保留 60 秒兜底刷新，
笔不在位时 5 分钟兜底一次，不会每 10 秒打 GLINK。

## 撤除

```sh
gnome-extensions disable liuqin-stylus-battery@liuqin
sudo rm -rf /usr/share/gnome-shell/extensions/liuqin-stylus-battery@liuqin
```

## 边界

- 只读 sysfs，不写充电模式、不触发配对、不刷固件。
- 不依赖 UPower 的冷启动枚举；UPower/GNOME 原生电源面板仍可独立显示同一个 `power_supply`。
- 仅声明 GNOME 51；其他版本需要另测。
