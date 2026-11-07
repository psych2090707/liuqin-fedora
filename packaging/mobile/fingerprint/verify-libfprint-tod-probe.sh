#!/bin/bash
# SPDX-License-Identifier: MIT
# In-container part of the fake-/dev/fpc1020 TOD enumeration test.
# Runs INSIDE the throwaway arm64 container created by
# packaging/mobile/fingerprint/verify-libfprint-tod.sh, with:
#   - /work mounted read-only-ish (same repo mount)
#   - a fake char device bind-mounted at /dev/fpc1020 (/dev/null)
# This proves the TOD discovery/adapter/enumeration plumbing works offline.
# It is NOT a hardware test and NOT a fingerprint enrollment/unlock claim.
set -uo pipefail
out=/work/out/rpms-mobile
fail=0
note() { echo "OK: $*"; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }
hr()   { echo "=== $* ==="; }

hr "probe container prerequisites"
# libgusb-devel is needed for gusb.pc (Requires: of the private TOD pc file);
# glib2-devel/pixman/libgudev/libfprint provide the remaining build/runtime bits.
dnf -y -q --setopt=install_weak_deps=False install \
    gcc glib2-devel pkgconf-pkg-config libgusb-devel libgudev pixman libfprint \
    >/tmp/probe-deps.log 2>&1 \
  || { bad "dnf install probe dependencies failed"; tail -20 /tmp/probe-deps.log; }
command -v gcc >/dev/null && command -v pkg-config >/dev/null \
  || { bad "gcc/pkg-config missing after dependency install"; tail -20 /tmp/probe-deps.log; }
rpm -q glib2 libgusb libgudev pixman libfprint >/dev/null 2>&1 || bad "probe runtime deps incomplete"
note "Fedora libfprint present: $(rpm -q --qf '%{NAME}-%{VERSION}' libfprint 2>/dev/null)"

lib_rpm=$(ls "$out"/libfprint-tod-1.95.1*.rpm 2>/dev/null | head -1)
devel_rpm=$(ls "$out"/libfprint-tod-devel-*.rpm 2>/dev/null | head -1)
adapter_rpm=$(ls "$out"/liuqin-fpc1264-tod-*.rpm 2>/dev/null | head -1)
[ -n "$lib_rpm" ] || bad "libfprint-tod RPM not found"
[ -n "$devel_rpm" ] || bad "libfprint-tod-devel RPM not found"
[ -n "$adapter_rpm" ] || bad "liuqin-fpc1264-tod RPM not found"
if [ $fail -ne 0 ]; then echo "PROBE VERIFY: FAIL ($fail)"; exit 1; fi

hr "install private TOD libfprint + extract adapter payload"
if rpm -Uvh --noscripts "$lib_rpm" "$devel_rpm" >/tmp/probe-install.log 2>&1; then
  note "installed $(basename "$lib_rpm") + $(basename "$devel_rpm")"
else
  bad "rpm install failed"; tail -20 /tmp/probe-install.log
fi
rm -rf /tmp/tod && mkdir -p /tmp/tod
if ( cd /tmp/tod && rpm2cpio "$adapter_rpm" | cpio -idm --quiet ); then
  note "extracted adapter payload from $(basename "$adapter_rpm")"
else
  bad "adapter payload extraction failed"
fi
adapter_so=/tmp/tod/usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so
print_bin=/tmp/tod/usr/libexec/liuqin-fingerprint/fpc-oem-print
[ -e "$adapter_so" ] || bad "adapter .so missing after extract"
[ -e "$print_bin" ] || bad "fpc-oem-print missing after extract"

hr "fake device node"
python3 - <<'PYDEV' || bad "fake /dev/fpc1020 is not a character device"
import os, stat
try:
    st = os.lstat('/dev/fpc1020')
except OSError as e:
    print('lstat failed:', e); raise SystemExit(1)
print('lstat /dev/fpc1020: mode=%o is_chr=%s' % (stat.S_IMODE(st.st_mode), stat.S_ISCHR(st.st_mode)))
raise SystemExit(0 if stat.S_ISCHR(st.st_mode) else 1)
PYDEV

hr "build FpContext probe against the private pkg-config"
export PKG_CONFIG_PATH=/usr/lib64/liuqin-fingerprint/pkgconfig
# The private main lib has a DT_NEEDED on libfprint-2-tod.so.1 and thus carries
# private fpi_* references; -rpath-link lets ld resolve them for verification
# without adding a direct TOD-lib NEEDED entry to the probe (the probe itself
# only uses the public API). That keeps loader selection controlled by
# LD_LIBRARY_PATH for the differential test below.
pc_out=$(pkg-config --cflags --libs libfprint-2 2>&1) || bad "pkg-config private libfprint-2 failed"
echo "    pkg-config --cflags --libs libfprint-2 -> $pc_out"
gcc -O2 -Wall -o /tmp/fp-tod-probe /root/fp-tod-probe.c $pc_out \
    -Wl,-rpath-link,/usr/lib64/liuqin-fingerprint/libfprint-tod >/tmp/probe-build.log 2>&1 \
  || { bad "probe compile failed"; tail -20 /tmp/probe-build.log; }
[ -x /tmp/fp-tod-probe ] && note "probe compiled (no RPATH: loader path controlled below)"

