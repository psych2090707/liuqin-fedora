%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

# Kernel release string. Must match the kernel produced by scripts/build-kernel.sh
# (fixed, upstream-compatible: 6.17.0-rc1-gfe81794b5e1b). Overridden by
# scripts/build-kernel-rpm.sh via --define "kver <release>".
%{!?kver:%global kver 6.17.0-rc1-gfe81794b5e1b}
%global kernelrelease %{kver}

# RPM version/release are independent from the kernel release string:
#  - Version/Release identify the RPM package (dnf upgrade ordering);
#  - kernelrelease stays fixed so /lib/modules/<kver> and the initramfs
#    kernel.release gate remain stable and comparable with upstream.
#    A config/ABI change that must be distinguishable gets a new .liuqinN bump.
%{!?pkgrel:%global pkgrel liuqin1}

Name:           kernel-liuqin
Epoch:          0
# The default preserves the 6.17 packaging.  The 7.3.1 experiment passes
# --define "rpm_version 7.3.1" --define "rpm_release 0.liuqin1".
Version:        %{!?rpm_version:6.17.0}%{?rpm_version}
Release:        %{!?rpm_release:0.rc1.gfe81794b5e1b.%{pkgrel}}%{?rpm_release}%{?dist}
Summary:        Linux kernel for Xiaomi Pad 6 Pro (liuqin, SM8475)
License:        GPL-2.0-only
URL:            https://github.com/yzddmr6/linux-sm8450-liuqin
ExclusiveArch:  aarch64
BuildArch:      aarch64
AutoReqProv:    no

# Payload is already cross-built and stripped by scripts/build-kernel.sh.
# rpmbuild must not run host (x86_64) strip/build-id/elfdeps over aarch64 .ko;
# that is why __os_install_post is disabled above and all Requires/Provides
# below are explicit.

# --- inputs staged by scripts/build-kernel-rpm.sh ---------------------------
Source0:  Image
Source1:  sm8475-xiaomi-liuqin.dtb
Source2:  modules.tar.gz
Source3:  config
Source4:  Module.symvers
Source5:  kernel.release
Source6:  kernel-modules.manifest
Source7:  kernel-build-info.json
Source8:  99-liuqin-android-boot.install
Source9:  liuqin-apply-boot
Source10: bootimg-builder
Source11: bootimg.conf.example
Source12: mkbootimg.py
Source13: unpack_bootimg.py
Source14: native-bootargs.txt
Source15: README.kernel-liuqin
Source16: liuqin-bootimg-refresh
# TN0032: single implementation of the boot metadata schema (v2) shared by
# liuqin-bootimg-refresh / the kernel-install hook / liuqin-apply-boot, and the
# kernel pair archive used to keep rollbacks boot+modules consistent.
Source17: liuqin_boot_metadata.py
Source18: liuqin-kernel-pair

BuildRequires: kmod
# kernel-install hook + liuqin-apply-boot are Python 3 (stdlib only).
Requires:      python3

# Deliberately do NOT "Provides: kernel": holding the generic kernel name would
# make dnf treat this device kernel as Fedora's generic kernel (installonly/BLS
# assumptions) and mix it with the official kernel dependency graph.
#
# LIMITATION: `Provides: kernel-uname-r = 6.17.0-rc1-gfe81794b5e1b` is not
# expressible -- RPM's EVR grammar rejects the upstream kernelrelease string
# (double '-' separator). Out-of-tree modules for this device must therefore
# depend on kernel-liuqin-<version>-<release> (or on
# kernel-liuqin-modules) instead of the generic kernel-uname-r capability.
# See docs/maintenance/kernel-rpm.md §2.1.
Provides:      kernel-liuqin-modules = %{version}-%{release}
Conflicts:     kernel
Conflicts:     kernel-core
Conflicts:     kernel-modules
Conflicts:     kernel-modules-core

%description
Cross-built Linux mainline kernel for the Xiaomi Pad 6 Pro
(liuqin, Qualcomm SM8475).  The current experiment packages Linux 7.3.1;
the retained 6.17 recipe is still accepted by the same spec.  Built by
scripts/build-kernel.sh with the Fedora config fragment (SELinux enabled).

This device has no UEFI/ESP/GRUB and boots an Android boot image (header v2)
loaded by Qualcomm ABL. The kernel therefore does NOT rely on dracut or BLS;
boot.img assembly is driven by /usr/lib/kernel/install.d/99-liuqin-android-boot.install,
which stages images under /boot/liuqin/ and never writes a boot partition.

%prep
# No upstream tarball: the cross-built artifacts are the sources.

%build
# Cross build happened in scripts/build-kernel.sh; nothing to compile here.

%install
rm -rf %{buildroot}
install -d %{buildroot}

