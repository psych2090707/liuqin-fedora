#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Stage the liuqin fingerprint userspace payload for RPM packaging.

Source of truth: upstream/xiaomipad-6pro-mainline/device/fingerprint/oem
(read-only). Paths are adapted from the Ubuntu candidate layout
(/usr/local/lib/liuqin-fpc-oem) to the Fedora packaged layout
(/usr/libexec/liuqin-fingerprint). No vendor firmware is copied.
"""
import shutil
import sys
from pathlib import Path

VENDOR = Path(sys.argv[1])
DEST = Path(sys.argv[2])
if DEST.exists():
    shutil.rmtree(DEST)
EXEC = DEST / 'payload/usr/libexec/liuqin-fingerprint'
UNITS = DEST / 'payload/usr/lib/systemd/system'
PRESET = DEST / 'payload/usr/lib/systemd/system-preset'
POLKIT_ACTIONS = DEST / 'payload/usr/share/polkit-1/actions'
POLKIT_RULES = DEST / 'payload/usr/share/polkit-1/rules.d'
DOC = DEST / 'payload/usr/share/doc/liuqin-fingerprint'
for d in (EXEC, UNITS, PRESET, POLKIT_ACTIONS, POLKIT_RULES, DOC,
          DEST / 'payload/usr/share/applications', DEST / 'payload/usr/bin',
          DEST / 'payload/usr/lib/modprobe.d', DEST / 'payload/etc/pam.d'):
    d.mkdir(parents=True, exist_ok=True)

def adapt(text: str) -> str:
    return (text
            .replace('/usr/local/lib/liuqin-fpc-oem/tod', '/usr/libexec/liuqin-fingerprint/tod')
            .replace('/usr/local/lib/liuqin-fpc-oem', '/usr/libexec/liuqin-fingerprint')
            .replace('desktop = ("gdm", "iio-sensor-proxy")', 'desktop = ("display-manager",)')
            .replace('candidate.get("control_service", "ssh")', 'candidate.get("control_service", "sshd")')
            .replace('here / "ufs-rpmb-provider" / "liuqin-rpmb-supplicant"', 'here / "liuqin-rpmb-supplicant"'))

def copy_adapt(src: Path, dst: Path, mode=0o644):
    dst.write_text(adapt(src.read_text()))
    dst.chmod(mode)

fp = VENDOR / 'src/fingerprint'
oem = fp / 'oem'
dep = fp / 'deployment'

# python providers / helpers (run from the private packaged dir)
for name in ('acceptance_input.py', 'authorize_oem.py', 'enrol_publish.py',
             'native_credential_preflight.py', 'native_credentials.py',
             'native_enrol.py', 'oem_runtime.py', 'user_credentials.py'):
    copy_adapt(oem / name, EXEC / name, 0o755)
for name in ('acceptance.py', 'provision_firmware.py', 'stable_module.py', 'verify_once.py'):
    copy_adapt(dep / name, EXEC / name, 0o755)

# PAM service
copy_adapt(oem / 'pam.d/liuqin-fpc-enrol', DEST / 'payload/etc/pam.d/liuqin-fpc-enrol')

# Fixed TA hashes only; extraction remains local to this tablet's modem_a.
firmware = EXEC / 'firmware'
firmware.mkdir()
shutil.copyfile(VENDOR / 'firmware/SHA256.json', firmware / 'SHA256.json')
shutil.copyfile(VENDOR / 'firmware/NOTICE', firmware / 'NOTICE')

# late module load unit (adapted to packaged path)
module_unit = adapt((dep / 'liuqin-fpc-stable-module.service').read_text())
module_unit = module_unit.replace('gdm.service ssh.service NetworkManager.service iio-sensor-proxy.service',
                                  'display-manager.service')
(UNITS / 'liuqin-fpc-stable-module.service').write_text(module_unit)
copy_adapt(dep / 'liuqin-fpc-stable-module.service', DOC / 'liuqin-fpc-stable-module.service.upstream')

# private fprintd daemon unit: derive from upstream drop-in + vendor unit idea
dropin = fp / 'libfprint-tod/fprintd-fpc1264-oem.conf'
unit = f'''[Unit]
Description=liuqin FPC1264 OEM fingerprint daemon (private fprintd, packaged)
Documentation=file:///usr/share/doc/liuqin-fingerprint/README.md
After=liuqin-fpc-stable-module.service
Wants=liuqin-fpc-stable-module.service
ConditionPathExists=/dev/fpc1020
# The TOD adapter is provided by liuqin-fpc1264-tod.
ConditionPathExists=/usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so

[Service]
# Kept disabled by default: enable only after the device-side fingerprint
# acceptance procedure in docs/maintenance/mobile-stack-packages.md.
UMask=0077
Type=simple
ExecStart=/usr/libexec/liuqin-fingerprint/fprintd --no-timeout
Environment=FP_LIUQIN_FPC1264_OEM_ENABLE=1
Environment=FP_DRIVERS_ALLOWLIST=fpc1264_oem
Environment=FP_TOD_DRIVERS_DIR=/usr/libexec/liuqin-fingerprint/tod
Environment=LIUQIN_FPC_OEM_RUNTIME=/usr/libexec/liuqin-fingerprint
RuntimeDirectory=liuqin-fpc-oem-runtime
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
StateDirectory=liuqin-fingerprint
StateDirectoryMode=0700
ReadWritePaths=/sys/module/firmware_class/parameters/path
DeviceAllow=/dev/fpc1020 rw
DeviceAllow=/dev/tee0 rw
DeviceAllow=/dev/teepriv0 rw
DeviceAllow=/dev/bsg/0:0:0:49476 rw
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
'''
(UNITS / 'liuqin-fprintd-oem.service').write_text(unit)
(DOC / 'liuqin-fprintd-oem.service').write_text(unit)
(PRESET / '90-liuqin-fingerprint.preset').write_text(
    '# Hardware-bound; enable only after device acceptance.\n# enable liuqin-fpc-stable-module.service\n'
    '# enable liuqin-fprintd-oem.service\n')

# Standard D-Bus activation must use the same OEM daemon as the desktop/PAM.
# Stored as a template; configure installs it only after checking the live kernel.
activation = adapt(dropin.read_text())
activation += '\n[Service]\nEnvironment=LD_LIBRARY_PATH=/usr/lib64/liuqin-fingerprint/libfprint-tod\n'
(DOC / 'fprintd-native.conf').write_text(activation)
install_bin = DEST / 'payload/usr/bin'
install_bin.mkdir(parents=True, exist_ok=True)
shutil.copyfile(Path(__file__).with_name('configure.py'), install_bin / 'liuqin-fingerprint-configure')
(install_bin / 'liuqin-fingerprint-configure').chmod(0o755)

# KDE lock screen: same flow as authselect's fingerprint-auth, without the
# 30 s pam_fprintd timeout that kscreenlocker treats as permanent (TN0064).
(DEST / 'payload/etc/pam.d/liuqin-kde-fingerprint-auth').write_text(
    '# liuqin KDE lock screen fingerprint stack (liuqin-fingerprint-lockscreen).\n'
    '# Mirrors authselect fingerprint-auth; pam_fprintd waits without a timeout\n'
    '# because kscreenlocker never restarts a timed-out fingerprint service.\n'
    'auth        required                                     pam_env.so\n'
    'auth        [success=done default=bad]                   pam_fprintd.so timeout=-1\n'
    'auth        required                                     pam_deny.so\n')
shutil.copyfile(Path(__file__).with_name('lockscreen-pam.py'), install_bin / 'liuqin-fingerprint-lockscreen')
(install_bin / 'liuqin-fingerprint-lockscreen').chmod(0o755)

# polkit
copy_adapt(dep / 'org.liuqin.fingerprint.policy',
           POLKIT_ACTIONS / 'org.liuqin.fingerprint.policy')
copy_adapt(dep / '60-liuqin-fingerprint-enroll.rules',
           POLKIT_RULES / '60-liuqin-fingerprint-enroll.rules')

# modprobe late-load blacklist (upstream install.py writes this at runtime)
(DEST / 'payload/usr/lib/modprobe.d/liuqin-fpc-late-load.conf').write_text(
    '# Installer-deferred FPC1264 SPI module load (see liuqin-fpc-stable-module.service)\n'
    'blacklist fpc1264_spi_diag\n')

# Native enrollment uses System Settings. Keep legacy providers private;
# upstream native installs also remove the development enrollment launchers.

# docs / provenance
shutil.copyfile(VENDOR / 'README.md', DOC / 'README.md')
shutil.copyfile(VENDOR / 'SOURCE_LOCK.json', DOC / 'SOURCE_LOCK.json')
shutil.copyfile(VENDOR / 'FPRINTD_SOURCE_HASHES.json', DOC / 'FPRINTD_SOURCE_HASHES.json')
shutil.copyfile(VENDOR / 'firmware/NOTICE', DOC / 'firmware-NOTICE')
shutil.copyfile(VENDOR / 'firmware/SHA256.json', DOC / 'firmware-SHA256.json')
shutil.copyfile(fp / 'README.md', DOC / 'fingerprint-README.md')
shutil.copyfile(fp / 'libfprint-tod/README.md', DOC / 'libfprint-tod-README.md')
shutil.copyfile(fp / 'fprintd-oem/README.md', DOC / 'fprintd-oem-README.md')
print(f'staged {sum(1 for _ in DEST.rglob("*") if _.is_file())} payload files')
