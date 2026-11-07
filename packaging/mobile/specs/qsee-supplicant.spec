Name:           qsee-supplicant
Version:        0.1.1
Release:        1.liuqin%{?dist}
Summary:        Userspace supplicant for Qualcomm QSEE trusted applications
License:        BSD-3-Clause-Clear
URL:            https://github.com/wrobelda/qsee-supplicant
Source0:        %{name}-%{version}.tar.gz
Patch0:         0001-qsee-supplicant-liuqin-legacy-qsee-and-rpmb.patch
BuildRequires:  gcc
BuildRequires:  glibc-static
BuildRequires:  kernel-headers

%description
QSEE (Qualcomm Secure Execution Environment) userspace daemons: a listener
supplicant, a TA app-loader and the liuqin UFS-RPMB provider. Used by the
liuqin FPC1264 fingerprint stack to talk to the trustzone fingerprint TA.

The liuqin patch adds the legacy QSEE transport, the fs read layout and the
authenticated UFS RPMB listener from yzddmr6/xiaomipad-6pro-mainline.

%prep
%autosetup -p1 -n %{name}-%{version}

%build
CFLAGS="-O2 -g0 -std=c11 -D_GNU_SOURCE -Wall -Wextra"
cc() { gcc $CFLAGS "$@"; }
common="src/path.c src/services.c src/handle_db.c src/fs.c src/gpfs.c"
cc -Iinclude -pthread -static -o qsee-supplicant \
   src/main.c src/transport_qseecom.c $common src/notify.c
cc -Iinclude -static -o qsee-app-loader \
   src/app_loader.c src/app_acquire.c src/notify.c
cc -Iinclude -pthread -static -o liuqin-rpmb-supplicant \
   src/liuqin_rpmb_main.c src/rpmb.c src/rpmb_ufs.c src/transport_qseecom.c \
   $common src/notify.c

%install
install -d %{buildroot}%{_libexecdir}/liuqin-fingerprint
install -m0755 qsee-supplicant qsee-app-loader liuqin-rpmb-supplicant \
        %{buildroot}%{_libexecdir}/liuqin-fingerprint/
install -Dpm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE
install -Dpm0644 LICENSES/BSD-3-Clause-Clear.txt \
        %{buildroot}%{_licensedir}/%{name}/BSD-3-Clause-Clear.txt

%files
%license %{_licensedir}/%{name}/LICENSE
%license %{_licensedir}/%{name}/BSD-3-Clause-Clear.txt
%{_libexecdir}/liuqin-fingerprint/qsee-supplicant
%{_libexecdir}/liuqin-fingerprint/qsee-app-loader
%{_libexecdir}/liuqin-fingerprint/liuqin-rpmb-supplicant

%changelog
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 0.1.1-1.liuqin
- liuqin-patched qsee-supplicant (legacy QSEE + UFS RPMB provider)
