#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Stage native FPC activation from the delivered kernel RPM's module manifest.

Offline only: no hardware, credential, firmware extraction or service start.
The upstream late loader rechecks the live kernel and wiring at every boot.
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys


def stage(root):
    root = Path(root).resolve()
    if root == Path('/') or not (root / 'etc/os-release').is_file():
        raise ValueError('an offline rootfs is required')
    runtime = root / 'usr/libexec/liuqin-fingerprint'
    for private in ('var/lib/fprint', 'var/lib/liuqin-fingerprint'):
        path = root / private
        if path.exists() and any(path.iterdir()):
            raise ValueError('private biometric state must not enter an image')
    release = (root / 'usr/share/liuqin/kernel.release').read_text().strip()
    module_path = f'/usr/lib/modules/{release}/kernel/drivers/misc/fpc1264_spi_diag.ko'
    records = [line.split() for line in
               (root / 'usr/share/liuqin/kernel-modules.manifest').read_text().splitlines()]
    hashes = [row[0] for row in records if len(row) == 2 and row[1] == module_path]
    if len(hashes) != 1:
        raise ValueError('FPC module is not uniquely recorded in the kernel RPM manifest')
    module = root / module_path.lstrip('/')
    digest = hashlib.sha256(module.read_bytes()).hexdigest()
    if digest != hashes[0]:
        raise ValueError('FPC module differs from the delivered kernel RPM manifest')
    for name in ('fprintd', 'native_enrol.py', 'stable_module.py', 'liuqin-rpmb-supplicant',
                 'tod/libfprint-tod-fpc1264-oem.so', 'firmware/SHA256.json'):
        if not (runtime / name).is_file():
            raise ValueError('missing FPC runtime: ' + name)
    if not (root / 'usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2').is_file():
        raise ValueError('missing private TOD library')
    candidate = dict(id='fedora-packaged-fpc1264', kernel_release=release,
                     kernel_module_sha256=digest, deployment_mode='installed',
                     enrollment_interface='fprintd', account_profile='primary-uid-1000',
                     linux_uid=1000, native_uid=0x60000000 | 1000,
                     firmware_source='modem_a-read-only', supports_one_finger_per_user=True)
    binding = runtime / 'CANDIDATE.json'
    if binding.exists() and json.loads(binding.read_text()) != candidate:
        raise ValueError('preserve unrelated FPC binding')
    (runtime / 'kernel').mkdir(exist_ok=True)
    target = runtime / 'kernel/fpc1264_spi_diag.ko'
    shutil.copyfile(module, target)
    target.chmod(0o600)
    binding.write_text(json.dumps(candidate, indent=2) + '\n')
    binding.chmod(0o600)
    units = root / 'etc/systemd/system'
    dropin = units / 'fprintd.service.d/60-liuqin-fpc-oem.conf'
    template = (root / 'usr/share/doc/liuqin-fingerprint/fprintd-native.conf').read_bytes()
    if dropin.exists() and dropin.read_bytes() != template:
        raise ValueError('preserve unrelated fprintd activation')
    dropin.parent.mkdir(parents=True, exist_ok=True)
    dropin.write_bytes(template)
    dropin.chmod(0o644)
    wants = units / 'multi-user.target.wants'
    wants.mkdir(parents=True, exist_ok=True)
    link = wants / 'liuqin-fpc-stable-module.service'
    destination = '/usr/lib/systemd/system/liuqin-fpc-stable-module.service'
    if link.is_symlink():
        if str(link.readlink()) != destination:
            raise ValueError('preserve unrelated FPC unit link')
    elif link.exists():
        raise ValueError('preserve unrelated FPC unit file')
    else:
        link.symlink_to(destination)
    print('fingerprint_image=STAGED live_guards=required credentials=absent firmware=local-only')
    return candidate


if __name__ == '__main__':
    stage(sys.argv[1])