hr "TOD enumeration with fake /dev/fpc1020"
env FP_TOD_DRIVERS_DIR=/tmp/tod/usr/libexec/liuqin-fingerprint/tod \
    FP_DRIVERS_ALLOWLIST=fpc1264_oem \
    FP_LIUQIN_FPC1264_OEM_ENABLE=1 \
    LD_LIBRARY_PATH=/usr/lib64/liuqin-fingerprint/libfprint-tod \
    G_MESSAGES_DEBUG=all \
    /tmp/fp-tod-probe >/tmp/probe-a.log 2>&1
rc_a=$?
sed 's/^/    /' /tmp/probe-a.log
[ $rc_a -eq 0 ] && note "probe exit 0 (exactly 1 device enumerated)" || bad "probe exit $rc_a"
grep -q 'LIBFPRINT_VERSION\|libfprint version 1.95.1+tod1' /tmp/probe-a.log \
  && note "FpContext reports TOD libfprint 1.95.1+tod1" \
  || bad "FpContext did not report the TOD libfprint version"
grep -q 'Loading driver fpc1264_oem' /tmp/probe-a.log \
  && note "TOD shared loader picked up the FPC1264 adapter" \
  || bad "TOD shared loader did not load the FPC1264 adapter"
grep -q 'Found virtual environment device: FP_LIUQIN_FPC1264_OEM_ENABLE' /tmp/probe-a.log \
  && note "FP_LIUQIN_FPC1264_OEM_ENABLE virtual device path taken" \
  || bad "virtual device environment gate not seen"
grep -q 'PROBE_DEVICE_INDEX=0 DRIVER=fpc1264_oem' /tmp/probe-a.log \
  && note "device enumerated with driver fpc1264_oem" \
  || bad "fpc1264_oem device not enumerated"
grep -q 'PROBE_DEVICE_COUNT=1' /tmp/probe-a.log \
  && note "exactly one fingerprint device visible (allowlist works)" \
  || bad "unexpected device count"

hr "allowlist negative control"
env FP_TOD_DRIVERS_DIR=/tmp/tod/usr/libexec/liuqin-fingerprint/tod \
    FP_DRIVERS_ALLOWLIST=no-such-driver \
    FP_LIUQIN_FPC1264_OEM_ENABLE=1 \
    LD_LIBRARY_PATH=/usr/lib64/liuqin-fingerprint/libfprint-tod \
    /tmp/fp-tod-probe >/tmp/probe-b.log 2>&1
grep -q 'PROBE_DEVICE_COUNT=0' /tmp/probe-b.log \
  && note "allowlist excludes fpc1264_oem -> 0 devices" \
  || { bad "allowlist negative control failed"; sed 's/^/    /' /tmp/probe-b.log; }

hr "differential: stock Fedora libfprint has no TOD loader"
env -u LD_LIBRARY_PATH \
    FP_TOD_DRIVERS_DIR=/tmp/tod/usr/libexec/liuqin-fingerprint/tod \
    FP_DRIVERS_ALLOWLIST=fpc1264_oem \
    FP_LIUQIN_FPC1264_OEM_ENABLE=1 \
    G_MESSAGES_DEBUG=all \
    /tmp/fp-tod-probe >/tmp/probe-c.log 2>&1
rc_c=$?
grep -q 'libfprint version 1.94.100' /tmp/probe-c.log \
  && note "without the private LD_LIBRARY_PATH the probe loads Fedora libfprint 1.94.100" \
  || { bad "differential run did not load Fedora libfprint 1.94.100"; sed 's/^/    /' /tmp/probe-c.log | head -10; }
if grep -q 'Loading driver fpc1264_oem' /tmp/probe-c.log; then
  bad "stock Fedora libfprint unexpectedly loaded the TOD adapter"
else
  note "stock libfprint has no TOD shared-loader (adapter not opened)"
fi
[ $rc_c -eq 1 ] && grep -q 'PROBE_DEVICE_COUNT=0' /tmp/probe-c.log \
  && note "stock libfprint enumerates 0 devices with the same TOD env - private TOD lib justified" \
  || { bad "stock libfprint unexpectedly enumerated the TOD device"; sed 's/^/    /' /tmp/probe-c.log | head -10; }

hr "fpc-oem-print DT_RPATH resolution (acceptance CLI path, no daemon env)"
ldd "$print_bin" >/tmp/probe-ldd.log 2>&1
grep -E 'libfprint-2(-tod)?\.so' /tmp/probe-ldd.log | sed 's/^/    /'
if grep -q 'libfprint-2\.so\.2 => /usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2\.so\.2' /tmp/probe-ldd.log \
   && grep -q 'libfprint-2-tod\.so\.1 => /usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2-tod\.so\.1' /tmp/probe-ldd.log; then
  note "fpc-oem-print resolves both libfprint libs to the private TOD build via DT_RPATH"
else
  bad "fpc-oem-print DT_RPATH does not resolve the private TOD libs"
fi

hr "result"
if [ $fail -eq 0 ]; then
  echo "PROBE VERIFY: PASS (fake-/dev/fpc1020 TOD enumeration, verified-offline only)"
  exit 0
else
  echo "PROBE VERIFY: FAIL ($fail failure(s))"
  exit 1
fi
