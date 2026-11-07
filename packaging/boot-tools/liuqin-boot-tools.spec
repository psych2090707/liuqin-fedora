%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           liuqin-boot-tools
Version:        0.6.0
Release:        7%{?dist}
Summary:        On-device boot image rebuild assets for Xiaomi Pad 6 Pro (liuqin)
License:        MIT AND GPL-2.0-only AND Apache-2.0
URL:            https://example.invalid/liuqin-fedora-port
ExclusiveArch:  aarch64
BuildArch:      aarch64
AutoReqProv:    no

# This package installs the asset tree used by kernel-liuqin's kernel-install
# hook (/usr/lib/kernel/install.d/99-liuqin-android-boot.install) and its
# /usr/libexec/liuqin/liuqin-bootimg-refresh pipeline. It contains the static
# BusyBox, the copied project initramfs/boot.img build scripts, the Fedora
# root-contract generator, prebuilt static stage-1 helpers, AOSP mkbootimg
# scripts, and the default /etc/liuqin/bootimg.conf.
#
# Source0 is a pre-staged asset tree built by scripts/build-boot-tools-rpm.sh
# from this repository (+ pinned upstream/third-party inputs). Firmware is NOT
# redistributed: `liuqin-boot-tools stage` assembles the firmware pool on the
# device from its own firmware packages and the user's stock ROM analysis tree.

# --- inputs staged by scripts/build-boot-tools-rpm.sh ----------------------
Source0:  liuqin-boot-assets-%{version}.tar.gz
Source1:  bootimg.conf.default
Source2:  NOTICE

# Runtime requirements of the copied build scripts and refresh pipeline.
Requires:      /bin/sh
Requires:      python3
# Fedora dtc package provides /usr/bin/dtc and /usr/bin/fdtoverlay, which the
# copied build-bootimg.sh needs for the canonical stock-rom DTB path.
Requires:      dtc
Requires:      patch
Requires:      cpio
Requires:      gzip
Requires:      coreutils
Requires:      findutils
Requires:      tar
# Firmware pool / AudioReach topology are staged from the device layer packages.
Requires:      liuqin-firmware
Requires:      liuqin-audio
# Do NOT require kernel-liuqin: dependency direction is deliberately one-way
# (boot-tools -> firmware/audio; kernel-liuqin has no dependency on boot-tools).
# The kernel-install hook discovers this asset tree via /etc/liuqin/bootimg.conf
# and fails closed if it is absent. This avoids an update-order cycle:
#   kernel-liuqin %posttrans -> kernel-install hook -> boot-assets (optional)
#   boot-tools install -> no kernel-install trigger
# Recommends keeps dnf from pulling the kernel when installing boot-tools alone.
Recommends:    kernel-liuqin

%description
Self-contained on-device asset tree for rebuilding the liuqin stage-1
initramfs and Android boot image (header v2) after a kernel update, without a
development host.

Contents: pinned static BusyBox 1.36.1 (GPL-2.0-only), prebuilt static stage-1
helpers, the project's Fedora-ized build-initramfs.sh / build-bootimg.sh, the
root admission contract generator, initramfs /init, AOSP mkbootimg scripts
(Apache-2.0), the default /etc/liuqin/bootimg.conf, and the
`liuqin-boot-tools stage` command that stages the firmware pool from the
device's own liuqin-firmware/liuqin-audio packages plus the user's stock ROM
analysis tree.

The package never writes a boot partition, never calls qbootctl/fastboot and
does not contain redistributable vendor firmware.

%prep
# Source0 is a prepared asset tree. Extract it manually (the asset tarball top
# directory is named after this package, not the spec Name macro).
rm -rf %{_builddir}/%{name}-%{version}
mkdir -p %{_builddir}/%{name}-%{version}
tar -xzf %{SOURCE0} -C %{_builddir}/%{name}-%{version} --strip-components=1
cd %{_builddir}/%{name}-%{version}

%build
# Asset tree is prebuilt by scripts/build-boot-tools-rpm.sh (shell/python only;
# the static helpers were compiled with the host aarch64-linux-gnu toolchain).

