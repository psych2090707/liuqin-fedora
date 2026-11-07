#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Reconcile the liuqin rescue gadget with its already negotiated Type-C role.

Board workaround: UCSI's USB_ROLE_NONE maps to the DT's host fallback, even
while Type-C still reports device. Never request a Type-C negotiation/swap or
override a reported host role. Called on uevents and the existing AFK timer.
"""
from pathlib import Path
import time


def reconcile(root=Path('/'), timeout=2):
    role = root / 'sys/class/usb_role/a600000.usb-role-switch/role'
    data = root / 'sys/class/typec/port0/data_role'
    gadget = root / 'sys/kernel/config/usb_gadget/liuqin/UDC'
    marker = root / 'etc/liuqin-slpi-disabled'
    if not marker.exists() or not role.exists() or not data.exists() or not gadget.exists():
        return 'unavailable'
    # A role request is allowed only when the connector already reports device.
    data_value = data.read_text().strip()
    if data_value not in ('device', 'host [device]'):
        return 'connector_not_device'
    if gadget.read_text().strip() != 'a600000.usb':
        return 'gadget_not_bound'
    if role.read_text().strip() == 'device':
        return 'already_device'
    # Recheck before writing: never overwrite a new genuine host negotiation.
    if data.read_text().strip() != data_value:
        return 'connector_changed'
    role.write_text('device\n')
    deadline = time.monotonic() + timeout
    while role.read_text().strip() != 'device':
        if time.monotonic() >= deadline:
            raise RuntimeError('controller did not enter device role')
        time.sleep(0.05)
    return 'corrected_device'


if __name__ == '__main__':
    result = reconcile()
    if result == 'corrected_device':
        print('liuqin USB: reconciled controller with negotiated device role')