# Modules tree first (deterministic tar from scripts/build-kernel.sh). The tar
# is in kernel modules_install layout: lib/modules/<kver>/...  Fedora is
# usr-merged, so move it under /usr/lib/modules BEFORE installing the other
# files (doing it the other way around leaves the modules in /lib and the
# package checks look at /usr/lib).
tar -xzf %{SOURCE2} -C %{buildroot}
test -d %{buildroot}/lib/modules/%{kver} || {
	echo "kernel-liuqin: modules.tar.gz does not contain lib/modules/%{kver}" >&2
	exit 1
}
test -f %{buildroot}/lib/modules/%{kver}/modules.order || {
	echo "kernel-liuqin: modules.tar.gz lacks modules.order" >&2
	exit 1
}
install -d %{buildroot}/usr/lib/modules
mv %{buildroot}/lib/modules/%{kver} %{buildroot}/usr/lib/modules/
rmdir %{buildroot}/lib/modules %{buildroot}/lib 2>/dev/null || :
test -d %{buildroot}/usr/lib/modules/%{kver}

install -d %{buildroot}/usr/lib/modules/%{kver}/device-tree/qcom
install -d %{buildroot}/usr/share/liuqin/tools
install -d %{buildroot}/usr/share/liuqin/mkbootimg
install -d %{buildroot}/usr/lib/kernel/install.d
install -d %{buildroot}/usr/libexec/liuqin
install -d %{buildroot}/usr/lib/liuqin
install -d %{buildroot}/usr/sbin

install -m 0755 %{SOURCE0} %{buildroot}/usr/lib/modules/%{kver}/vmlinuz
install -m 0644 %{SOURCE1} %{buildroot}/usr/lib/modules/%{kver}/device-tree/qcom/sm8475-xiaomi-liuqin.dtb
# Canonical DTB alias used by the kernel-install hook / boot.img builder.
ln -s device-tree/qcom/sm8475-xiaomi-liuqin.dtb %{buildroot}/usr/lib/modules/%{kver}/dtb

# modules.dep & friends are generated offline at build time (device has no
# network; package content must be self-contained). depmod only searches
# <root>/lib/modules, so borrow Fedora's usr-merge layout temporarily and remove
# the helper symlink again so it is not packaged.
if command -v depmod >/dev/null 2>&1; then
	ln -sfn usr/lib %{buildroot}/lib
	depmod -b %{buildroot} %{kver}
	rm -f %{buildroot}/lib
else
	echo "kernel-liuqin: depmod not available; modules.dep missing" >&2
	exit 1
fi

install -m 0644 %{SOURCE5} %{buildroot}/usr/share/liuqin/kernel.release
install -m 0644 %{SOURCE6} %{buildroot}/usr/share/liuqin/kernel-modules.manifest
install -m 0644 %{SOURCE7} %{buildroot}/usr/share/liuqin/kernel-build-info.json
install -m 0644 %{SOURCE3} %{buildroot}/usr/share/liuqin/kernel-config
install -m 0644 %{SOURCE4} %{buildroot}/usr/share/liuqin/Module.symvers

install -m 0755 %{SOURCE8} %{buildroot}/usr/lib/kernel/install.d/99-liuqin-android-boot.install
install -m 0755 %{SOURCE9} %{buildroot}/usr/sbin/liuqin-apply-boot
install -m 0755 %{SOURCE10} %{buildroot}/usr/libexec/liuqin/bootimg-builder
install -m 0755 %{SOURCE16} %{buildroot}/usr/libexec/liuqin/liuqin-bootimg-refresh
install -m 0644 %{SOURCE17} %{buildroot}/usr/lib/liuqin/liuqin_boot_metadata.py
install -m 0755 %{SOURCE18} %{buildroot}/usr/sbin/liuqin-kernel-pair
install -m 0644 %{SOURCE11} %{buildroot}/usr/share/liuqin/bootimg.conf.example
install -m 0644 %{SOURCE12} %{buildroot}/usr/share/liuqin/mkbootimg/mkbootimg.py
install -m 0644 %{SOURCE13} %{buildroot}/usr/share/liuqin/mkbootimg/unpack_bootimg.py
install -m 0644 %{SOURCE14} %{buildroot}/usr/share/liuqin/tools/native-bootargs.txt
install -m 0644 %{SOURCE15} %{buildroot}/usr/share/liuqin/README.kernel-liuqin

%pre
# TN0032: preserve the currently installed kernel pair (Image + modules tree +
# identity files) BEFORE rpm replaces the files.  It matters because the
# kernelrelease is intentionally fixed: an upgrade overwrites the SAME
# /usr/lib/modules/<kver> path, so without this archive a boot.img rollback
# would run the old Image against the new modules.  liuqin-kernel-pair records
# pair_id = sha256(Image) and verifies every archived file; liuqin-apply-boot
# finds the pair from the boot.img backup and restores both.
#
# Fail closed: if an installed kernel pair exists and cannot be archived, refuse
# the upgrade instead of silently losing the ability to roll back.  The archive
# requires free space under /var/lib/liuqin/kernel-pairs (roughly the size of
# one modules tree + vmlinuz, retained for LIUQIN_KERNEL_PAIR_RETAIN pairs).
# Escape hatch for operators who accept a non-rollbackable update:
#   LIUQIN_KERNEL_PAIR_ARCHIVE=0 dnf upgrade kernel-liuqin
# Real-system gate (Lead review TN0032): scriptlets also run when an image is
# assembled into a staging rootfs (mkosi / dnf --installroot / rpm --root).
# /run/systemd/system only exists on a system actually booted by systemd, so an
# offline image build can never be disturbed by this archive step.  Build or
# rescue environments that really want it must set the explicit force switch.
lq_archive=1
[ "${LIUQIN_KERNEL_PAIR_ARCHIVE:-1}" = "0" ] && lq_archive=0
if [ ! -d /run/systemd/system ] && [ "${LIUQIN_KERNEL_PAIR_ARCHIVE_FORCE:-0}" != "1" ]; then
	lq_archive=0
