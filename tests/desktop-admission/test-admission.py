#!/usr/bin/env python3
"""Exercise the shipped init admission predicate on isolated synthetic roots.

Run with sudo; no devices/mounts or installed system changes. A tiny static
systemd fixture accepts --version, so the real chroot call is also exercised.
This verifies topology admission, never a working desktop or ARM hardware.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('contract', PROJECT / 'tools/build-root-contract.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
assert os.geteuid() == 0, 'Run with sudo to test real root ownership and chroot'


with tempfile.TemporaryDirectory(prefix='liuqin-desktop-admission-') as tmp:
    work = Path(tmp)
    root = work / 'root'
    envelope = work / 'contracts'
    root.mkdir()
    envelope.mkdir()
    primary = envelope / 'liuqin-fedora-root.contract'
    alternate = envelope / 'liuqin-fedora-root.gnome.contract'
    marker = envelope / 'liuqin-fedora-desktop-transition'
    primary.write_text(c.build_contract_text(c.CONTRACT_HEADERS['fedora']))
    alternate.write_text(c.build_contract_text(c.CONTRACT_HEADERS['fedora'], 'gnome'))
    marker.write_text('gnome-v1\n')
    for entry in set(c.CONTRACT_ENTRIES + c.GNOME_ENTRIES):
        kind, name, *rest = entry
        if kind not in ('file', 'exec', 'marker'):
            continue
        path = root / name.lstrip('/')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('liuqin-fedora-root-v1\n' if kind == 'marker' else 'fixture\n')
        path.chmod(0o755 if kind == 'exec' else 0o644)
    src = work / 'systemd.c'
    src.write_text('int main(void) { return 0; }\n')
    subprocess.run(['cc', '-static', str(src), '-o', str(root / 'usr/lib/systemd/systemd')], check=True)
    for name, target in (
        ('usr/sbin/init', '/usr/lib/systemd/systemd'),
        ('etc/systemd/system/default.target', '/usr/lib/systemd/system/graphical.target'),
        ('usr/lib/systemd/system/default.target', 'graphical.target'),
    ):
        p = root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.symlink_to(target)
    (root / 'usr/lib/systemd/system/graphical.target').write_text('fixture\n')
    dm = root / 'etc/systemd/system/display-manager.service'
    wants = root / 'etc/systemd/system/graphical.target.wants/plasmalogin.service'
    wants.parent.mkdir(parents=True)
    log = work / 'admission.log'
    checks = 0

    def select(unit):
        dm.unlink(missing_ok=True)
        dm.symlink_to('/usr/lib/systemd/system/' + unit)

    def check(label, expected):
        global checks
        env = dict(os.environ, LIUQIN_INIT_STORAGE_TEST_ONLY='1',
                   LIUQIN_INIT_TEST_BUSYBOX=shutil.which('busybox'),
                   LIUQIN_INIT_TEST_PATH='/usr/bin:/bin',
                   LIUQIN_INIT_TEST_LOG=str(log),
                   LIUQIN_STORAGE_FEDORA_CONTRACT=str(primary),
                   LIUQIN_INIT_ADMISSION_ROOT=str(root))
        result = subprocess.run(['busybox', 'sh', str(PROJECT / 'initramfs/init')], env=env,
                                capture_output=True, text=True)
        assert (result.returncode == 0) == expected, (label, result.stderr, log.read_text())
        checks += 1
        print('PASS:', label)

    select('plasmalogin.service')
    check('transition accepts complete KDE route', True)
    select('gdm.service')
    check('transition accepts complete GNOME route', True)
    # TN0083 KDE removal: the selected GNOME branch must tolerate removal of
    # every KDE-specific topology file, not just plasmashell alone.
    kde_only = []
    for entry in c.CONTRACT_ENTRIES:
        if entry in c.GNOME_ENTRIES or entry[0] not in ('file', 'exec'):
            continue
        path = root / entry[1].lstrip('/')
        kde_only.append((path, path.read_bytes(), path.stat().st_mode & 0o777))
        path.unlink()
    check('GNOME accepts a root with all KDE topology files absent', True)
    for path, data, mode in kde_only:
        path.write_bytes(data)
        path.chmod(mode)
    plasma = root / 'usr/bin/plasmashell'
    plasma.unlink()
    check('GNOME does not require KDE binaries', True)
    select('plasmalogin.service')
    check('KDE cannot fall back to complete GNOME when KDE is broken', False)
    plasma.write_text('fixture\n')
    plasma.chmod(0o755)
    select('gdm.service')
    shell = root / 'usr/bin/gnome-shell'
    shell.chmod(0o644)
    check('GNOME cannot fall back to KDE when GNOME is broken', False)
    shell.chmod(0o755)
    os.chown(shell, 1000, 1000)
    check('non-root-owned GNOME binary is rejected', False)
    os.chown(shell, 0, 0)
    wants.symlink_to('/usr/lib/systemd/system/plasmalogin.service')
    check('two enabled managers are rejected', False)
    wants.unlink()
    dm.unlink()
    check('no enabled manager is rejected', False)
    select('unknown.service')
    (root / 'usr/lib/systemd/system/unknown.service').write_text('fixture\n')
    check('unknown alias is rejected', False)
    wants.symlink_to('/usr/lib/systemd/system/plasmalogin.service')
    check('unknown alias cannot be hidden behind valid wants', False)
    wants.unlink()
    select('gdm.service')
    alternate.rename(work / 'saved-gnome')
    check('missing transition payload fails closed', False)
    alternate.symlink_to(work / 'saved-gnome')
    check('symlinked transition payload fails closed', False)
    alternate.unlink()
    (work / 'saved-gnome').rename(alternate)
    marker.write_text('invalid\n')
    check('invalid envelope marker is rejected', False)
    marker.write_text('gnome-v1\n')
    role = root / 'etc/liuqin-fedora-root'
    role.write_text('wrong-device\n')
    check('root identity marker still rejects wrong root', False)
    role.write_text('liuqin-fedora-root-v1\n')
    dm.unlink()
    wants = root / 'etc/systemd/system/graphical.target.wants/gdm.service'
    wants.symlink_to('/usr/lib/systemd/system/gdm.service')
    check('GNOME wants-only enablement is accepted', True)
    wants.unlink()
    select('plasmalogin.service')
    marker.unlink()
    check('legacy KDE v2 behavior remains available without envelope', True)
    select('gdm.service')
    check('old KDE-only boot still rejects GDM', False)
    # Pure GNOME v2 boot is valid too; no dependency on the migration envelope.
    primary.write_bytes(alternate.read_bytes())
    check('standalone GNOME v2 contract accepts GDM', True)
    # First-boot preset-all may remove the /etc alias.  The packaged default
    # still resolves, so the second boot must not be rejected by stage 1.
    (root / 'etc/systemd/system/default.target').unlink()
    check('GNOME remains bootable after the first-boot /etc alias is removed', True)
    vendor_default = root / 'usr/lib/systemd/system/default.target'
    vendor_default.unlink()
    check('a missing packaged default target is still rejected', False)
    vendor_default.symlink_to('graphical.target')
    c.check_rootfs(c.GNOME_ENTRIES, root)
    # The generator must enforce the same unit ownership as the boot parser.
    unit = root / 'usr/lib/systemd/system/gdm.service'
    os.chown(unit, 1000, 1000)
    assert c.entry_error(root, ('display-manager', 'gdm.service')) is not None
    check('non-root-owned login manager is rejected', False)
    os.chown(unit, 0, 0)
    print(f'{checks} admission checks passed')
