%global debug_package %{nil}
%global __os_install_post %{nil}

# AudioReach topology + ALSA UCM2 for the Xiaomi Pad 6 Pro quad CS35L41
# speaker array and the onboard WCD938x microphone.
#
# The topology is built from source with m4 + alsatplg against the pinned
# linux-msm/audioreach-topology commit 2af1f1ebb8d4fd03b5f53891467ddde2e208a8a0
# (BSD-3-Clause) using the upstream builder, which also rewrites the single
# unified Audio-IF sink to the device firmware's legacy TDM sink and verifies
# the decoded topology tokens.  The resulting binary's sha256 is pinned so a
# silently different firmware can never enter a package.
#
# The UCM2 files are project work (MIT) and stay at the distribution-neutral
# /usr/share/alsa/ucm2 path.  No hardware volume mixer is exported: PipeWire
# keeps software volume so an un-calibrated amplifier cannot be driven to full
# scale (per-device protection calibration is provisioned from persist).

Name:           liuqin-audio
Version:        0.6.0
Release:        1%{?dist}
Summary:        Xiaomi Pad 6 Pro (liuqin) AudioReach topology and ALSA UCM2 configuration
License:        BSD-3-Clause AND MIT
URL:            https://github.com/yzddmr6/xiaomipad-6pro-mainline
Source0:        audioreach-topology.tar
Source1:        liuqin-speakers.m4
Source2:        build-liuqin-audio-topology.sh
Source3:        ucm2.tar
Source4:        source-sha256-audio.txt
Source5:        NOTICE
Source6:        LICENSE
Source7:        audio-topology-README.md
# BuildArch is deliberately omitted: rpmbuild --target aarch64 sets the
# package arch and an explicit BuildArch is rejected by a foreign build host.
AutoReqProv:    no
BuildRequires:  m4
BuildRequires:  git
BuildRequires:  alsa-topology-utils
Requires:       alsa-ucm

%description
Audio support data for the Xiaomi Pad 6 Pro (liuqin, SM8475) mainline port:
the AudioReach/TDM speaker topology loaded by the ADSP and the ALSA UCM2
profile that turns the sm8450-sndcard / Xiaomi-Pad-6-Pro card into a working
PipeWire output and capture device.

The topology is compiled from the project's BSD-3-Clause m4 source at build
time and its binary sha256 is checked against the device-validated value.

%prep
cd %{_sourcedir}
sha256sum -c --quiet source-sha256-audio.txt

builddir=%{_builddir}
rm -rf "$builddir/audioreach-topology" "$builddir/proj" "$builddir/topology.bin"
mkdir -p "$builddir/proj/tools" "$builddir/proj/device/audio-topology"
tar -xf %{SOURCE0} -C "$builddir"
cp %{SOURCE2} "$builddir/proj/tools/build-liuqin-audio-topology.sh"
cp %{SOURCE1} "$builddir/proj/device/audio-topology/liuqin-speakers.m4"

%build
command -v m4 >/dev/null || { echo 'm4 is required' >&2; exit 1; }
command -v alsatplg >/dev/null || { echo 'alsatplg is required (alsa-utils)' >&2; exit 1; }
AUDIOREACH_TOPOLOGY_DIR=%{_builddir}/audioreach-topology \
	OUTPUT=%{_builddir}/topology.bin \
	sh %{_builddir}/proj/tools/build-liuqin-audio-topology.sh

# Device-validated topology identity (upstream build-liuqin-firmware-prep.sh).
expected=9c9f8bfcffde1f52c143d58cba821c5f6b3899553370ab92a88b90d81fef9ee9
got=$(sha256sum %{_builddir}/topology.bin | cut -d' ' -f1)
[ "$got" = "$expected" ] ||
	{ echo "topology sha256 $got != expected $expected" >&2; exit 1; }

%install
install -D -m0644 %{_builddir}/topology.bin \
	%{buildroot}%{_prefix}/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin
mkdir -p %{buildroot}%{_datadir}
tar -xf %{SOURCE3} -C %{buildroot}%{_datadir}
[ -f %{buildroot}%{_datadir}/alsa/ucm2/conf.d/sm8450/Xiaomi-Pad-6-Pro.conf ] ||
	{ echo 'UCM2 entry point missing after extraction' >&2; exit 1; }
[ -f %{buildroot}%{_datadir}/alsa/ucm2/Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf ] ||
	{ echo 'UCM2 HiFi verb missing after extraction' >&2; exit 1; }
install -D -m0644 %{SOURCE6} %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -D -m0644 %{SOURCE5} %{buildroot}%{_datadir}/licenses/%{name}/NOTICE
install -D -m0644 %{SOURCE7} %{buildroot}%{_defaultdocdir}/%{name}/README.audio-topology.md

%files
%license %{_datadir}/licenses/%{name}/LICENSE
%license %{_datadir}/licenses/%{name}/NOTICE
%doc %{_defaultdocdir}/%{name}/README.audio-topology.md
%{_prefix}/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin
%{_datadir}/alsa/ucm2/conf.d/sm8450/Xiaomi-Pad-6-Pro.conf
%{_datadir}/alsa/ucm2/Qualcomm/sm8450/Xiaomi-Pad-6-Pro/HiFi.conf

%changelog
* Tue Oct 20 2026 liuqin-fedora project <liuqin@localhost> - 0.6.0-1
- Initial packaging from xiaomipad-6pro-mainline v0.6.0.
