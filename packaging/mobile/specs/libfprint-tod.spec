# libfprint TOD fork (Ubuntu-maintained, LGPL-2.1-or-later upstream source)
# rebuilt for Fedora 45 / liuqin (Xiaomi Pad 6 Pro, FPC1264).
#
# Source provenance: liuqin upstream device/fingerprint/oem/SOURCE_LOCK.json
#   url  = https://archive.ubuntu.com/ubuntu/pool/main/libf/libfprint/libfprint_1.95.1+tod1.orig.tar.bz2
#   sha256 = b04c55ce1b1f0bcf97ca6e9e3dfbcad931ac2e8f87c29548c93d1aa69d9f6c60
#   git  = https://gitlab.freedesktop.org/3v1n0/libfprint tag v1.95.1+tod1
# Reusing another distribution's maintained *open source* here is not the same as
# installing its binary packages; the Fedora RPM is rebuilt from this locked tarball.
#
# This package deliberately does NOT replace Fedora's system libfprint. It is a
# private copy under %{_libdir}/liuqin-fingerprint/ used only by the liuqin
# private fprintd-oem daemon (see liuqin-fpc1264-tod). The Fedora fprintd package
# must keep resolving libfprint-2.so.2 to Fedora libfprint, so the private library
# must not advertise the system soname provide (dnf would otherwise pick it as an
# alternative provider and leave fprintd with an unreachable runtime library).
%global __provides_exclude_from ^%{_libdir}/liuqin-fingerprint/libfprint-tod/libfprint-2[.]so([.][0-9]+)*$

# Ubuntu's own package disables LTO for this source for a reason: the TOD
# symbol-version script (libfprint/tod/libfprint-tod.ver.in) relies on .symver
# aliases and ld.bfd rejects the LTO build with
#   "no symbol version section for versioned symbol `fpi_ssm_new_full@LIBFPRINT_TOD_1_1.92'"
# (see debian/rules: DEB_BUILD_MAINT_OPTIONS = optimize=-lto). Fedora enables
# LTO by default; turn it off for this package only.
%define _lto_cflags %{nil}

%global upstream_version 1.95.1+tod1
%global upstream_tree    libfprint-v%{upstream_version}

Name:           libfprint-tod
Version:        %{upstream_version}
Release:        1.liuqin%{?dist}
Summary:        Private libfprint TOD fork for the liuqin FPC1264 fingerprint stack
License:        LGPL-2.1-or-later
URL:            https://gitlab.freedesktop.org/3v1n0/libfprint/tree/tod
Source0:        libfprint_1.95.1+tod1.orig.tar.bz2
Source1:        README-libfprint-tod.md
BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  gcc
BuildRequires:  pkgconf-pkg-config
BuildRequires:  glib2-devel >= 2.80
BuildRequires:  libgusb-devel
BuildRequires:  libgudev-devel
BuildRequires:  systemd-devel
BuildRequires:  openssl-devel >= 3.0.8
BuildRequires:  python3

%description
The libfprint Touch-OEM-Driver (TOD) fork shipped by Ubuntu for OEM fingerprint
sensors, built from the source version locked by the liuqin upstream tree
(1.95.1+tod1, LGPL-2.1-or-later).

Fedora 45 has no TOD-enabled libfprint: the Fedora package is stock upstream
libfprint (1.94.100) which only exposes in-tree drivers and therefore cannot load
the liuqin FPC1264 TOD adapter. This package provides a private, isolated copy of
the TOD fork plus its private TOD library (libfprint-2-tod.so.1). It is installed
under %{_libdir}/liuqin-fingerprint/libfprint-tod and is NOT registered with the
system dynamic linker; only the liuqin private fprintd-oem daemon loads it
through a unit drop-in and FP_TOD_DRIVERS_DIR.

This is an offline buildability/coexistence deliverable, not a claim that the
fingerprint reader works: device-side enrollment/unlock remains pending-device.

%package devel
Summary:        Development headers/pkg-config for the private libfprint TOD fork
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description devel
Headers and pkg-config metadata for building out-of-tree TOD drivers against the
private libfprint TOD fork. The files are installed under
%{_includedir}/liuqin-fingerprint and %{_libdir}/liuqin-fingerprint/pkgconfig so
they never shadow Fedora's libfprint(-devel).

%prep
%autosetup -n %{upstream_tree}

%build
# The TOD library is what we need; the in-tree driver set is kept identical to
# Ubuntu's distro build (-Ddrivers=all) for provenance parity. Fedora 45
# compiles this source with GCC 16 and meson 1.11.
#
# Note: -Ddrivers= (empty) is *not* usable: upstream meson fails with
# "Key  is not in the dictionary" (libfprint/meson.build:189), even though the
# error message at meson.build:241 suggests a TOD-only build. Use drivers=all.
%meson \
    -Dtod=true \
    -Ddrivers=all \
    -Dintrospection=false \
    -Ddoc=false \
    -Dgtk-examples=false \
    -Dinstalled-tests=false \
    -Dudev_rules=disabled \
    -Dudev_hwdb=disabled
