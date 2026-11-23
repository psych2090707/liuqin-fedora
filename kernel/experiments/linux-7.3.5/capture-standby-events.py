#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Capture one RTC-bounded battery suspend on the liuqin RAM test kernel."""

import argparse
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import time


RUN = Path("/run/liuqin-standby-events")
TRACEFS = Path("/sys/kernel/tracing")
DEBUGFS = Path("/sys/kernel/debug")
POWER = Path("/sys/power")
SUPPLY = Path("/sys/class/power_supply")
RTC = Path("/sys/class/rtc/rtc0")
EVENTS = (
    "power/suspend_resume",
    "interconnect/icc_set_bw",
    "interconnect/icc_set_bw_end",
    "rpmh/rpmh_send_msg",
)
AUDIO_DEVICES = (
    "3210000.soundwire", "33b0000.soundwire", "3440000.pinctrl",
    "3200000.codec", "3220000.codec", "33f0000.codec",
)
AUDIO_CLOCKS = (
    "LPASS_HW_DCODEC", "LPASS_HW_MACRO", "LPASS_HW_LPR_VOTE",
    "LPASS_CLK_ID_RX_CORE_TX_MCLK", "LPASS_CLK_ID_RX_CORE_MCLK2_2X_MCLK",
    "LPASS_CLK_ID_TX_CORE_MCLK", "LPASS_CLK_ID_VA_CORE_MCLK",
    "LPASS_CLK_ID_VA_CORE_2X_MCLK", "lpass-rx-mclk", "lpass-tx-mclk",
)


def read(path):
    return path.read_text().strip()


def save(name, data):
    (RUN / name).write_text(json.dumps(data, indent=2) + "\n")


def on_battery():
    return (read(SUPPLY / "qcom-battmgr-usb/online") == "0"
            and read(SUPPLY / "qcom-battmgr-wls/online") == "0"
            and read(SUPPLY / "qcom-battmgr-bat/status") == "Discharging")


def counters():
    return {k: int(read(POWER / "suspend_stats" / k)) for k in ("success", "fail")}


def wakeup_irq():
    try:
        return read(POWER / "pm_wakeup_irq")
    except OSError as error:
        if error.errno == errno.ENODATA:
            return None
        raise


def snapshot(sleep_domains=False):
    data = {
        "boottime_ns": time.clock_gettime_ns(time.CLOCK_BOOTTIME),
        "monotonic_ns": time.monotonic_ns(),
        "suspend": counters(),
        "on_battery": on_battery(),
        "rtc_alarm": read(RTC / "wakealarm"),
        "rtc_interrupts": [line.strip() for line in Path("/proc/interrupts").read_text().splitlines()
                           if "rtc_alarm" in line],
        "pm_wakeup_irq": wakeup_irq(),
        "qcom_stats": {name: read(DEBUGFS / "qcom_stats" / name)
                       for name in ("apss", "aosd", "cxsd", "ddr", "adsp")},
    }
    if sleep_domains:
        platform = Path("/sys/bus/platform/devices")
        data["audio_runtime_status"] = {
            name: read(platform / name / "power/runtime_status") for name in AUDIO_DEVICES
        }
        data["audio_clock_counts"] = {
            name: {field: int(read(DEBUGFS / "clk" / name / ("clk_" + field)))
                   for field in ("prepare_count", "enable_count")}
            for name in AUDIO_CLOCKS
        }
        data["additional_qcom_stats"] = {
            name: read(DEBUGFS / "qcom_stats" / name)
            for name in ("cdsp", "slpi", "slpi_island")
        }
    return data


def collect(instance, events):
    for event in events:
        (RUN / (event.replace("/", ".") + ".format")).write_text(
            (instance / "events" / event / "format").read_text())
    save("trace-stats.json", {p.parent.name: read(p)
                             for p in sorted((instance / "per_cpu").glob("cpu*/stats"))})
    (RUN / "suspend.trace").write_text((instance / "trace").read_text())


