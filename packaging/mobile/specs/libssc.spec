%global commit 0cf77b93b55752da34dca2dcecc06fca8665184b
%global shortcommit %(c=%{commit}; echo ${c:0:7})

Name:           libssc
Version:        0.4.4
Release:        2.git%{shortcommit}%{?dist}
Summary:        Library to expose Qualcomm Sensor Core sensors
License:        GPL-3.0-or-later
URL:            https://codeberg.org/DylanVanAssche/libssc
Source0:        %{name}-%{version}.tar.gz
Patch0001:      0001-propagate-test-process-exit-status.patch
Patch0002:      0002-libssc-select-the-delivery-and-batching-of-streams-at-run-time.patch
Patch0003:      0003-libssc-choose-the-stream-delivery-by-sensor-type.patch
BuildRequires:  meson >= 1.4.0
BuildRequires:  gcc
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gio-unix-2.0)
BuildRequires:  pkgconfig(qmi-glib)
BuildRequires:  pkgconfig(libprotobuf-c)
BuildRequires:  python3-devel
BuildRequires:  python3-gobject-base
BuildRequires:  python3-protobuf

%description
libssc is a library to expose the sensors managed by the Qualcomm Sensor
Core found in many Qualcomm SoCs (SSC). It talks QMI over QRTR.

# Runtime shared libraries are all provided by Fedora official packages
# (rootfs package set must include them; image assembly resolves from Fedora 45).
Requires:       glib2
Requires:       libqmi
Requires:       libqrtr-glib
Requires:       protobuf-c

%package devel
Summary:        Development files for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description devel
Development files for %{name}.

%prep
%autosetup -p1 -n %{name}-%{version}

%build
%meson
%meson_build

%check
%meson_test

%install
%meson_install
install -Dpm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE
# Runtime package only: drop installed-test/mocking python payloads.
rm -rf %{buildroot}%{_libexecdir}/installed-tests
rm -rf %{buildroot}%{python3_sitelib}/ssc_server

%files
%license %{_licensedir}/%{name}/LICENSE
%{_libdir}/libssc.so.2*
%{_bindir}/ssccli

%files devel
%{_includedir}/libssc
%{_libdir}/libssc.so
%{_libdir}/pkgconfig/libssc.pc

%changelog
* Wed Nov 11 2026 liuqin project <liuqin@localhost> - 0.4.4-2.git0cf77b9
- Import per-sensor delivery policy, stream options and test exit propagation

* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 0.4.4-1.git0cf77b9
- initial Fedora RPM for liuqin sensor stack (source codeberg.com/DylanVanAssche/libssc)
