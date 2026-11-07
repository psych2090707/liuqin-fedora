Name:           liuqin-clock-support
Version:        1.0
Release:        4%{?dist}
Summary:        Preserve trusted early-boot time for liuqin offline updates
License:        MIT
BuildArch:      noarch
Source0:        %{name}-%{version}.tar.gz
Requires:       systemd >= 247
Requires:       chrony
Requires:       python3 >= 3.9

%description
Keep chronyd as the only NTP client and persist a conservative timestamp for
systemd's native /usr/lib/clock-epoch reader. The optional timer never wakes
the device. Installation does not enable services or modify the clock stamp.

%prep
%autosetup

%build

%install
install -Dm0755 liuqin-clock-save.py %{buildroot}%{_libexecdir}/liuqin/liuqin-clock-save
for unit in liuqin-clock-save.service liuqin-clock-save.timer liuqin-clock-shutdown.service; do
    install -Dm0644 "$unit" "%{buildroot}%{_prefix}/lib/systemd/system/$unit"
done

%files
%license LICENSE
%doc README.md
%{_libexecdir}/liuqin/liuqin-clock-save
%{_prefix}/lib/systemd/system/liuqin-clock-save.service
%{_prefix}/lib/systemd/system/liuqin-clock-save.timer
%{_prefix}/lib/systemd/system/liuqin-clock-shutdown.service

# No scriptlets, presets, clock-epoch payload, chronyd override or auto-activation.
# The administrator's runtime stamp must survive package upgrades/removal.

%changelog
* Fri Oct 30 2026 liuqin project <liuqin@localhost> - 1.0-4
- Keep the already-confined chronyc client identity stable without CAP_SETUID/GID.
* Fri Oct 30 2026 liuqin project <liuqin@localhost> - 1.0-3
- Permit chronyc to create its temporary Unix reply socket under /run/chrony.
* Fri Oct 30 2026 liuqin project <liuqin@localhost> - 1.0-2
- Allow the root service to query chronyd's owner-only Unix socket.
* Fri Oct 30 2026 liuqin project <liuqin@localhost> - 1.0-1
- Prepare a separately activated clock floor for native offline updates.
