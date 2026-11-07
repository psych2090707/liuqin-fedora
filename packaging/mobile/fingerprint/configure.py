#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Bind packaged FPC userspace to a separately verified kernel artifact.

No enrollment, credential creation, boot writes or sensor-processor startup.
The caller supplies the release/hash from the matching kernel build, never a
hash inferred from whatever module happens to be installed on the tablet.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import time

RUNTIME = Path('/usr/libexec/liuqin-fingerprint')
DROPIN = Path('/etc/systemd/system/fprintd.service.d/60-liuqin-fpc-oem.conf')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-release', required=True)
    parser.add_argument('--module-sha256', required=True)
    parser.add_argument('--apply', action='store_true', help='Install binding and start native fprintd')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('root required')
    if not re.fullmatch(r'[a-zA-Z0-9_.+-]+', args.kernel_release):
        parser.error('invalid kernel release')
    if not re.fullmatch(r'[0-9a-f]{64}', args.module_sha256):
        parser.error('invalid module digest')
    if os.uname().release != args.kernel_release:
        raise RuntimeError('Running kernel differs from the selected build')
    pwd.getpwuid(1000)
    module = Path('/usr/lib/modules') / args.kernel_release / 'kernel/drivers/misc/fpc1264_spi_diag.ko'
    if sha(module) != args.module_sha256:
        raise RuntimeError('Installed module differs from the selected build')
    for name in ('stable_module.py', 'provision_firmware.py', 'native_enrol.py',
                 'native_credentials.py', 'fprintd', 'qsee-supplicant',
                 'liuqin-rpmb-supplicant', 'qsee-gatekeeper', 'fpc-oem-print',
                 'tod/libfprint-tod-fpc1264-oem.so', 'firmware/SHA256.json'):
        if not (RUNTIME / name).is_file():
            raise RuntimeError('Missing packaged runtime: ' + name)
    if not Path('/usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2').is_file():
        raise RuntimeError('Private TOD library missing')
    node = Path('/sys/bus/spi/devices/spi1.0/of_node')
    regulator = Path('/sys/firmware/devicetree/base/soc@0/rsc@17a00000/regulators-1/ldo9')
    if (not Path('/dev/tee0').exists() or
            b'fpc,fpc1020' not in (node / 'compatible').read_bytes() or
            (node / 'vdd-supply').read_bytes() != (regulator / 'phandle').read_bytes() or
            int.from_bytes((regulator / 'regulator-min-microvolt').read_bytes(), 'big') != 2960000 or
            int.from_bytes((regulator / 'regulator-max-microvolt').read_bytes(), 'big') != 3008000):
        raise RuntimeError('Stable FPC device-tree/TEE checks failed')
    subprocess.run(['systemctl', 'is-active', '--quiet', 'display-manager.service'], check=True)
    template = Path('/usr/share/doc/liuqin-fingerprint/fprintd-native.conf')
    text = template.read_text()
    if DROPIN.is_symlink() or (DROPIN.exists() and DROPIN.read_text() != text):
        raise RuntimeError('Preserve unrelated native fprintd configuration')
    candidate = dict(id='fedora-packaged-fpc1264', kernel_release=args.kernel_release,
                     kernel_module_sha256=args.module_sha256, deployment_mode='installed',
                     enrollment_interface='fprintd', account_profile='primary-uid-1000',
                     linux_uid=1000, native_uid=0x60000000 | 1000,
                     firmware_source='modem_a-read-only', supports_one_finger_per_user=True)
    binding = RUNTIME / 'CANDIDATE.json'
    if binding.exists() and json.loads(binding.read_text()) != candidate:
        raise RuntimeError('Preserve existing candidate; explicit upgrade required')
    print('fingerprint_binding=CHECKED module_hash=matched dt_voltage=matched account_uid=1000')
    if not args.apply:
        return
    backup = Path('/var/lib/liuqin-fingerprint/setup-backups') / str(time.time_ns())
    backup.mkdir(parents=True, mode=0o700)
    for path in (binding, DROPIN):
        if path.exists():
            shutil.copy2(path, backup / path.name)
    (backup / 'before.json').write_text(json.dumps({
        'binding_existed': binding.exists(), 'dropin_existed': DROPIN.exists(),
        'module_unit_enabled': subprocess.run(['systemctl', 'is-enabled',
            'liuqin-fpc-stable-module.service'], capture_output=True, text=True).stdout.strip(),
    }, indent=2) + '\n')
    kernel = RUNTIME / 'kernel'
    kernel.mkdir(exist_ok=True)
    target = kernel / module.name
    if target.is_symlink() or (target.exists() and sha(target) != args.module_sha256):
        raise RuntimeError('Preserve unrelated runtime module')
    shutil.copyfile(module, target)
    target.chmod(0o600)
    binding.write_text(json.dumps(candidate, indent=2) + '\n')
    binding.chmod(0o600)
    # Reuse the upstream guarded loader, including local read-only modem
    # extraction. No fprintd activation occurs if any guard/extraction fails.
    sys.path.insert(0, str(RUNTIME))
    from stable_module import load
    load()
    DROPIN.parent.mkdir(parents=True, exist_ok=True)
    DROPIN.write_text(text)
    DROPIN.chmod(0o644)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', 'liuqin-fpc-stable-module.service'], check=True)
    subprocess.run(['systemctl', 'restart', 'fprintd.service'], check=True)
    print('fingerprint_activation=STARTED enrollment=NOT_RUN backup=' + str(backup))


if __name__ == '__main__':
    main()
