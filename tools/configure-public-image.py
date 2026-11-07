#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply generic defaults to a NEW offline image, never to the running system."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess


def configure(root, user):
    root = root.resolve(strict=True)
    if root == Path('/') or not (root / 'etc/liuqin-fedora-root').is_file():
        raise ValueError('expected an offline liuqin image with its identity marker')
    if (root / 'proc/self').exists() or (root / 'run/systemd/system').exists():
        raise ValueError('refusing an image with live runtime filesystems')
    accounts = [line.split(':') for line in (root / 'etc/passwd').read_text().splitlines()]
    desktops = [a for a in accounts if 1000 <= int(a[2]) < 65534]
    if len(desktops) != 1 or desktops[0][0] != user or desktops[0][2:4] != ['1000', '1000']:
        raise ValueError('expected exactly the specified desktop account at UID/GID 1000')
    home = root / desktops[0][5].lstrip('/')
    if not home.is_dir() or home.is_symlink():
        raise ValueError('desktop home missing or symlinked')
    branded = subprocess.run(['chroot', str(root), 'rpm', '-qa', '--qf', '%{NAME}\\n'],
                             check=True, capture_output=True, text=True).stdout.splitlines()
    if any(n.startswith(('fedora-release', 'fedora-logos')) for n in branded):
        raise ValueError('official Fedora branding packages must be replaced for the public Remix')
    os_release = root / 'usr/lib/os-release'
    fields = {}
    for line in os_release.read_text().splitlines():
        if '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            fields[key] = value
    fields.update(NAME='"Liuqin Linux (Fedora Remix)"', ID='liuqin', ID_LIKE='fedora',
                  PRETTY_NAME='"Liuqin Linux 45 (Fedora Remix, experimental)"',
                  HOME_URL='"https://github.com/psych2090707/liuqin-fedora"',
                  BUG_REPORT_URL='"https://github.com/psych2090707/liuqin-fedora/issues"')
    os_release.write_text(''.join(f'{k}={v}\n' for k, v in fields.items()))
    for path in (home, home / '.var', home / '.var/app'):
        path.mkdir(exist_ok=True)
        os.chown(path, 1000, 1000)
        path.chmod(0o700 if path == home else 0o755)
    # A public base has no usable shared login password.  The local preparer
    # requires the recipient to set a password before producing install files.
    subprocess.run(['chroot', str(root), 'usermod', '-L', user], check=True)
    subprocess.run(['chroot', str(root), 'usermod', '-L', 'root'], check=True)
    for unit in ('sshd.service', 'sshd.socket', 'liuqin-fpc-stable-module.service'):
        subprocess.run(['chroot', str(root), 'systemctl', 'disable', unit],
                       check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['chroot', str(root), 'systemctl', '--global', 'disable',
                    'liuqin-appearance-sync.service'], check=True)
    auth = subprocess.run(['chroot', str(root), 'authselect', 'current', '--raw'],
                          check=True, capture_output=True, text=True).stdout
    if 'with-fingerprint' in auth.split():
        subprocess.run(['chroot', str(root), 'authselect', 'disable-feature',
                        'with-fingerprint'], check=True)
    preset = root / 'etc/systemd/system-preset/00-liuqin-public.preset'
    preset.parent.mkdir(parents=True, exist_ok=True)
    required_units = ['gdm.service', 'NetworkManager.service', 'bluetooth.service',
                      'liuqin-powerd.service', 'liuqin-wlan-mac.service',
                      'liuqin-bt-preconfigure.service']
    core_units = required_units + ['systemd-resolved.service', 'chronyd.service',
                                  'systemd-oomd.service', 'fstrim.timer', 'tuned.service',
                                  'tuned-ppd.service', 'liuqin-backlight-default.service',
                                  'liuqin-clock-save.timer', 'liuqin-clock-shutdown.service']
    disabled_units = ['sshd.service', 'sshd.socket', 'liuqin-fpc-stable-module.service',
                      'liuqin-slpi.service', 'liuqin-sensor-proxy-refresh.service',
                      'liuqin-sensor-stack.target', 'liuqin-hexagonrpcd-sdsp.service',
                      'liuqin-mipps-auth.service', 'liuqin-daily-log.timer']
    preset.write_text(''.join(f'enable {u}\n' for u in core_units) +
                      ''.join(f'disable {u}\n' for u in disabled_units))
    preset.chmod(0o644)
    # This authentication/negotiation path has no accepted 67 W result.  Udev
    # activation bypasses "disable", so keep it masked in the public baseline.
    auth_unit = root / 'etc/systemd/system/liuqin-mipps-auth.service'
    auth_unit.unlink(missing_ok=True)
    auth_unit.symlink_to('/dev/null')
    android_entry = root / 'usr/share/applications/liuqin-reboot-to-android.desktop'
    if android_entry.exists():
        text = android_entry.read_text()
        text = re.sub(r'^NoDisplay=.*\n?', '', text, flags=re.M)
        android_entry.write_text(text.rstrip() + '\nNoDisplay=true\n')
    optional = root / 'usr/share/liuqin/optional'
    optional.mkdir(parents=True, exist_ok=True)
    custom_input = root / 'etc/dconf/db/local.d/20-liuqin-gnome-input'
    if custom_input.exists():
        custom_input.replace(optional / custom_input.name)
    extensions = root / 'etc/dconf/db/local.d/30-liuqin-gnome-extensions'
    extensions.write_text("[org/gnome/shell]\nenabled-extensions=['liuqin-stylus-battery@liuqin']\n")
    extensions.chmod(0o644)
    subprocess.run(['chroot', str(root), 'dconf', 'update'], check=True)
    # Simulate the same preset operation systemd performs on first boot, with
    # the native host tool operating ONLY on the offline image.
    subprocess.run(['systemctl', '--root', str(root), 'preset-all'], check=True)
    for unit in required_units:
        subprocess.run(['systemctl', '--root', str(root), 'is-enabled', '--quiet', unit], check=True)
    for unit in ('liuqin-lid-policy.service', 'liuqin-power-keyd.service', 'sshd.service'):
        if subprocess.run(['systemctl', '--root', str(root), 'is-enabled', '--quiet', unit]).returncode == 0:
            raise ValueError('unexpected enabled unit after first-boot presets: ' + unit)
    target = subprocess.check_output(['systemctl', '--root', str(root), 'get-default'], text=True).strip()
    if target != 'graphical.target':
        raise ValueError('public image does not boot to graphical.target after presets')
    for config in (root / 'etc/sudoers.d').glob('*'):
        if config.is_file() and re.search(r'^\s*[^#\n].*NOPASSWD', config.read_text(), re.M):
            raise ValueError('public image must not contain passwordless sudo rules')
    for name in ('authorized_keys', 'id_rsa', 'id_ed25519'):
        if any(home.rglob(name)) or any((root / 'root').rglob(name)):
            raise ValueError('public image contains SSH credentials')
    machine_id = root / 'etc/machine-id'
    machine_id.write_text('')
    machine_id.chmod(0o444)
    policy = {
        'format': 'liuqin-public-image/1', 'desktop_user': user,
        'requires_local_preparation': True,
        'default': ['powerd', 'keyboard-nowake', 'stylus-battery', 'native-ibus'],
        'optional_disabled': ['custom-osk', 'light-style', 'appearance-sync', 'fingerprint'],
        'dual_boot': 'not verified; not supported by this first release',
        'root_password_login': 'locked', 'sshd': 'disabled',
    }
    (root / 'usr/share/liuqin/public-image.json').write_text(json.dumps(policy, indent=2) + '\n')
    print('Public defaults applied: native input; stylus enabled; optional customizations disabled')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--user', required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('root is required to preserve image ownership')
    root = args.root.resolve(strict=True)
    if root == Path('/') or not (root / 'etc/liuqin-fedora-root').is_file():
        parser.error('expected an offline liuqin image')
    if (root / 'proc/self').exists() or (root / 'run/systemd/system').exists():
        parser.error('refusing a live root')
    devnull = root / 'dev/null'
    created = not devnull.exists()
    if created:
        os.mknod(devnull, stat.S_IFCHR | 0o666, os.makedev(1, 3))
        devnull.chmod(0o666)
    try:
        configure(root, args.user)
    finally:
        if created:
            devnull.unlink()
