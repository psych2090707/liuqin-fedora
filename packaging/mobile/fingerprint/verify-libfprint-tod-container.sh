#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline verification of the libfprint-tod / liuqin-fpc1264-tod RPMs.
# Runs INSIDE the arm64 Fedora 45 container (workspace mounted at /work).
# Host wrapper: packaging/mobile/fingerprint/verify-libfprint-tod.sh
# No device access; the fake /dev/fpc1020 enumeration test lives in the host
# wrapper (throwaway container), not here.
set -uo pipefail
out=/work/out/rpms-mobile
verify_dir=/work/out/fingerprint-tod/verify
fail=0
shopt -s nullglob

note()   { echo "OK: $*"; }
bad()    { echo "FAIL: $*"; fail=$((fail+1)); }
warn()   { echo "WARN: $*"; }
hr()     { echo "=== $* ==="; }

mkdir -p "$verify_dir"
tmp=$(mktemp -d /tmp/tn0034-verify.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

hr "artifacts"
lib_rpms=("$out"/libfprint-tod-1.95.1*.rpm)
devel_rpms=("$out"/libfprint-tod-devel-*.rpm)
adapter_rpms=("$out"/liuqin-fpc1264-tod-*.rpm)
if [ ${#lib_rpms[@]} -ne 1 ]; then bad "expected exactly 1 libfprint-tod RPM, got ${#lib_rpms[@]}"; fi
if [ ${#devel_rpms[@]} -ne 1 ]; then bad "expected exactly 1 libfprint-tod-devel RPM, got ${#devel_rpms[@]}"; fi
if [ ${#adapter_rpms[@]} -ne 1 ]; then bad "expected exactly 1 liuqin-fpc1264-tod RPM, got ${#adapter_rpms[@]}"; fi
[ ${#lib_rpms[@]} -eq 1 ] && note "libfprint-tod: $(basename "${lib_rpms[0]}")"
[ ${#devel_rpms[@]} -eq 1 ] && note "libfprint-tod-devel: $(basename "${devel_rpms[0]}")"
[ ${#adapter_rpms[@]} -eq 1 ] && note "liuqin-fpc1264-tod: $(basename "${adapter_rpms[0]}")"
if [ $fail -ne 0 ]; then echo "VERIFY: FAIL ($fail)"; exit 1; fi

lib_rpm=${lib_rpms[0]}; devel_rpm=${devel_rpms[0]}; adapter_rpm=${adapter_rpms[0]}

hr "RPM metadata"
for rpm in "$lib_rpm" "$devel_rpm" "$adapter_rpm"; do
  name=$(rpm -qp --qf '%{NAME}' "$rpm")
  evr=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$rpm")
  arch=$(rpm -qp --qf '%{ARCH}' "$rpm")
  lic=$(rpm -qp --qf '%{LICENSE}' "$rpm")
  echo "RPM: $name $evr $arch license=$lic"
  case $arch in aarch64) note "$name arch aarch64" ;; *) bad "$name arch $arch" ;; esac
  case $name in
    libfprint-tod|libfprint-tod-devel) [ "$evr" = "1.95.1+tod1-1.liuqin.fc45" ] || bad "$name unexpected EVR $evr" ;;
    liuqin-fpc1264-tod) [ "$evr" = "1.0-1.liuqin.fc45" ] || bad "$name unexpected EVR $evr" ;;
  esac
  case $lic in *LGPL-2.1*) note "$name license LGPL-2.1" ;; *) bad "$name license '$lic'" ;; esac
done

hr "package relation guards (must not hijack Fedora libfprint soname)"
lib_provides=$(rpm -qp --provides "$lib_rpm")
if grep -qE '^libfprint-2\.so\.2' <<<"$lib_provides"; then
  bad "libfprint-tod still provides the system soname libfprint-2.so.2 (dnf could pick it for fprintd)"
else
  note "no libfprint-2.so.2 auto-provide (system fprintd keeps Fedora libfprint)"
fi
grep -qE '^libfprint-2-tod\.so\.1' <<<"$lib_provides" && note "provides libfprint-2-tod.so.1" || bad "missing libfprint-2-tod.so.1 provide"
adapter_requires=$(rpm -qp --requires "$adapter_rpm")
if grep -qE '^libfprint-2(\.so\.2|-tod\.so\.1)' <<<"$adapter_requires"; then
  bad "adapter has auto soname requires that would resolve to Fedora libfprint: $(grep -E 'libfprint-2' <<<"$adapter_requires" | tr '\n' ' ')"
else
  note "adapter has no auto libfprint soname requires (AutoReqProv: no)"
fi
grep -qE '^libfprint-tod\(aarch-64\) >= 1\.95\.1' <<<"$adapter_requires" \
  && note "adapter requires private libfprint-tod package" \
  || bad "adapter missing explicit libfprint-tod require"
grep -qE '^libfprint-2\.so\.2' <<<"$(rpm -qp --requires "$lib_rpm")" \
  && bad "libfprint-tod requires system libfprint-2.so.2" \
  || note "libfprint-tod does not require system libfprint-2.so.2"

hr "payload layout (extracted, no install yet)"
root=$tmp/root
mkdir -p "$root"
for rpm in "${lib_rpms[0]}" "${devel_rpms[0]}" "${adapter_rpms[0]}" \
           "$out"/qsee-supplicant-*.rpm "$out"/fprintd-oem-*.rpm "$out"/liuqin-fingerprint-support-*.rpm; do
  ( cd "$root" && rpm2cpio "$rpm" | cpio -idm --quiet ) || bad "extract failed: $(basename "$rpm")"
done
priv_lib=$root/usr/lib64/liuqin-fingerprint/libfprint-tod
for f in usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so \
         usr/libexec/liuqin-fingerprint/fpc-oem-print \
         usr/lib/systemd/system/liuqin-fprintd-oem.service.d/10-libfprint-tod.conf \
         usr/share/doc/liuqin-fingerprint/TOD-PROVENANCE.md; do
  [ -e "$root/$f" ] && note "present /$f" || bad "missing /$f"
done
[ -e "$priv_lib/libfprint-2.so.2" ] && note "private libfprint-2.so.2" || bad "missing private libfprint-2.so.2"
[ -e "$priv_lib/libfprint-2-tod.so.1" ] && note "private libfprint-2-tod.so.1" || bad "missing private libfprint-2-tod.so.1"
[ -e "$root/usr/lib64/libfprint-2.so.2" ] && bad "libfprint-tod installed a system-path libfprint-2.so.2" \
  || note "no system-path libfprint-2.so.2 from these RPMs"
[ -e "$root/usr/share/metainfo/org.freedesktop.libfprint.metainfo.xml" ] && bad "metainfo would collide with Fedora libfprint" \
  || note "no metainfo collision"
[ -e "$root/usr/lib/udev/rules.d/70-libfprint-2.rules" ] && bad "udev rules would collide with Fedora libfprint" \
  || note "no udev rules collision"
for pc in usr/lib64/liuqin-fingerprint/pkgconfig/libfprint-2.pc \
          usr/lib64/liuqin-fingerprint/pkgconfig/libfprint-2-tod-1.pc; do
  [ -e "$root/$pc" ] && note "private pkg-config /$pc" || bad "missing /$pc"
done
grep -q 'LD_LIBRARY_PATH=/usr/lib64/liuqin-fingerprint/libfprint-tod' \
  "$root/usr/lib/systemd/system/liuqin-fprintd-oem.service.d/10-libfprint-tod.conf" \
  && note "drop-in sets scoped LD_LIBRARY_PATH" || bad "drop-in missing LD_LIBRARY_PATH"

hr "ELF architecture"
while IFS= read -r elf; do
  file "$elf" | grep -q 'ELF 64-bit LSB.*ARM aarch64' || bad "non-aarch64 ELF: ${elf#$root}"
done < <(find "$priv_lib" "$root/usr/libexec/liuqin-fingerprint" -type f -exec file {} + | grep 'ELF' | cut -d: -f1)
note "all TOD/adapter ELFs are ARM aarch64"

hr "adapter ELF dependency wiring"
adapter_so=$root/usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so
print_elf=$root/usr/libexec/liuqin-fingerprint/fpc-oem-print
readelf -d "$adapter_so" | grep -q 'libfprint-2-tod.so.1' && note "adapter NEEDED libfprint-2-tod.so.1" || bad "adapter lacks libfprint-2-tod.so.1 NEEDED"
readelf -d "$adapter_so" | grep -q 'RPATH.*liuqin-fingerprint/libfprint-tod' \
  && note "adapter has DT_RPATH to private libs" || bad "adapter missing DT_RPATH to private libs"
readelf -d "$print_elf" | grep -q 'RPATH.*liuqin-fingerprint/libfprint-tod' \
  && note "fpc-oem-print has DT_RPATH to private libs" || bad "fpc-oem-print missing DT_RPATH"
adapter_syms=$(nm -D "$adapter_so" 2>/dev/null)
grep -q ' T fpi_tod_shared_driver_get_type' <<<"$adapter_syms" \
  && note "adapter exports fpi_tod_shared_driver_get_type" || bad "adapter missing TOD entry point"
grep -q 'device->id = "fpc1264_oem"' /work/upstream/xiaomipad-6pro-mainline/device/fingerprint/oem/src/fingerprint/libfprint-tod/fpc1264-oem.c \
  && note "adapter device id fpc1264_oem (source check)" || warn "adapter device id source check failed"

hr "real install transaction (dnf deps + rpm)"
dnf -y -q --setopt=install_weak_deps=False install polkit dbus >/dev/null 2>&1 || true
install_set=(
  "$out"/qsee-supplicant-*.rpm "$out"/fprintd-oem-*.rpm "$out"/liuqin-fingerprint-support-*.rpm
  "$lib_rpm" "$devel_rpm" "$adapter_rpm"
)
if rpm -Uvh --replacepkgs "${install_set[@]}" >"$tmp/install.log" 2>&1; then
  note "rpm -Uvh installed all six fingerprint RPMs (incl. new TOD packages)"
else
  bad "rpm -Uvh failed (see below)"
  sed 's/^/    /' "$tmp/install.log" | tail -20
fi
for pkg in libfprint-tod libfprint-tod-devel liuqin-fpc1264-tod liuqin-fingerprint-support fprintd-oem qsee-supplicant; do
  rpm -q "$pkg" >/dev/null 2>&1 && note "installed: $(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$pkg")" \
    || bad "package not installed: $pkg"
done
for f in /usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2-tod.so.1 \
         /usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so \
         /usr/libexec/liuqin-fingerprint/fpc-oem-print \
         /usr/lib/systemd/system/liuqin-fprintd-oem.service.d/10-libfprint-tod.conf; do
  [ -e "$f" ] && note "installed /$f" || bad "not installed: /$f"
done
if rpm -qf /usr/lib64/libfprint-2.so.2 2>/dev/null | grep -q '^libfprint-'; then
  note "system /usr/lib64/libfprint-2.so.2 still owned by Fedora libfprint ($(rpm -qf --qf '%{NAME}-%{VERSION}' /usr/lib64/libfprint-2.so.2))"
else
  bad "system libfprint ownership changed"
fi
ld_cache=$(ldconfig -p 2>/dev/null)
if grep -q 'liuqin-fingerprint/libfprint-tod' <<<"$ld_cache"; then
  bad "private TOD libs leaked into the system ld.so cache"
else
  note "private TOD libs are not in the system ld.so cache (only scoped LD_LIBRARY_PATH)"
fi

hr "ABI: existing fprintd-oem binary vs rebuilt TOD libfprint"
tod_lib=/usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2.so.2.0.0
fprintd_bin=/usr/libexec/liuqin-fingerprint/fprintd
readelf --dyn-syms -W "$tod_lib" | awk '$7!="UND" && $8 ~ /^fp_/ {sub(/@@?.*/,"",$8); print $8}' | sort -u >"$tmp/tod.exports"
readelf --dyn-syms -W "$fprintd_bin" | awk '$7=="UND" && $8 ~ /^fp_/ {sub(/@.*/,"",$8); print $8}' | sort -u >"$tmp/fprintd.needs"
missing=$(comm -23 "$tmp/fprintd.needs" "$tmp/tod.exports")
if [ -z "$missing" ]; then
  note "all $(wc -l <"$tmp/fprintd.needs") fp_* symbols needed by fprintd-oem exist in the TOD libfprint"
else
  bad "fprintd-oem missing symbols in TOD libfprint: $missing"
fi
needed_versions=$(readelf --dyn-syms -W "$fprintd_bin" | awk '$7=="UND" && $8 ~ /^fp_/ {sub(/.*@/,"",$8); print $8}' | sort -u)
tod_versions=$(readelf -V "$tod_lib" | grep -oE 'LIBFPRINT_2\.[0-9.]+' | sort -u)
if [ -z "$(comm -23 <(printf '%s\n' "$needed_versions") <(printf '%s\n' "$tod_versions"))" ]; then
  note "fprintd-oem symbol versions ($(echo "$needed_versions" | tr '\n' ' ')) provided by TOD libfprint"
else
  bad "symbol version mismatch: needed $(echo "$needed_versions" | tr '\n' ' '), have $(echo "$tod_versions" | tr '\n' ' ')"
fi
lld_with_tod=$(env LD_LIBRARY_PATH=/usr/lib64/liuqin-fingerprint/libfprint-tod ldd "$fprintd_bin" 2>/dev/null)
grep -E 'libfprint-2(-tod)?\.so' <<<"$lld_with_tod" | sed 's/^/    /'
if grep -q 'liuqin-fingerprint/libfprint-tod/libfprint-2\.so\.2' <<<"$lld_with_tod"; then
  note "with scoped LD_LIBRARY_PATH fprintd-oem resolves libfprint-2.so.2 to the private TOD build"
else
  bad "fprintd-oem does not resolve to the private TOD libfprint"
fi

hr "ABI: adapter vs TOD private library"
readelf --dyn-syms -W /usr/libexec/liuqin-fingerprint/tod/libfprint-tod-fpc1264-oem.so \
  | awk '$7=="UND" && $8 ~ /^fpi_/ {print $8}' | sort -u >"$tmp/adapter.needs"
readelf --dyn-syms -W /usr/lib64/liuqin-fingerprint/libfprint-tod/libfprint-2-tod.so.1 \
  | awk '$7!="UND" && $8 ~ /^fpi_/ {sub(/@@/,"@",$8); print $8}' | sort -u >"$tmp/todlib.exports"
adapter_missing=$(comm -23 "$tmp/adapter.needs" "$tmp/todlib.exports")
if [ -z "$adapter_missing" ]; then
  note "all $(wc -l <"$tmp/adapter.needs") versioned fpi_* TOD symbols needed by the adapter exist in libfprint-2-tod.so.1"
else
  bad "adapter missing TOD symbols: $adapter_missing"
fi

hr "systemd units (unit + drop-in parse)"
unit_root=$tmp/unitroot
mkdir -p "$unit_root"
for rpm in "$out"/fprintd-oem-*.rpm "$out"/liuqin-fingerprint-support-*.rpm "$lib_rpm" "$adapter_rpm"; do
  ( cd "$unit_root" && rpm2cpio "$rpm" | cpio -idm --quiet ) || true
done
mkdir -p "$unit_root/usr/lib/systemd/system" "$unit_root/usr/lib/systemd/user" "$unit_root/usr/bin"
for u in sysinit.target basic.target multi-user.target graphical.target local-fs.target network.target; do
  printf '[Unit]\nDescription=verify-root stub\n' >"$unit_root/usr/lib/systemd/system/$u"
done
printf '[Socket]\nListenStream=/run/verify-stub.socket\n' >"$unit_root/usr/lib/systemd/system/dbus.socket"
printf '#!/bin/sh\nexit 0\n' >"$unit_root/usr/bin/python3"; chmod 0755 "$unit_root/usr/bin/python3"
units=$(find "$unit_root/usr/lib/systemd/system" -maxdepth 1 -type f -name 'liuqin-*' 2>/dev/null)
if [ -n "$units" ] && systemd-analyze verify --root="$unit_root" --man=no $units >"$tmp/units.log" 2>&1; then
  note "systemd-analyze verify: unit + drop-in parse OK ($(echo "$units" | wc -w) units)"
else
  bad "systemd-analyze verify problems"; sed 's/^/    /' "$tmp/units.log" | head -20
fi

hr "result"
if [ $fail -eq 0 ]; then
  echo "VERIFY: PASS (libfprint-tod + liuqin-fpc1264-tod RPMs, Fedora 45 aarch64)"
  exit 0
else
  echo "VERIFY: FAIL ($fail failure(s))"
  exit 1
fi
