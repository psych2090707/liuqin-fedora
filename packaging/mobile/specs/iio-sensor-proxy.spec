Name:           iio-sensor-proxy
Epoch:          1
Version:        3.9
Release:        2.liuqin%{?dist}
Summary:        IIO accelerometer sensor to input device proxy (SSC-enabled, liuqin)
License:        GPL-3.0-or-later
URL:            https://gitlab.freedesktop.org/hadess/iio-sensor-proxy
Source0:        %{name}-%{version}.tar.gz
Patch0001:      0003-iio-sensor-proxy-start-preclaimed-coldplug-sensor.patch
Patch0002:      0004-iio-sensor-proxy-serialize-ssc-accel-polling.patch
Patch0003:      0005-iio-sensor-proxy-cancel-released-pending-claims.patch
Patch0004:      0006-iio-sensor-proxy-broadcast-sensor-availability.patch
BuildRequires:  meson
BuildRequires:  gcc
BuildRequires:  pkgconfig(glib-2.0) >= 2.76
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(gudev-1.0) >= 237
BuildRequires:  pkgconfig(polkit-gobject-1) >= 0.91
BuildRequires:  pkgconfig(libssc) >= 0.4.4
BuildRequires:  systemd-devel
BuildRequires:  libssc-devel
Requires:       libssc%{?_isa} >= 0.4.4

%description
iio-sensor-proxy exports accelerometer, light and compass readings from the
Linux IIO subsystem over D-Bus (net.hadess.SensorProxy).

This is the liuqin build: 3.9 with upstream libssc (Qualcomm SSC) support
enabled plus the four liuqin sensor patches from
yzddmr6/xiaomipad-6pro-mainline. It intentionally replaces the Fedora
iio-sensor-proxy package (Epoch 1 so it stays newer than Fedora's 3.9-3.fc45)
so that the KDE/KWin auto-rotation path and the liuqin sample-gate drop-in use
one binary and one D-Bus name.

%prep
%autosetup -p1 -n %{name}-%{version}

%build
%meson -Dssc-support=enabled -Dtests=false -Dgtk-tests=false -Dgtk_doc=false \
       -Dudevrulesdir=%{_udevrulesdir} -Dsystemdsystemunitdir=%{_unitdir} \
      
%meson_build

%install
%meson_install
install -Dpm0644 COPYING %{buildroot}%{_licensedir}/%{name}/COPYING

%files
%license %{_licensedir}/%{name}/COPYING
%{_libexecdir}/iio-sensor-proxy
%{_bindir}/monitor-sensor
%{_unitdir}/iio-sensor-proxy.service
%{_udevrulesdir}/80-iio-sensor-proxy.rules
%{_datadir}/dbus-1/system.d/net.hadess.SensorProxy.conf
%{_datadir}/polkit-1/actions/net.hadess.SensorProxy.policy

%changelog
* Fri Nov 06 2026 liuqin project <liuqin@localhost> - 3.9-2.liuqin
- Add Epoch 1 and bump release: the 11-06 dnf upgrade replaced 3.9-1.liuqin.fc45
  with Fedora's 3.9-3.fc45 (no libssc), disabling the SSC path.
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 3.9-1.liuqin
- SSC-enabled build with liuqin claim/polling/availability patches
