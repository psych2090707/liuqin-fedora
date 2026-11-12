%global debug_package %{nil}
%global __os_install_post %{nil}

# Distribution-neutral liuqin device services, relocated to Fedora paths.
#
# Included upstream pieces:
#   * systemd units/drop-ins: power-key policy, backlight default, WLAN MAC,
#     Bluetooth public address, MiPPS charger authentication, Gunyah node hide,
#     logind power-key handoff, NetworkManager/BlueZ ordering drop-ins
#   * udev rules (camera DMA-BUF heap, magnetic-keyboard touchpad, MiPPS auth)
#   * polkit action + desktop entry for the dual-boot "Reboot to Android"
#   * modprobe order for the camera clock controller
#   * chrony no-RTC bootstrap drop-in
#   * helpers: liuqin-power-keyd (static aarch64), liuqin-reboot (static
#     aarch64), liuqin-mipps-auth (Python), liuqin-switch (dual-boot boot image
#     rotation), liuqin-wlan-mac, liuqin-bt-public-addr, liuqin-backlight-default
#   * Fedora/KDE replacement for the GNOME-specific power-key action helper
#
# Excluded deliberately (GNOME/Ubuntu specific): dconf + GDM profiles,
# gnome-storage-guard, gnome-usb-rescue, snap admission, Snapshot desktop/dbus
# entries, liuqin-shell, liuqin-camera, liuqin-rescue, the zenity/GNOME power
# menu, the GNOME power settings GSchema, flash-kernel marker, dmabuf env.

Name:           liuqin-device-support
Version:        0.6.0
Release:        3%{?dist}
Summary:        Xiaomi Pad 6 Pro (liuqin) system services and helpers
License:        MIT AND GPL-2.0-only
URL:            https://github.com/yzddmr6/xiaomipad-6pro-mainline
Source0:        device-support-tree.tar
Source1:        relocate-device-support.sh
Source2:        liuqin-power-key-action
Source3:        liuqin-power-keyd
Source4:        liuqin-reboot
Source5:        elf-check.py
Source6:        source-sha256-device-support.txt
Source7:        NOTICE
Source8:        LICENSE
Source9:        device-support-README.md
Source10:       liuqin-daily-log.py
Source11:       liuqin-daily-log.service
Source12:       liuqin-daily-log.timer
Source13:       liuqin-gpu-hang-watch.py
Source14:       liuqin-gpu-hang-watch.service
# BuildArch is deliberately omitted: rpmbuild --target aarch64 sets the
# package arch and an explicit BuildArch is rejected by a foreign build host.
AutoReqProv:    no
BuildRequires:  systemd-rpm-macros
Requires:       systemd
Requires:       polkit
Requires:       python3
Requires:       coreutils
Requires:       util-linux
Recommends:     NetworkManager
Recommends:     bluez
Recommends:     chrony
Recommends:     upower
# The units enable themselves through their [Install] sections only when the
# image assembly enables them; the RPM never runs systemctl (chroot images).

%description
Device services for the Xiaomi Pad 6 Pro (liuqin, SM8475) running a Fedora
image: Android-like power-key policy helper, the dual-boot boot-image switcher
and its polkit action, MiPPS/PD charger authentication, backlight default,
WLAN MAC and Bluetooth address provisioning, camera/udev helpers, the
logind power-key handoff and the no-RTC chrony bootstrap.

The helper binaries are built separately as static aarch64 executables and the
architecture/static identity is asserted at package time.

%prep
cd %{_sourcedir}
sha256sum -c --quiet source-sha256-device-support.txt
python3 %{SOURCE5} --static %{SOURCE3} %{SOURCE4}

work=%{_builddir}/tree
rm -rf "$work"
mkdir -p "$work"
tar -xf %{SOURCE0} -C "$work"
[ -d "$work/device/gnome-overlay" ] ||
	{ echo 'upstream overlay missing from staged tree' >&2; exit 1; }

%build
# All binaries were cross-built on the build host (static aarch64) and are
# shipped as Sources; this package does not execute target code at build time.

%install
mkdir -p %{buildroot}
sh %{SOURCE1} \
	--tree %{_builddir}/tree \
	--root %{buildroot} \
	--power-keyd %{SOURCE3} \
	--reboot %{SOURCE4} \
	--action %{SOURCE2} \
	--chrony-dir %{_sysconfdir}/chrony.d

# Final identity checks on the installed payload.
python3 %{SOURCE5} --static \
	%{buildroot}%{_libexecdir}/liuqin/liuqin-power-keyd \
	%{buildroot}%{_libexecdir}/liuqin/liuqin-reboot
