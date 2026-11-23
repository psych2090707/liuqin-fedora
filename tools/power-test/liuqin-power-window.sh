#!/bin/bash
# liuqin-power-window.sh — 纯电池下两段定时挂起，比较 Wi-Fi 开/关的耗电速率。
#
# 用法（root，经 systemd-run 脱离终端）：
#   systemd-run --unit=liuqin-powertest --collect /tmp/liuqin-power-window.sh 480
#
# 关键教训（2026-11-22）：
#   本机 RTC 时基停在 1973 年，写绝对时间（2026 的 epoch）的闹钟永远不会响。
#   必须用 rtcwake，或写 since_epoch + N；否则睡下去只能靠电源键叫醒。
#   `systemctl suspend` 会提前返回，不能用来计时，所以这里直接用 rtcwake。
#
# 行为：
#   1. 最多等 WAIT_MAX 秒直到 USB 供电离线；插着电就退出（FORCE=1 可强制）。
#   2. A 段：Wi-Fi 保持原状，挂起 N 秒。
#   3. B 段：rfkill 关 Wi-Fi，再挂起 N 秒，结束后恢复。
#   4. 结果写 /tmp/liuqin-power-window.log（0644）。
# 只动 Wi-Fi 开关和 RTC 闹钟；不改电源策略、不碰内核和启动分区。
set -u

BAT=/sys/class/power_supply/qcom-battmgr-bat
USB=/sys/class/power_supply/qcom-battmgr-usb
LOG=/tmp/liuqin-power-window.log
WINDOW="${1:-480}"
WAIT_MAX="${2:-1800}"

say() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
bat() { cat "$BAT/$1" 2>/dev/null; }
online() { cat "$USB/online" 2>/dev/null; }
bt() { awk '{printf "%.2f", $1}' /proc/uptime; }

: >"$LOG"
chmod 0644 "$LOG"
say "start window=${WINDOW}s wait_max=${WAIT_MAX}s forced=${FORCE:-0}"

waited=0
while [ "${FORCE:-0}" != "1" ] && [ "$(online)" != "0" ]; do
    if [ "$waited" -ge "$WAIT_MAX" ]; then
        say "abort: USB still online after ${WAIT_MAX}s; nothing tested"
        exit 0
    fi
    sleep 10
    waited=$((waited + 10))
done
say "on battery after ${waited}s; usb_online=$(online)"

# rtcwake 用 RTC 自己的时基，能在这块 RTC 上正确工作。
nap() {
    local secs="$1" b0 b1
    b0="$(bt)"
    rtcwake -m mem -s "$secs" 2>>"$LOG"
    b1="$(bt)"
    awk -v a="$b0" -v b="$b1" 'BEGIN{printf "%.2f", b-a}'
}

run_window() {
    local name="$1" secs="$2"
    local cc0 cap0 ocv0 tmp0 t0 slept cc1 cap1 ocv1 tmp1
    cc0="$(bat charge_counter)"; cap0="$(bat capacity)"
    ocv0="$(bat voltage_ocv)"; tmp0="$(bat temp)"
    t0="$(date +%s)"
    say "$name pre  cap=${cap0}% cc=${cc0} ocv=${ocv0} temp=${tmp0} usb=$(online) wifi_blocked=$(rfkill list wifi 2>/dev/null | grep -c 'Soft blocked: yes')"
    slept="$(nap "$secs")"
    cc1="$(bat charge_counter)"; cap1="$(bat capacity)"
    ocv1="$(bat voltage_ocv)"; tmp1="$(bat temp)"
    say "$name post cap=${cap1}% cc=${cc1} ocv=${ocv1} temp=${tmp1} usb=$(online) slept=${slept}s drain=$(( (cc0 - cc1) / 1000 ))mAh"
}

run_window "A_wifi_on" "$WINDOW"

rfkill block wifi 2>/dev/null || say "rfkill block failed"
sleep 5
say "wifi blocked=$(rfkill list wifi 2>/dev/null | grep -c 'Soft blocked: yes')"
run_window "B_wifi_off" "$WINDOW"
rfkill unblock wifi 2>/dev/null || say "rfkill unblock failed"

echo 0 >/sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
say "done; wifi restored; rtc alarm cleared"
