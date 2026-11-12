%global commit 598b591ae9da6a6cfe2ca5ea78998019ca6395ea
%global shortcommit %(c=%{commit}; echo ${c:0:7})

Name:           hexagonrpc
Version:        0.5.0
Release:        3.git%{shortcommit}%{?dist}
Summary:        FastRPC ioctl wrapper and a reverse tunnel
License:        GPL-3.0-or-later
URL:            https://github.com/linux-msm/hexagonrpc
Source0:        %{name}-%{version}.tar.gz
Patch0001:      0001-hexagonrpcd-expose-the-SSC-registry-version-sibling.patch
Patch0002:      0002-hexagonrpcd-add-a-narrow-sns_registry-property-shim.patch
Patch0003:      0007-hexagonrpcd-add-narrow-write-stub.patch
Patch0004:      0008-hexagonrpcd-restore-rom-property-allowlist.patch
Patch0010:      0001-fix-type-sequence-marshalling.patch
Patch0011:      0002-avoid-unaligned-metadata-store-and-null-test-comparison.patch
Patch0012:      0005-upstream-fetch-large-listener-inputs.patch
Patch0013:      0006-test-and-validate-large-listener-inputs.patch
Patch0014:      0007-liuqin-registry-error-reply-test.patch
BuildRequires:  meson >= 1.1
BuildRequires:  gcc
BuildRequires:  json-c-devel
BuildRequires:  systemd-rpm-macros

%description
HexagonRPC is a FastRPC ioctl wrapper and reverse tunnel used to talk to the
Qualcomm Context Hub Runtime Environment (CHRE) and to serve files to remote
processors such as the SLPI sensor DSP. On liuqin it provides
/usr/bin/hexagonrpcd, which the sensor stack starts against /dev/fastrpc-sdsp.

The liuqin patches add the SSC registry version sibling, a narrow
sns_registry property shim, and a narrow write-only stub for the registry
temp file the SLPI firmware requests during initialization.

%prep
%autosetup -N -n %{name}-%{version}
%patch -P 1 -p1
%patch -P 2 -p1
%patch -P 3 -p1
%patch -P 4 -p1
%patch -P 10 -p1
%patch -P 11 -p1
%patch -P 12 -p1
%patch -P 13 -p1
%patch -P 14 -p1

%build
%meson -Dhexagonrpcd_verbose=false
%meson_build

%check
%meson_test

%install
%meson_install
# Upstream installs service templates under %{_libdir}/systemd/system; Fedora
# only reads %{_unitdir}. Relocate the generated units.
if [ -d %{buildroot}%{_libdir}/systemd/system ]; then
  mkdir -p %{buildroot}%{_unitdir}
  mv %{buildroot}%{_libdir}/systemd/system/*.service %{buildroot}%{_unitdir}/
  rmdir %{buildroot}%{_libdir}/systemd/system %{buildroot}%{_libdir}/systemd
fi
install -Dpm0644 COPYING %{buildroot}%{_licensedir}/%{name}/COPYING

%files
%license %{_licensedir}/%{name}/COPYING
%{_bindir}/hexagonrpcd
%{_libexecdir}/hexagonrpc/chrecd
%{_libdir}/libhexagonrpc.so*
%{_unitdir}/hexagonrpcd-*.service
%{_mandir}/man1/hexagonrpcd.1*

%changelog
* Wed Nov 11 2026 liuqin project <liuqin@localhost> - 0.5.0-3.git598b591
- Import v0.6.1 RPC safety and listener continuation; retain narrow write stub

* Sat Nov 07 2026 liuqin project <liuqin@localhost> - 0.5.0-2.git598b591
- add narrow write-only stub for SLPI registry temp files; no host file is written

* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 0.5.0-1.git598b591
- initial Fedora RPM for liuqin sensor stack; liuqin registry-version + sns_registry patches
