Name:           liuqin-gnome-support
Version:        1.0
Release:        3%{?dist}
Summary:        GNOME session integration for Xiaomi Pad 6 Pro
License:        MIT
BuildArch:      noarch
Source0:        %{name}-%{version}.tar.gz
Requires:       liuqin-device-support >= 0.6.0
Requires:       gdm
Requires:       gnome-shell
Requires:       gnome-session-wayland-session
Requires:       gnome-settings-daemon
Requires:       ibus
Requires:       ibus-libpinyin
Requires:       gnome-keyring
Requires:       gnome-keyring-pam
Requires:       xdg-desktop-portal-gnome
Requires:       xdg-desktop-portal-gtk
Requires:       dconf
Requires:       python3
Requires:       util-linux
Requires:       glib2

%description
Fedora GNOME input, screen-lock and power-key integration. Does not depend on
Plasma, change the display-manager alias, enable services, suspend, or reboot.
Activation is an explicit, backed-up operation on the device.

%prep
%autosetup

%build

%install
mkdir -p %{buildroot}
cp -a payload/. %{buildroot}/

%files
%license LICENSE
%doc README.md
%{_libexecdir}/liuqin/gnome-power-key-action
%config(noreplace) /etc/environment.d/60-liuqin-input.conf
%config(noreplace) /etc/profile.d/zz-liuqin-wayland-input.sh
%config(noreplace) /etc/systemd/logind.conf.d/95-liuqin-power-keys.conf
%config(noreplace) /etc/systemd/logind.conf.d/96-liuqin-gnome-lid.conf
%config(noreplace) /etc/systemd/system/liuqin-power-keyd.service.d/30-gnome-action.conf
%config(noreplace) /etc/dconf/db/local.d/20-liuqin-gnome-input
%config(noreplace) /etc/dconf/db/local.d/20-liuqin-gnome-lock
%config(noreplace) /etc/dconf/db/local.d/10-liuqin-gnome-power

# No RPM scriptlets: the migration driver validates and reloads configuration
# without restarting the live graphical session or hardware services.

%changelog
* Wed Oct 28 2026 liuqin project <liuqin@localhost> - 1.0-3
- Keep GNOME's native power-button action at 'nothing' for the custom
  power-key/lid policy app and services

* Wed Oct 28 2026 liuqin project <liuqin@localhost> - 1.0-2
- Restore the native GNOME power-button action (suspend) after the
  Chassis/VM fix; keep the custom liuqin-power-keyd service disabled

* Wed Oct 28 2026 liuqin project <liuqin@localhost> - 1.0-1
- Own the existing native GNOME power helper and session-independent IBus defaults
