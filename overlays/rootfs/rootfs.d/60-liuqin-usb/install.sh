#!/bin/bash
# Product USB NCM layer: apply the preset and fail the build if it did not stick.
set -euo pipefail

systemctl preset liuqin-usb0-link.service liuqin-usb0-dhcp.service
for unit in liuqin-usb0-link.service liuqin-usb0-dhcp.service; do
    systemctl is-enabled --quiet "$unit" || {
        echo "60-liuqin-usb: $unit is not enabled after preset; first boot would disable it" >&2
        exit 1
    }
done

# dnsmasq drops to the dnsmasq user after binding port 67; the lease file must
# be writable by that user.  StateDirectory= alone creates root-owned 0755.
install -d -o dnsmasq -g dnsmasq -m 0755 /var/lib/liuqin-usb0