def event_filters(sleep_domains):
    filters = dict.fromkeys(EVENTS)
    if sleep_domains:
        def match(field, names):
            return " || ".join(f'{field} == "{name}"' for name in names)

        filters.update({
            "rpm/rpm_status": match("name", AUDIO_DEVICES),
            "clk/clk_prepare_complete": match("name", AUDIO_CLOCKS),
            "clk/clk_unprepare_complete": match("name", AUDIO_CLOCKS),
            "clk/clk_enable_complete": match("name", AUDIO_CLOCKS),
            "clk/clk_disable_complete": match("name", AUDIO_CLOCKS),
            "qcom_aoss/aoss_send": None,
            "qcom_aoss/aoss_send_done": None,
        })
    return filters


def measure(instance, filters, sleep_domains):
    alarm = RTC / "wakealarm"
    (instance / "tracing_on").write_text("0\n")
    (instance / "buffer_size_kb").write_text("384\n")
    (instance / "trace_clock").write_text("boot\n")
    for event, expression in filters.items():
        event_path = instance / "events" / event
        if expression is not None:
            (event_path / "filter").write_text(expression + "\n")
        (event_path / "enable").write_text("1\n")
    if "[s2idle]" not in read(POWER / "mem_sleep") or read(alarm):
        raise RuntimeError("requires s2idle and an unused RTC alarm")
    (RUN / "ready").touch()
    deadline = time.monotonic() + 300
    unplugged_since = None
    while time.monotonic() < deadline:
        if on_battery():
            if unplugged_since is None:
                unplugged_since = time.monotonic()
            if time.monotonic() - unplugged_since >= 12:
                break
        else:
            unplugged_since = None
        time.sleep(1)
    else:
        raise RuntimeError("USB/wireless power did not stay offline within the preparation window")

    before = snapshot(sleep_domains)
    save("before.json", before)
    if not before["on_battery"] or before["rtc_alarm"]:
        raise RuntimeError("power or RTC state changed just before suspend")
    wake_time = int(read(RTC / "since_epoch")) + 65
    # An absolute future time on this RTC also refuses to replace an active alarm.
    alarm.write_text(f"{wake_time}\n")
    try:
        if read(alarm) != str(wake_time):
            raise RuntimeError("RTC alarm readback mismatch")
        (instance / "tracing_on").write_text("1\n")
        (instance / "trace_marker").write_text("liuqin-standby-start\n")
        subprocess.run(["systemctl", "suspend"], check=True, timeout=12)
        # systemctl returns on enqueue. Wait for the kernel's result; userspace
        # is frozen during actual sleep, so this does not poll while suspended.
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if counters() != before["suspend"]:
                break
            time.sleep(1)
        else:
            raise RuntimeError("no suspend result within the awake-time deadline")
        (instance / "trace_marker").write_text("liuqin-standby-end\n")
        (instance / "tracing_on").write_text("0\n")
        save("after.json", snapshot(sleep_domains))
    finally:
        if read(alarm) == str(wake_time):
            alarm.write_text("0\n")
        (RUN / "alarm-after").write_text(read(alarm) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sleep-domains", action="store_true",
                        help="also record liuqin audio clock edges and host AOSS messages")
    sleep_domains = parser.parse_args().sleep_domains
    identity = json.loads(Path("/run/liuqin-kernel-ram-test.json").read_text())
    release = os.uname().release
    if (not release.startswith("7.3.5-liuqin-standbytrace")
            or identity["kernel_release"] != release or identity["mode"] != "RAM only"):
        raise RuntimeError("requires the 7.3.5 standby tracing RAM kernel")
    RUN.mkdir(mode=0o700)
    instance = TRACEFS / "instances/liuqin-standby"
    instance.mkdir()
    filters = event_filters(sleep_domains)
    try:
        measure(instance, filters, sleep_domains)
    finally:
        try:
            (instance / "tracing_on").write_text("0\n")
            collect(instance, filters)
            # This maps RPMh addresses to names from shared command-db memory.
            # Do it after tracing so this read cannot change the capture window.
            (RUN / "cmd-db").write_text((DEBUGFS / "cmd-db").read_text())
        finally:
            instance.rmdir()
    (RUN / "complete").touch()


def terminate(_signum, _frame):
    raise SystemExit("capture terminated")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    main()
