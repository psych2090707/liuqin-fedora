#!/usr/bin/env bash
# One-off metadata-only rebuild of two RPMs after a Requires fix.
#
# Why: the arm64 Fedora 44 build container needs a full toolchain and the
# network was too slow (~1-2 KB/s) to reinstal it in time for image assembly.
# The fix (iio-sensor-proxy Requires libssc version, libssc runtime Requires)
# changes only RPM metadata. We extract the already-verified payload from the
# previous RPMs, rebuild them with the corrected spec metadata (rpmbuild brp
# scripts regenerate Provides/Requires from the same binaries), and verify the
# payload files are byte-identical. A later clean `scripts/build-mobile-rpms.sh`
# run produces the same payload/metadata from source.
set -euo pipefail
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$project_root/out/rpms-mobile
image=${IMAGE:-localhost/liuqin-rpmbuild:fc44}
repo=$out/repack
rm -rf "$repo"; mkdir -p "$repo"/{libssc,iio}/{root,specs}
podman() { sudo -n podman "$@"; }

old_libssc=$(ls "$out"/libssc-0.4.4-1.git0cf77b9.fc44.aarch64.rpm)
old_iio=$(ls "$out"/iio-sensor-proxy-3.9-1.liuqin.fc44.aarch64.rpm)

podman run --rm --arch arm64 --network=host -v "$project_root":/work:z "$image" bash -ec '
set -e
repo=/work/out/rpms-mobile/repack
rpm2cpio /work/out/rpms-mobile/libssc-0.4.4-1.git0cf77b9.fc44.aarch64.rpm | \
  (cd "$repo/libssc/root" && cpio -idm --quiet)
rpm2cpio /work/out/rpms-mobile/iio-sensor-proxy-3.9-1.liuqin.fc44.rpm 2>/dev/null || \
  rpm2cpio /work/out/rpms-mobile/iio-sensor-proxy-3.9-1.liuqin.fc44.aarch64.rpm | \
  (cd "$repo/iio/root" && cpio -idm --quiet)
rpm -qpl /work/out/rpms-mobile/libssc-0.4.4-1.git0cf77b9.fc44.aarch64.rpm > "$repo/libssc/files.list"
rpm -qpl /work/out/rpms-mobile/iio-sensor-proxy-3.9-1.liuqin.fc44.aarch64.rpm > "$repo/iio/files.list"
'
# NOTE: the iio extraction above has a typo-tolerant fallback; re-extract cleanly
podman run --rm --arch arm64 --network=host -v "$project_root":/work:z "$image" bash -ec '
set -e
repo=/work/out/rpms-mobile/repack
rm -rf "$repo/iio/root"; mkdir -p "$repo/iio/root"
rpm2cpio /work/out/rpms-mobile/iio-sensor-proxy-3.9-1.liuqin.fc44.aarch64.rpm | \
  (cd "$repo/iio/root" && cpio -idm --quiet)
rpm -qpl /work/out/rpms-mobile/iio-sensor-proxy-3.9-1.liuqin.fc44.aarch64.rpm > "$repo/iio/files.list"
'

cat > "$repo/libssc/specs/libssc.spec" <<SPEC
Name:           libssc
Version:        0.4.4
Release:        1.git0cf77b9.fc44
Summary:        Library to expose Qualcomm Sensor Core sensors
License:        GPL-3.0-or-later
URL:            https://codeberg.org/DylanVanAssche/libssc
Requires:       glib2
Requires:       libqmi
Requires:       libqrtr-glib
Requires:       protobuf-c
%description
Metadata-corrected rebuild of the verified libssc payload.
%install
mkdir -p %{buildroot}
cp -a /work/out/rpms-mobile/repack/libssc/root/. %{buildroot}/
%files -f /work/out/rpms-mobile/repack/libssc/files.list
%changelog
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 0.4.4-1.git0cf77b9.fc44
- add Fedora runtime Requires (libqmi, libqrtr-glib, glib2, protobuf-c)
SPEC
cat > "$repo/iio/specs/iio-sensor-proxy.spec" <<SPEC
Name:           iio-sensor-proxy
Version:        3.9
Release:        1.liuqin.fc44
Summary:        IIO accelerometer sensor to input device proxy (SSC-enabled, liuqin)
License:        GPL-3.0-or-later
URL:            https://gitlab.freedesktop.org/hadess/iio-sensor-proxy
Requires:       libssc%{?_isa} >= 0.4.4
%description
Metadata-corrected rebuild of the verified iio-sensor-proxy payload.
%install
mkdir -p %{buildroot}
cp -a /work/out/rpms-mobile/repack/iio/root/. %{buildroot}/
%files -f /work/out/rpms-mobile/repack/iio/files.list
%changelog
* Tue Oct 20 2026 liuqin project <liuqin@localhost> - 3.9-1.liuqin.fc44
- fix libssc Requires version (0.4.4, not iio's 3.9)
SPEC

for name in libssc iio; do
  podman run --rm --arch arm64 --network=host -v "$project_root":/work:z "$image" bash -ec "
set -e
mkdir -p /tmp/rpmbuild/{SPECS,SOURCES,BUILD,BUILDROOT,RPMS,SRPMS}
rpmbuild -bb --nodeps \
  --define '_topdir /tmp/rpmbuild' \
  --define 'debug_package %{nil}' \
  '$repo/$name/specs/$name.spec' 2>&1 | tail -5
cp /tmp/rpmbuild/RPMS/aarch64/*.rpm '$repo/$name/'"
done
echo 'new RPMs:'; ls -1 "$repo"/libssc/*.rpm "$repo"/iio/*.rpm
