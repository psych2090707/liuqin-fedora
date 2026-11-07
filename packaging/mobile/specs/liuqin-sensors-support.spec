Name:           liuqin-sensors-support
Version:        1.0
Release:        1%{?dist}
Summary:        Xiaomi Pad 6 Pro (liuqin) sensor stack policy, units and helpers
License:        MIT
URL:            https://github.com/yzddmr6/xiaomipad-6pro-mainline
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       iio-sensor-proxy >= 3.9
Requires:       hexagonrpc >= 0.5.0
Requires:       libssc >= 0.4.4
Requires:       systemd
Requires:       polkit
Requires(post): systemd
Requires(postun): systemd
%{?sysusers_requires_compat}

%description
Fedora path/KDE-adapted policy layer for the liuqin Qualcomm SSC sensor stack:
systemd units, udev rules, polkit rules, sysusers/tmpfiles entries and helper
scripts derived from yzddmr6/xiaomipad-6pro-mainline device/sensors-overlay.

Not included: the device-specific SSC registry/calibration data (import it from
the owner's own stock ROM with liuqin-sensor-registry-import).

%prep
%autosetup -n %{name}-%{version}

%install
mkdir -p %{buildroot}
cp -a usr %{buildroot}/
# overlay is authored for /etc and /usr/local; relocate to Fedora vendor paths
install -d %{buildroot}%{_unitdir} %{buildroot}%{_userunitdir} \
           %{buildroot}%{_udevrulesdir} %{buildroot}%{_datadir}/polkit-1/rules.d \
           %{buildroot}%{_sysusersdir} %{buildroot}%{_tmpfilesdir}
cp -a etc/systemd/system/. %{buildroot}%{_unitdir}/
cp -a etc/systemd/user/. %{buildroot}%{_userunitdir}/
cp -a etc/udev/rules.d/. %{buildroot}%{_udevrulesdir}/
cp -a etc/polkit-1/rules.d/. %{buildroot}%{_datadir}/polkit-1/rules.d/
cp -a etc/sysusers.d/. %{buildroot}%{_sysusersdir}/
cp -a etc/tmpfiles.d/. %{buildroot}%{_tmpfilesdir}/
chmod 0755 %{buildroot}%{_libexecdir}/liuqin/* \
             %{buildroot}%{_libexecdir}/liuqin-ssc-sample-gate
install -d %{buildroot}%{_datadir}/qcom/sm8450/Xiaomi/liuqin/sensors/config
install -d %{buildroot}%{_datadir}/qcom/sm8450/Xiaomi/liuqin/sensors

%post
%sysusers_create_compat %{_sysusersdir}/liuqin-fastrpc.conf
%tmpfiles_create %{_tmpfilesdir}/liuqin-sensors.conf

%preun
%systemd_preun liuqin-slpi.service liuqin-sensor-proxy-refresh.service liuqin-sensor-proxy-session-refresh.service

%postun
%systemd_postun liuqin-slpi.service liuqin-sensor-proxy-refresh.service liuqin-sensor-proxy-session-refresh.service

%files
%{_datadir}/doc/liuqin/README-sensors.md
%{_datadir}/doc/liuqin/sensor-stack-sources.manifest
%{_datadir}/doc/liuqin/sensor-stack-patches.manifest
%{_libexecdir}/liuqin/slpi
%{_libexecdir}/liuqin/sensor-proxy-refresh
%{_libexecdir}/liuqin/sensor-proxy-session-refresh
%{_libexecdir}/liuqin/sensor-registry-import
%{_libexecdir}/liuqin-ssc-sample-gate
%{_unitdir}/liuqin-hexagonrpcd-sdsp.service
%{_unitdir}/liuqin-slpi.service
%{_unitdir}/liuqin-ssc-sample-gate.service
%{_unitdir}/liuqin-sensor-proxy-refresh.service
%{_unitdir}/liuqin-sensor-stack.target
%{_unitdir}/iio-sensor-proxy.service.d/90-liuqin-ssc.conf
%{_userunitdir}/liuqin-sensor-proxy-session-refresh.service
%{_presetdir}/90-liuqin-sensors.preset
%{_userpresetdir}/90-liuqin-sensors.preset
%{_udevrulesdir}/80-liuqin-fastrpc.rules
%{_datadir}/polkit-1/rules.d/49-liuqin-sensorproxy.rules
%{_sysusersdir}/liuqin-fastrpc.conf
%{_tmpfilesdir}/liuqin-sensors.conf
%dir %{_datadir}/qcom/sm8450/Xiaomi/liuqin
%dir %{_datadir}/qcom/sm8450/Xiaomi/liuqin/sensors
%dir %{_datadir}/qcom/sm8450/Xiaomi/liuqin/sensors/config

%changelog
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 1.0-1
- Fedora/KDE adaptation of liuqin sensors-overlay
