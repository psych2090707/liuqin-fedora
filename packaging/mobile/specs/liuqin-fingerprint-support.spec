Name:           liuqin-fingerprint-support
Version:        1.0
Release:        7.liuqin%{?dist}
Summary:        Xiaomi Pad 6 Pro (liuqin) FPC1264 fingerprint policy and helpers
License:        MIT AND BSD-3-Clause AND BSD-3-Clause-Clear
URL:            https://github.com/yzddmr6/xiaomipad-6pro-mainline
Source0:        %{name}-%{version}.tar.gz
Source1:        qcbor-1.6.1.tar.gz
Requires:       qsee-supplicant >= 0.1.1
Requires:       fprintd-oem >= 1.94.5-2
Requires:       polkit
Requires:       systemd
Requires:       python3
Requires:       pam
BuildRequires:  gcc
BuildRequires:  glibc-static
BuildRequires:  pam-devel
BuildRequires:  openssl-devel
BuildRequires:  systemd-rpm-macros

%description
Fedora packaging of the liuqin FPC1264 fingerprint userspace from
yzddmr6/xiaomipad-6pro-mainline device/fingerprint/oem: accept/verify helpers,
native Gatekeeper credential provider, PAM service, polkit rules and policy,
systemd units and the qsee-gatekeeper client.

The locked open-source TOD base and FPC1264 adapter are built as separate
libfprint-tod and liuqin-fpc1264-tod RPMs; they coexist with Fedora's libfprint.
Offline packaging and fake-device enumeration are verified, not enrollment or
unlock on a tablet. The FPC1264 TA firmware must come from the owner's modem_a
partition and is never packaged. Activation remains kernel-candidate bound;
enrollment and unlock are pending-device (see docs/maintenance/mobile-stack-packages.md).

%prep
%autosetup -n %{name}-%{version}
tar -xzf %{SOURCE1}

%build
# QCBOR 1.6.1 objects for the static gatekeeper client
gcc -O2 -g0 -fPIC -I qcbor-1.6.1/inc -c qcbor-1.6.1/src/UsefulBuf.c -o qcbor-use.o
for f in qcbor_encode qcbor_decode ieee754 qcbor_err_to_str; do
  gcc -O2 -g0 -fPIC -I qcbor-1.6.1/inc -c qcbor-1.6.1/src/$f.c -o qcbor-$f.o
done
gcc -O2 -g0 -std=c11 -D_GNU_SOURCE -Wall -Wextra \
    -I qcbor-1.6.1/inc -static -o qsee-gatekeeper \
    src/oem/qsee_gatekeeper.c qcbor-*.o -lm
gcc -O2 -g0 -std=c11 -D_GNU_SOURCE -Wall -Wextra \
    -static -o fpc_build_info src/oem/fpc_build_info.c
gcc -O2 -g0 -std=c11 -D_GNU_SOURCE -Wall -Wextra \
    -o pam-input src/oem/pam-input.c -lpam -lcrypto

%install
mkdir -p %{buildroot}
cp -a payload/. %{buildroot}/
install -d %{buildroot}%{_libexecdir}/liuqin-fingerprint
install -m0755 qsee-gatekeeper fpc_build_info %{buildroot}%{_libexecdir}/liuqin-fingerprint/
install -m0755 pam-input %{buildroot}%{_libexecdir}/liuqin-fingerprint/
install -Dpm0644 qcbor-1.6.1/LICENSE %{buildroot}%{_licensedir}/%{name}/QCBOR-LICENSE
install -Dpm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LIUQIN-MIT

%files
%license %{_licensedir}/%{name}/QCBOR-LICENSE
%license %{_licensedir}/%{name}/LIUQIN-MIT
%{_libexecdir}/liuqin-fingerprint
%{_sbindir}/liuqin-fingerprint-configure
%{_sbindir}/liuqin-fingerprint-lockscreen
%{_unitdir}/liuqin-fpc-stable-module.service
%{_unitdir}/liuqin-fprintd-oem.service
%{_presetdir}/90-liuqin-fingerprint.preset
%config(noreplace) %{_sysconfdir}/pam.d/liuqin-fpc-enrol
%config(noreplace) %{_sysconfdir}/pam.d/liuqin-kde-fingerprint-auth
%{_datadir}/polkit-1/actions/org.liuqin.fingerprint.policy
%{_datadir}/polkit-1/rules.d/60-liuqin-fingerprint-enroll.rules
/usr/lib/modprobe.d/liuqin-fpc-late-load.conf
%{_datadir}/doc/liuqin-fingerprint

%post
%systemd_post liuqin-fpc-stable-module.service liuqin-fprintd-oem.service

%preun
if [ "$1" -eq 0 ] && [ -x %{_sbindir}/liuqin-fingerprint-lockscreen ]; then
    %{_sbindir}/liuqin-fingerprint-lockscreen --revert >/dev/null 2>&1 || :
fi
%systemd_preun liuqin-fpc-stable-module.service liuqin-fprintd-oem.service

%postun
%systemd_postun liuqin-fpc-stable-module.service liuqin-fprintd-oem.service

%changelog
* Wed Oct 28 2026 liuqin project <liuqin@localhost> - 1.0-7.liuqin
- Follow display-manager instead of pulling in Plasma Login Manager
- Match stable_module readiness to the selected display manager (TN0083)

* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.0-6.liuqin
- Add KDE lock screen fingerprint PAM stack without the pam_fprintd timeout
- Require fprintd-oem with the post-resume verify authorization recheck

* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.0-5.liuqin
- Check confirmed finger lift after each successful sensor-state command

* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.0-4.liuqin
- Use native enrollment exclusively; remove obsolete development launchers

* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.0-3.liuqin
- Connect Fedora desktop activation, guarded kernel binding and local TA cache
- Correct RPMB provider path and remove GNOME/sensor startup dependencies

* Wed Oct 21 2026 liuqin project <liuqin@localhost> - 1.0-2.liuqin
- Correct TOD source-reuse status; enrollment and unlock remain pending-device

* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 1.0-1.liuqin
- Fedora packaging of liuqin FPC1264 fingerprint userspace (libfprint-tod pending)
