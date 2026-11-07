%global debug_package %{nil}
%global __os_install_post %{nil}

# The 197-file vendor firmware closure from the Xiaomi Pad 6 Pro retail ROM
# OS2.0.6.0.VMYCNXM.  This is a LOCAL PRIVATE package: the binaries belong to
# Qualcomm/Xiaomi/Cirrus Logic and their licensors and must never be published
# in a repository or shipped inside a public image.  See NOTICE.
#
# Ownership policy:
#  * regulatory.db / regulatory.db.p7s are omitted (Fedora wireless-regdb owns
#    those paths and the kernel consumes that copy);
#  * qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin is omitted (liuqin-audio owns it);
#  * ath11k/WCN6855/** is relocated to /usr/lib/firmware/updates/ath11k/**
#    because the same main-tree paths exist in Fedora linux-firmware with
#    different bytes; the firmware loader prefers updates/ and nothing in
#    linux-firmware is overwritten.
# Result: 194 regular files + 4 symlinks packaged out of the upstream 197+4.

Name:           liuqin-firmware
Version:        0.6.0
Release:        1%{?dist}
Summary:        Xiaomi Pad 6 Pro (liuqin) board firmware closure (local private build)
License:        Proprietary
URL:            https://github.com/yzddmr6/xiaomipad-6pro-mainline
Source0:        firmware-tree.tar
Source1:        firmware.manifest
Source2:        source-sha256-firmware.txt
Source3:        NOTICE
Source4:        LICENSE
Source5:        firmware-README.md
# BuildArch is deliberately omitted: rpmbuild --target aarch64 sets the
# package arch and an explicit BuildArch is rejected by a foreign build host.
AutoReqProv:    no
# regulatory.db/.p7s intentionally come from Fedora instead of this package.
Requires:       wireless-regdb

%description
Board firmware closure for the Xiaomi Pad 6 Pro (liuqin, Qualcomm SM8475)
mainline Linux port: ADSP/CDSP/SLPI images, QCA6490 WLAN (ath11k WCN6855) and
Bluetooth, Novatek NT36532 touch firmware (CSOT and TM panels), Adreno 730
GPU files, VPU, the AudioReach topology and the wireless regulatory database
bootstrap set as pinned by the upstream project.

This package is built from the retail ROM OS2.0.6.0.VMYCNXM and its content is
proprietary third-party firmware.  It is intended for local, private use on a
tablet you own.  Do not redistribute it, publish it in a package repository or
embed it in a publicly distributed image.

%prep
cd %{_sourcedir}
sha256sum -c --quiet source-sha256-firmware.txt
work=%{_builddir}/firmware
rm -rf "$work"
mkdir -p "$work"
tar -xf %{SOURCE0} -C "$work"

# Verify the staged tree against the upstream firmware.manifest (sha256 of
# every file, relative to /usr/lib/firmware) before packaging anything.
sed 's|  /usr/lib/firmware/|  usr/lib/firmware/|' %{SOURCE1} >%{_builddir}/firmware.manifest.local
(cd "$work" && sha256sum -c --quiet ../firmware.manifest.local)
[ "$(find "$work/usr/lib/firmware" -type f | wc -l)" = 197 ] ||
	{ echo 'staged firmware tree does not hold 197 files' >&2; exit 1; }
[ "$(find "$work/usr/lib/firmware" -type l | wc -l)" = 4 ] ||
	{ echo 'staged firmware tree does not hold 4 symlinks' >&2; exit 1; }

%build
# Data-only package: the tree is already verified in %prep.

%install
fwhome=%{buildroot}%{_prefix}/lib/firmware
mkdir -p "$fwhome"
cp -a %{_builddir}/firmware/usr/lib/firmware/. "$fwhome/"

# (1) regulatory database: owned by Fedora's wireless-regdb.
rm -f "$fwhome/regulatory.db" "$fwhome/regulatory.db.p7s"

# (2) AudioReach topology: owned by liuqin-audio (same path as upstream tree).
rm -f "$fwhome/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin"
rmdir "$fwhome/qcom/sm8450" 2>/dev/null || true

# (3) ath11k: relocate the main tree into the firmware-loader updates/ tree so
# Fedora linux-firmware's WCN6855 files are neither overwritten nor preferred.
if [ -d "$fwhome/ath11k" ]; then
	mkdir -p "$fwhome/updates/ath11k"
	cp -a "$fwhome/ath11k/." "$fwhome/updates/ath11k/"
	rm -rf "$fwhome/ath11k"
fi

files=$(find "$fwhome" -type f | wc -l)
links=$(find "$fwhome" -type l | wc -l)
[ "$files" = 194 ] ||
	{ echo "firmware payload is $files files, expected 194" >&2; exit 1; }
[ "$links" = 4 ] ||
	{ echo "firmware payload is $links symlinks, expected 4" >&2; exit 1; }
[ ! -e "$fwhome/regulatory.db" ] && [ ! -e "$fwhome/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin" ] &&
	[ ! -d "$fwhome/ath11k" ] ||
	{ echo 'firmware conflict policy did not apply' >&2; exit 1; }

install -D -m0644 %{SOURCE4} %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -D -m0644 %{SOURCE3} %{buildroot}%{_datadir}/licenses/%{name}/NOTICE
install -D -m0644 %{SOURCE5} %{buildroot}%{_defaultdocdir}/%{name}/README.firmware.md

%files
%license %{_datadir}/licenses/%{name}/LICENSE
%license %{_datadir}/licenses/%{name}/NOTICE
%doc %{_defaultdocdir}/%{name}/README.firmware.md
%{_prefix}/lib/firmware/qca/*
%{_prefix}/lib/firmware/novatek/liuqin/*
%{_prefix}/lib/firmware/qcom/sm8475/liuqin/*
%{_prefix}/lib/firmware/updates/ath11k/WCN6855/hw2.0/*
%{_prefix}/lib/firmware/updates/ath11k/WCN6855/hw2.1/*
%{_prefix}/lib/firmware/updates/qcom/a730_sqe.fw
%{_prefix}/lib/firmware/updates/qcom/gmu_gen70000.bin
%{_prefix}/lib/firmware/updates/qcom/vpu/vpu20_4v.mbn

%changelog
* Tue Oct 20 2026 liuqin-fedora project <liuqin@localhost> - 0.6.0-1
- Initial local private packaging from xiaomipad-6pro-mainline v0.6.0.