fi
if [ "$1" -ge 2 ] && [ "$lq_archive" = "1" ] && \
	[ -x /usr/sbin/liuqin-kernel-pair ]; then
	if ! /usr/sbin/liuqin-kernel-pair archive --reason rpm-upgrade; then
		echo "kernel-liuqin: %pre could not archive the installed kernel pair." >&2
		echo "kernel-liuqin: refusing the upgrade so a boot+modules rollback stays possible." >&2
		echo "kernel-liuqin: free space under /var/lib/liuqin/kernel-pairs and retry, or set" >&2
		echo "kernel-liuqin: LIUQIN_KERNEL_PAIR_ARCHIVE=0 to accept a non-rollbackable update." >&2
		exit 1
	fi
fi
exit 0

%post
# Refresh module dependencies after installation (best effort: image assembly
# may not have kmod available yet).
if [ -x /usr/sbin/depmod ]; then
	/usr/sbin/depmod -a %{kver} >/dev/null 2>&1 || :
fi
# Do NOT run dracut/grub2-mkconfig/kernel-install here: this device has no
# ESP/GRUB and boot.img staging is gated on /etc/liuqin/bootimg.conf (opt-in).
exit 0

%posttrans
# Opt-in only: /etc/liuqin/bootimg.conf is created by the device layer after the
# stock ROM analysis tree and the boot.img builder are in place. During image
# build the file is absent, so no boot.img is generated and dnf stays quiet.
if [ -x /usr/bin/kernel-install ] && [ -f /etc/liuqin/bootimg.conf ]; then
	if ! /usr/bin/kernel-install add %{kver} /usr/lib/modules/%{kver}/vmlinuz >/dev/null 2>&1; then
		echo "kernel-liuqin: kernel-install add %{kver} failed; boot.img not regenerated." >&2
		echo "kernel-liuqin: see /var/log/liuqin-bootimg/ (old staged image kept)." >&2
	fi
fi
exit 0

%postun
# Same opt-in gate as %posttrans; never touches the boot partition.
# $1 is the number of kernel-liuqin packages left after this step: 0 means a
# real erase, >=1 means an upgrade.  The kernelrelease is fixed across
# upgrades, so on an upgrade `kernel-install remove` would delete the staged
# boot-<kver>.img that the new package's %posttrans just produced; only run it
# when the package is actually being removed.
if [ "$1" -eq 0 ] && [ -x /usr/bin/kernel-install ] && [ -f /etc/liuqin/bootimg.conf ]; then
	/usr/bin/kernel-install remove %{kver} >/dev/null 2>&1 || :
fi
exit 0

%files
%defattr(-,root,root,-)
%dir /usr/lib/modules/%{kver}
%dir /usr/lib/modules/%{kver}/device-tree
%dir /usr/lib/modules/%{kver}/device-tree/qcom
/usr/lib/modules/%{kver}/vmlinuz
/usr/lib/modules/%{kver}/dtb
/usr/lib/modules/%{kver}/device-tree/qcom/sm8475-xiaomi-liuqin.dtb
/usr/lib/modules/%{kver}/kernel
/usr/lib/modules/%{kver}/extra
/usr/lib/modules/%{kver}/modules.*
/usr/share/liuqin/kernel.release
/usr/share/liuqin/kernel-modules.manifest
/usr/share/liuqin/kernel-build-info.json
/usr/share/liuqin/kernel-config
/usr/share/liuqin/Module.symvers
/usr/share/liuqin/bootimg.conf.example
/usr/share/liuqin/README.kernel-liuqin
/usr/share/liuqin/tools/native-bootargs.txt
/usr/share/liuqin/mkbootimg/mkbootimg.py
/usr/share/liuqin/mkbootimg/unpack_bootimg.py
/usr/lib/kernel/install.d/99-liuqin-android-boot.install
/usr/libexec/liuqin/bootimg-builder
/usr/libexec/liuqin/liuqin-bootimg-refresh
/usr/lib/liuqin/liuqin_boot_metadata.py
/usr/sbin/liuqin-kernel-pair
/usr/sbin/liuqin-apply-boot

%changelog
* Tue Oct 20 2026 Fedora liuqin port <liuqin@localhost> - 6.17.0-0.rc1.gfe81794b5e1b.liuqin1
- Initial kernel-liuqin package: cross-built Image, liuqin DTB, 481 modules,
  kernel-install boot.img staging hook (no partition writes), apply-boot dry-run tool.
