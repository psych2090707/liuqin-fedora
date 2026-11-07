Name:           fprintd-oem
Version:        1.94.5
Release:        4.liuqin%{?dist}
Summary:        Private fprintd daemon with liuqin FPC1264 adaptive-template commit
License:        LGPL-2.1-or-later
URL:            https://gitlab.freedesktop.org/libfprint/fprintd
Source0:        fprintd-oem-1.94.5.tar.gz
Source1:        oem-update.inc
Source2:        prepare.py
Source3:        FPRINTD_SOURCE_HASHES.json
Source4:        fprintd-oem-update.patch
Source5:        0005-fprintd-recheck-verify-after-transient-logind-inactivity.patch
Source6:        0006-fprintd-defer-claim-while-device-is-suspended.patch
BuildRequires:  meson
BuildRequires:  gcc
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(dbus-1)
BuildRequires:  pkgconfig(polkit-gobject-1)
BuildRequires:  pkgconfig(libfprint-2)
BuildRequires:  systemd-devel
Requires:       libfprint%{?_isa} >= 1.94

%description
A private build of fprintd 1.94.5 with the liuqin OEM adaptive-template patch.
The patched match callback persists an updated opaque fingerprint database from
the FPC1264 TOD driver atomically before authorising a verify result. It does
not replace the Fedora fprintd package; the binary is installed under
%{_libexecdir}/liuqin-fingerprint/ and started by a liuqin-specific unit from
liuqin-fingerprint-support.

%prep
%autosetup -n fprintd-oem-1.94.5
# RPM copies Source1..4 into %{_builddir}; after %autosetup the cwd is the
# unpacked vendor tree, so reference the helpers via ../
python3 - <<'PYHASH'
import hashlib, json, pathlib
ref = json.load(open('%{SOURCE3}'))
for name, digest in ref.items():
    got = hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()
    if got != digest:
        raise SystemExit('pinned fprintd source mismatch: ' + name)
print('fprintd source hashes verified:', len(ref), 'files')
PYHASH
python3 %{SOURCE2} . %{_builddir}/fprintd-oem-source --patch-output %{_builddir}/fprintd-oem-update.generated.patch
cp %{SOURCE1} %{_builddir}/fprintd-oem-source/src/oem-update.inc
# Recheck verify authorization while logind settles after suspend (TN0064).
patch -d %{_builddir}/fprintd-oem-source -p1 --no-backup-if-mismatch < %{SOURCE5}
# Keep a Claim pending while libfprint reports the device suspended (TN0064).
patch -d %{_builddir}/fprintd-oem-source -p1 --no-backup-if-mismatch < %{SOURCE6}

%build
meson setup build %{_builddir}/fprintd-oem-source \
    --prefix=/usr --buildtype=release --wrap-mode=nodownload \
    -Dpam=false -Dman=false -Dgtk_doc=false -Dsystemd=false
meson compile -C build fprintd
install -Dm0755 build/src/fprintd %{_builddir}/fprintd-oem-bin

%install
install -d %{buildroot}%{_libexecdir}/liuqin-fingerprint
install -m0755 %{_builddir}/fprintd-oem-bin %{buildroot}%{_libexecdir}/liuqin-fingerprint/fprintd
install -Dpm0644 COPYING %{buildroot}%{_licensedir}/%{name}/COPYING
install -Dpm0644 %{_builddir}/fprintd-oem-update.generated.patch \
    %{buildroot}%{_datadir}/doc/liuqin-fingerprint/fprintd-oem-update.patch
install -Dpm0644 %{SOURCE5} \
    %{buildroot}%{_datadir}/doc/liuqin-fingerprint/fprintd-oem-transient-logind.patch
install -Dpm0644 %{SOURCE6} \
    %{buildroot}%{_datadir}/doc/liuqin-fingerprint/fprintd-oem-suspended-claim.patch

%files
%license %{_licensedir}/%{name}/COPYING
%{_libexecdir}/liuqin-fingerprint/fprintd
%{_datadir}/doc/liuqin-fingerprint/fprintd-oem-update.patch
%{_datadir}/doc/liuqin-fingerprint/fprintd-oem-transient-logind.patch
%{_datadir}/doc/liuqin-fingerprint/fprintd-oem-suspended-claim.patch

%changelog
* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.94.5-4.liuqin
- Keep Claim pending while the device is suspended instead of failing busy

* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.94.5-3.liuqin
- Bound the post-resume recheck to 1 s once logind reports the user active

* Fri Oct 23 2026 liuqin project <liuqin@localhost> - 1.94.5-2.liuqin
- Recheck verify authorization while logind settles after suspend/resume

* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 1.94.5-1.liuqin
- private fprintd with liuqin OEM adaptive-template commit