%meson_build

%install
%meson_install

private_libdir=%{buildroot}%{_libdir}/liuqin-fingerprint/libfprint-tod
private_pcdir=%{buildroot}%{_libdir}/liuqin-fingerprint/pkgconfig
private_incdir=%{buildroot}%{_includedir}/liuqin-fingerprint
install -d "$private_libdir" "$private_pcdir" "$private_incdir"

mv %{buildroot}%{_libdir}/libfprint-2.so*     "$private_libdir"/
mv %{buildroot}%{_libdir}/libfprint-2-tod.so* "$private_libdir"/
mv %{buildroot}%{_includedir}/libfprint-2     "$private_incdir"/
rm -f %{buildroot}%{_libdir}/pkgconfig/libfprint-2.pc \
      %{buildroot}%{_libdir}/pkgconfig/libfprint-2-tod-1.pc

# Private pkg-config metadata: paths point at the private install location.
cat >"$private_pcdir/libfprint-2.pc" <<'PCEOF'
prefix=/usr
exec_prefix=${prefix}
libdir=%{_libdir}/liuqin-fingerprint/libfprint-tod
includedir=%{_includedir}/liuqin-fingerprint

Name: libfprint-2
Description: Private libfprint-2 (TOD fork) for the liuqin fingerprint stack
Version: %{upstream_version}
Requires: gio-unix-2.0 >= 2.80, gobject-2.0 >= 2.80
Libs: -L${libdir} -lfprint-2
Cflags: -I${includedir}/libfprint-2
PCEOF

cat >"$private_pcdir/libfprint-2-tod-1.pc" <<'PCEOF'
prefix=/usr
exec_prefix=${prefix}
libdir=%{_libdir}/liuqin-fingerprint/libfprint-tod
includedir=%{_includedir}/liuqin-fingerprint

Name: libfprint-2-tod-1
Description: Private libfprint Touch Drivers API (liuqin TOD fork)
Version: %{upstream_version}
Requires: libfprint-2, gio-2.0, gusb >= 0.2.0
Libs: -L${libdir} -lfprint-2-tod -lfprint-2
Cflags: -I${includedir}/libfprint-2/tod-1 -I${includedir}/libfprint-2
PCEOF

# The metainfo file would collide with Fedora libfprint's copy; keep it as
# provenance documentation instead of installing it to /usr/share/metainfo.
install -d %{buildroot}%{_docdir}/%{name}
if [ -f %{buildroot}%{_datadir}/metainfo/org.freedesktop.libfprint.metainfo.xml ]; then
    mv %{buildroot}%{_datadir}/metainfo/org.freedesktop.libfprint.metainfo.xml \
       %{buildroot}%{_docdir}/%{name}/
    rmdir %{buildroot}%{_datadir}/metainfo 2>/dev/null || true
fi
install -m0644 %{SOURCE1} %{buildroot}%{_docdir}/%{name}/README-libfprint-tod.md

# Sanity: nothing of this package may land on the system linker/header paths.
for stray in %{buildroot}%{_libdir}/libfprint-2* \
             %{buildroot}%{_libdir}/pkgconfig/libfprint-2* \
             %{buildroot}%{_includedir}/libfprint-2 \
             %{buildroot}%{_datadir}/metainfo/org.freedesktop.libfprint.metainfo.xml \
             %{buildroot}%{_libdir}/girepository-1.0/FPrint-2.0.typelib \
             %{buildroot}%{_udevrulesdir}/70-libfprint-2.rules; do
    if [ -e "$stray" ]; then
        echo "ERROR: libfprint-tod would install a system-path file: $stray" >&2
        exit 1
    fi
done

%files
%license COPYING
%doc NEWS.tod.md README.tod.md
%{_libdir}/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2*
%{_libdir}/liuqin-fingerprint/libfprint-tod/libfprint-2-tod.so.1*
%{_docdir}/%{name}/README-libfprint-tod.md
%{_docdir}/%{name}/org.freedesktop.libfprint.metainfo.xml

%files devel
%{_libdir}/liuqin-fingerprint/libfprint-tod/libfprint-2.so
%{_libdir}/liuqin-fingerprint/libfprint-tod/libfprint-2-tod.so
%{_includedir}/liuqin-fingerprint/libfprint-2
%{_libdir}/liuqin-fingerprint/pkgconfig/libfprint-2.pc
%{_libdir}/liuqin-fingerprint/pkgconfig/libfprint-2-tod-1.pc

%changelog
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 1.95.1+tod1-1.liuqin
- Rebuild Ubuntu-maintained libfprint TOD fork (source locked by liuqin upstream
  SOURCE_LOCK.json, sha256 b04c55ce...) as an isolated Fedora 45 aarch64 package.
- Private install path only; does not replace Fedora libfprint.
