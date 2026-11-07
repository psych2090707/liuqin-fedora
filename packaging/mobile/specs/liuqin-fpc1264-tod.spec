# FPC1264 TOD driver adapter for the liuqin fingerprint stack.
#
# Source: liuqin upstream repository (MIT project, files carry SPDX
# LGPL-2.1-or-later headers), device/fingerprint/oem/src/fingerprint/libfprint-tod/
# built exactly as the upstream tools/build-tod.sh intends:
#   pkg-config --cflags --libs libfprint-2-tod-1
# against the locked libfprint TOD source provided by libfprint-tod(-devel).
#
# Runtime layout (matching the existing liuqin-fingerprint-support payload):
#   /usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so  (TOD driver)
#   /usr/libexec/liuqin-fingerprint/fpc-oem-print                     (serializer)
# The private libfprint copy itself is provided by libfprint-tod and loaded via
# a systemd drop-in for liuqin-fprintd-oem.service only.
#
# AutoReq is disabled deliberately: the auto-generated requires for
# libfprint-2.so.2/libfprint-2-tod.so.1 must not be satisfied by Fedora's
# libfprint (the whole point is to run against the private TOD build), and the
# private libfprint-tod package does not advertise the system soname provide.
# Dependencies are declared explicitly below.
AutoReqProv: no

%global tod_version 1.95.1

Name:           liuqin-fpc1264-tod
Version:        1.0
Release:        1.liuqin%{?dist}
Summary:        FPC1264 TOD driver and serializer for the liuqin fingerprint stack
License:        LGPL-2.1-or-later
URL:            https://github.com/yzddmr6/xiaomipad-6pro-mainline
Source0:        %{name}-%{version}.tar.gz
Source1:        README-libfprint-tod.md
BuildRequires:  gcc
BuildRequires:  pkgconf-pkg-config
BuildRequires:  glib2-devel
BuildRequires:  libfprint-tod-devel >= %{tod_version}
Requires:       libfprint-tod%{?_isa} >= %{tod_version}
Requires:       fprintd-oem >= 1.94.5
Requires:       liuqin-fingerprint-support >= 1.0
Requires:       glib2%{?_isa}

%description
The liuqin FPC1264 Touch-OEM-Driver (TOD) adapter shared object plus the
fpc-oem-print serializer used by the authenticated enrolment path.

The adapter is an explicitly discovered TOD driver (entry point
fpi_tod_shared_driver_get_type, device id fpc1264_oem, virtual device gated by
FP_LIUQIN_FPC1264_OEM_ENABLE) and does no host-side biometric matching. It links
against the private libfprint TOD build from the libfprint-tod package; the
fingerprint reader itself (TA firmware, RPMB, /dev/fpc1020) remains
pending-device.

This package ships a systemd drop-in for liuqin-fprintd-oem.service that adds
LD_LIBRARY_PATH=%{_libdir}/liuqin-fingerprint/libfprint-tod so the private
daemon loads the TOD libfprint instead of Fedora's stock libfprint.

%prep
%autosetup -n %{name}-%{version}

%build
export PKG_CONFIG_PATH=%{_libdir}/liuqin-fingerprint/pkgconfig
CFLAGS_EXTRA='%{optflags} -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror'
RPATH='-Wl,-rpath,%{_libdir}/liuqin-fingerprint/libfprint-tod -Wl,--disable-new-dtags'

# Same compilation units and flags as upstream tools/build-tod.sh.
gcc -shared -fPIC $CFLAGS_EXTRA $RPATH \
    $(pkg-config --cflags libfprint-2-tod-1 gio-2.0) \
    fpc1264-oem.c \
    -o libfprint-tod-fpc1264-oem.so \
    $(pkg-config --libs libfprint-2-tod-1 gio-2.0)

gcc $CFLAGS_EXTRA $RPATH \
    $(pkg-config --cflags libfprint-2 libfprint-2-tod-1) \
    fpc-oem-print.c \
    -o fpc-oem-print \
    $(pkg-config --libs libfprint-2 libfprint-2-tod-1)

%install
install -d %{buildroot}%{_libexecdir}/liuqin-fingerprint/tod
install -m0755 libfprint-tod-fpc1264-oem.so %{buildroot}%{_libexecdir}/liuqin-fingerprint/tod/
install -m0755 fpc-oem-print              %{buildroot}%{_libexecdir}/liuqin-fingerprint/

# Only the private fprintd-oem daemon gets the TOD libfprint on its loader path;
# Fedora fprintd keeps using Fedora libfprint from the default paths.
install -d %{buildroot}%{_unitdir}/liuqin-fprintd-oem.service.d
cat >%{buildroot}%{_unitdir}/liuqin-fprintd-oem.service.d/10-libfprint-tod.conf <<'EOF'
# Added by liuqin-fpc1264-tod: load the isolated TOD libfprint build instead of
# Fedora's stock libfprint. Do not add this directory to the global loader path:
# Fedora fprintd must keep using /usr/lib64/libfprint-2.so.2.
[Service]
Environment=LD_LIBRARY_PATH=%{_libdir}/liuqin-fingerprint/libfprint-tod
EOF

install -Dpm0644 %{SOURCE1} %{buildroot}%{_docdir}/liuqin-fingerprint/TOD-PROVENANCE.md
install -Dpm0644 LICENSE-LGPL-2.1 %{buildroot}%{_licensedir}/%{name}/LICENSE-LGPL-2.1
install -Dpm0644 SOURCE_LOCK.json  %{buildroot}%{_docdir}/liuqin-fingerprint/TOD-SOURCE_LOCK.json

%files
%license %{_licensedir}/%{name}/LICENSE-LGPL-2.1
%doc README.md LICENSE-MIT
%{_libexecdir}/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so
%{_libexecdir}/liuqin-fingerprint/fpc-oem-print
%{_unitdir}/liuqin-fprintd-oem.service.d/10-libfprint-tod.conf
%{_docdir}/liuqin-fingerprint/TOD-PROVENANCE.md
%{_docdir}/liuqin-fingerprint/TOD-SOURCE_LOCK.json

%post
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
fi

%postun
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
fi

%changelog
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 1.0-1.liuqin
- Build the FPC1264 TOD adapter against the locked libfprint TOD source
  (libfprint-tod 1.95.1+tod1) for Fedora 45 aarch64.
- Add scoped LD_LIBRARY_PATH drop-in for the private fprintd-oem daemon.