%install
cd %{_builddir}/%{name}-%{version}
rm -rf %{buildroot}
install -d %{buildroot}%{_libexecdir}/liuqin/boot-assets
cp -a . %{buildroot}%{_libexecdir}/liuqin/boot-assets/
install -d %{buildroot}%{_libexecdir}/liuqin/boot-assets/firmware-pool
install -d %{buildroot}%{_libexecdir}/liuqin/boot-assets/wlan-hsp2-tuple
install -m 0644 /dev/null %{buildroot}%{_libexecdir}/liuqin/boot-assets/firmware-pool/.keep
install -m 0644 /dev/null %{buildroot}%{_libexecdir}/liuqin/boot-assets/wlan-hsp2-tuple/.keep

install -d %{buildroot}%{_sysconfdir}/liuqin
install -m 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/liuqin/bootimg.conf

install -d %{buildroot}%{_docdir}/liuqin-boot-tools
install -m 0644 %{SOURCE2} %{buildroot}%{_docdir}/liuqin-boot-tools/NOTICE
install -m 0644 %{buildroot}%{_libexecdir}/liuqin/boot-assets/LICENSE* \
	%{buildroot}%{_docdir}/liuqin-boot-tools/ 2>/dev/null || :
install -d %{buildroot}%{_licensedir}/liuqin-boot-tools
for lic in %{buildroot}%{_libexecdir}/liuqin/boot-assets/LICENSES/*; do
	[ -f "$lic" ] && install -m 0644 "$lic" %{buildroot}%{_licensedir}/liuqin-boot-tools/
done

%posttrans
# Best-effort firmware pool staging. The kernel-install hook fails closed with a
# clear message if this was not possible (e.g. firmware installed in a later
# transaction); re-run manually:
#   /usr/libexec/liuqin/boot-assets/bin/liuqin-boot-tools stage
if [ -x %{_libexecdir}/liuqin/boot-assets/bin/liuqin-boot-tools ]; then
	%{_libexecdir}/liuqin/boot-assets/bin/liuqin-boot-tools stage --quiet >/dev/null 2>&1 || :
fi
exit 0

%files
%defattr(-,root,root,-)
%config(noreplace) %{_sysconfdir}/liuqin/bootimg.conf
%{_libexecdir}/liuqin/boot-assets
%{_docdir}/liuqin-boot-tools/NOTICE
%{_licensedir}/liuqin-boot-tools

%changelog
* Thu Nov 05 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-7
- Patch the final boot DTB from splash_region to linux_splash so ABL disables
  the live display and the 7.3 kernel cold-initializes the panel
- Ship the verified A-slot cmdline (console=tty0, gnome.is_vm=0, no
  console=drm_log) for on-device kernel-update boot rebuilds

* Wed Oct 28 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-6
- Allow the canonical stock-rom boot build to use the project cmdline even when
  it differs from the raw kernel DTB /chosen bootargs (the overlay replaces it);
  add an offline check that gnome.is_vm=0 reaches the final DTB (TN0085)

* Wed Oct 28 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-5
- Ship the project DT cmdline (`upstream native-bootargs + gnome.is_vm=0`) and
  use it by default so kernel-update boot rebuilds keep GNOME auto-suspend
  working (TN0085)

* Wed Oct 28 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-4
- Support GNOME-only admission contracts after the KDE removal
- Default on-device bootimg.conf to the GNOME desktop topology

* Thu Oct 22 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-3
- Include the canonical DTB parser compatibility patch for dtc node labels
- Reject boot DTBs that discard the board's MDSS interconnect configuration

* Wed Oct 21 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-2
- Refresh boot assets and retain the actual kernel config snapshot
- Rebuild with repository-consistency verification

* Tue Oct 20 2026 Fedora liuqin port <liuqin@localhost> - 0.6.0-1
- Initial liuqin-boot-tools: on-device boot asset tree, prebuilt helpers,
  contract generator patch (kernel identity advisory), default bootimg.conf,
  firmware pool staging command.
