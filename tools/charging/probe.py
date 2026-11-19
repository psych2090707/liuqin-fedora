#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""One read-only charging snapshot, suitable for `ssh ... sudo python3 -`.

No authentication, sysfs writes, service changes or raw challenge collection.
Fields are sequential reads, not a simultaneous electrical measurement.
"""
import json
from pathlib import Path
import struct
import time


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError as exc:
        return {"error": exc.errno}


def build_id():
    data = Path('/sys/kernel/notes').read_bytes()
    offset, found = 0, []
    while offset + 12 <= len(data):
        namesz, descsz, kind = struct.unpack_from('<III', data, offset)
        offset += 12
        desc_at = offset + ((namesz + 3) & ~3)
        end = desc_at + descsz
        if end > len(data):
            raise ValueError('truncated kernel note')
        if data[offset:offset + namesz].rstrip(b'\0') == b'GNU' and kind == 3:
            found.append(data[desc_at:end].hex())
        offset = desc_at + ((descsz + 3) & ~3)
    if len(found) != 1:
        raise ValueError('expected one GNU build ID')
    return found[0]


start = time.clock_gettime(time.CLOCK_BOOTTIME)
supplies = Path('/sys/class/power_supply')
power_fields = 'online status health capacity temp voltage_now current_now voltage_max current_max input_current_limit usb_type'.split()
xm_fields = 'authentic slave_authentic pd_verifed adapter_svid adapter_id real_type current_state pdo2 apdo_max power_max fastchg_mode'.split()
glink = Path('/sys/devices/platform/pmic-glink')
thermal = {}
for p in Path('/sys/bus/iio/devices').glob('iio:device*/in_temp*_label'):
    label = read(p)
    if label in ('cpu_therm', 'quiet_therm', 'conn_therm', 'charger_therm0', 'wifi_therm'):
        thermal[str(p.with_name(p.name.removesuffix('_label') + '_input'))] = {
            'label': label,
            'milli_celsius': read(p.with_name(p.name.removesuffix('_label') + '_input')),
        }
snapshot = {
    'realtime_ns': time.time_ns(), 'boottime_start': start,
    'monotonic': time.monotonic(),
    'boot_id': read('/proc/sys/kernel/random/boot_id'), 'build_id': build_id(),
    'ram_identity': read('/run/liuqin-kernel-ram-test.json'),
    'power_supply': {p.name: {n: read(p/n) for n in power_fields if (p/n).exists()}
                     for p in supplies.glob('qcom-battmgr-*')},
    'xiaomi': {str(p): {n: read(p/n) for n in xm_fields if (p/n).exists()}
               for p in glink.glob('*/xiaomi')},
    'connector_firmware_deci_celsius': {str(p): read(p) for p in glink.glob('*/raw_xm_connector_temp')},
    'thermistors': thermal,
    'typec': {str(p): read(p) for n in ('data_role', 'power_role', 'power_operation_mode')
              for p in Path('/sys/class/typec').glob('port*/'+n)},
    'usb_role': {str(p): read(p) for p in Path('/sys/class/usb_role').glob('*/role')},
    'suspend_stats': {p.name: read(p) for p in Path('/sys/power/suspend_stats').glob('*') if p.is_file()},
    'slpi_disabled': Path('/etc/liuqin-slpi-disabled').exists(),
}
snapshot['boottime_end'] = time.clock_gettime(time.CLOCK_BOOTTIME)
print(json.dumps(snapshot, sort_keys=True))