[ "$(find %{buildroot}%{_unitdir} -maxdepth 1 -name 'liuqin-*.service' | wc -l)" = 7 ] ||
	{ echo 'unexpected number of liuqin systemd units' >&2; exit 1; }
[ -x %{buildroot}%{_libexecdir}/liuqin/liuqin-switch ] ||
	{ echo 'liuqin-switch is not executable' >&2; exit 1; }
[ -x %{buildroot}%{_libexecdir}/liuqin/liuqin-mipps-auth ] ||
	{ echo 'liuqin-mipps-auth is not executable' >&2; exit 1; }
# No bytecode caches from host Python, no Ubuntu/ GNOME leftovers.
find %{buildroot} -name '__pycache__' -prune -exec rm -rf {} + || true

install -D -m0644 %{SOURCE8} %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -D -m0644 %{SOURCE7} %{buildroot}%{_datadir}/licenses/%{name}/NOTICE
install -D -m0644 %{SOURCE9} %{buildroot}%{_defaultdocdir}/%{name}/README.device-support.md
install -D -m0644 %{SOURCE10} %{buildroot}%{_libexecdir}/liuqin/daily-log.py
install -D -m0644 %{SOURCE11} %{buildroot}%{_unitdir}/liuqin-daily-log.service
install -D -m0644 %{SOURCE12} %{buildroot}%{_unitdir}/liuqin-daily-log.timer
install -D -m0644 %{SOURCE13} %{buildroot}%{_libexecdir}/liuqin/gpu-hang-watch.py
install -D -m0644 %{SOURCE14} %{buildroot}%{_unitdir}/liuqin-gpu-hang-watch.service

%files
%license %{_datadir}/licenses/%{name}/LICENSE
%license %{_datadir}/licenses/%{name}/NOTICE
%doc %{_defaultdocdir}/%{name}/README.device-support.md
%{_unitdir}/liuqin-power-keyd.service
%{_unitdir}/liuqin-power-keyd.service.d/20-liuqin-session-runtime.conf
%{_unitdir}/liuqin-backlight-default.service
%{_unitdir}/liuqin-bt-preconfigure.service
%{_unitdir}/liuqin-wlan-mac.service
%{_unitdir}/liuqin-mipps-auth.service
%{_unitdir}/liuqin-mipps-battery-auth.service
%{_prefix}/lib/systemd/system-preset/90-liuqin-mipps.preset
%{_unitdir}/liuqin-hide-gunyah-node.service
%{_unitdir}/bluetooth.service.d/20-liuqin-public-address.conf
%{_unitdir}/NetworkManager.service.d/20-liuqin-wlan-mac.conf
%{_prefix}/lib/systemd/logind.conf.d/90-liuqin.conf
%{_unitdir}/chronyd.service.d/20-liuqin-no-rtc.conf
%{_udevrulesdir}/70-liuqin-camera-heap.rules
%{_udevrulesdir}/70-liuqin-touchpad-external.rules
%{_udevrulesdir}/90-liuqin-mipps-auth.rules
%{_prefix}/lib/modprobe.d/liuqin-camera.conf
%{_datadir}/polkit-1/actions/io.github.liuqin.switch.policy
%{_datadir}/applications/liuqin-reboot-to-android.desktop
%config(noreplace) %{_sysconfdir}/chrony.d/00-liuqin-no-rtc.conf
%{_libexecdir}/liuqin/liuqin-power-keyd
%{_libexecdir}/liuqin/liuqin-power-key-action
%{_libexecdir}/liuqin/liuqin-reboot
%{_libexecdir}/liuqin/liuqin-mipps-auth
%{_libexecdir}/liuqin/liuqin-backlight-default
%{_libexecdir}/liuqin/liuqin-wlan-mac
%{_libexecdir}/liuqin/liuqin-bt-public-addr
%{_libexecdir}/liuqin/liuqin-switch
%{_libexecdir}/liuqin/daily-log.py
%{_unitdir}/liuqin-daily-log.service
%{_unitdir}/liuqin-daily-log.timer
%{_libexecdir}/liuqin/gpu-hang-watch.py
%{_unitdir}/liuqin-gpu-hang-watch.service

%changelog
* Mon Oct 26 2026 liuqin-fedora project <liuqin@localhost> - 0.6.0-2
- Ship bounded passive daily-use logging; timer activation remains explicit.
* Tue Oct 20 2026 liuqin-fedora project <liuqin@localhost> - 0.6.0-1
- Initial packaging from xiaomipad-6pro-mainline v0.6.0; Fedora/KDE paths.
