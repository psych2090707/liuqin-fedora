#!/bin/bash
# Offline verification of the built liuqin mobile RPMs. Runs INSIDE the arm64
# Fedora 45 container (mounted workspace at /work). No device access.
set -uo pipefail
out=/work/out/rpms-mobile
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
shopt -s nullglob
rpms=("$out"/*.rpm)
if [ ${#rpms[@]} -eq 0 ]; then echo "FAIL: no RPMs in $out"; exit 1; fi
root=$tmp/verifyroot
mkdir -p "$root"
# The verify root only contains our RPM payload; stub the few base-system
# targets/sockets and the python3 interpreter that our units reference so
# systemd-analyze reports problems with OUR units, not with the minimal root.
mkdir -p "$root/usr/lib/systemd/system" "$root/usr/lib/systemd/user" "$root/usr/bin"
for u in sysinit.target basic.target multi-user.target graphical.target local-fs.target network.target; do
  printf '[Unit]\nDescription=verify-root stub\n' > "$root/usr/lib/systemd/system/$u"
done
printf '[Socket]\nListenStream=/run/verify-stub.socket\n' > "$root/usr/lib/systemd/system/dbus.socket"
printf '#!/bin/sh\nexit 0\n' > "$root/usr/bin/python3"
chmod 0755 "$root/usr/bin/python3"
for rpm in "${rpms[@]}"; do
  name=$(rpm -qp --qf '%{NAME}' "$rpm")
  ver=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$rpm")
  arch=$(rpm -qp --qf '%{ARCH}' "$rpm")
  case $arch in aarch64|noarch) ;; *) echo "FAIL: $name has arch $arch"; fail=1 ;; esac
  echo "RPM ok: $name $ver ($arch)"
  ( cd "$root" && rpm2cpio "$rpm" | cpio -idm --quiet ) || { echo "FAIL: extract $rpm"; fail=1; }
done
# 1) every ELF payload is aarch64
while IFS= read -r elf; do
  file "$elf" | grep -q 'ELF 64-bit LSB.*ARM aarch64' || { echo "FAIL: non-aarch64 ELF $elf"; fail=1; }
done < <(find "$root" -type f -exec file {} + | grep 'ELF' | cut -d: -f1)
echo "ELF arch check done"
# 2) required binaries exist and are executable
for b in usr/bin/hexagonrpcd usr/bin/ssccli usr/libexec/iio-sensor-proxy \
         usr/libexec/liuqin-fingerprint/qsee-supplicant \
         usr/libexec/liuqin-fingerprint/fprintd; do
  if [ -x "$root/$b" ]; then echo "binary ok: /$b"; else echo "FAIL: missing /$b"; fail=1; fi
done
# 3) no Ubuntu/upstream candidate paths leaked into payload config/scripts
for needle in /usr/local/lib/liuqin-fpc-oem /usr/local/sbin/liuqin /usr/local/libexec/liuqin-iio-sensor-proxy; do
  hits=$(grep -RIl --exclude='*.md' --exclude='*.json' -- "$needle" "$root" 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "FAIL: Ubuntu path '$needle' in: $hits"; fail=1; fi
done
echo "path hygiene check done"
# 4) systemd unit verification (units must exist and parse)
# -type f: the liuqin-fpc1264-tod RPM legitimately ships a drop-in DIRECTORY
# (liuqin-fprintd-oem.service.d/); passing that directory to systemd-analyze
# fails with "Failed to prepare filename ... Invalid argument".
units=$(find "$root/usr/lib/systemd/system" -maxdepth 2 -type f \( -name 'liuqin-*' -o -name 'iio-sensor-proxy.service' -o -name 'hexagonrpcd-*.service' \) 2>/dev/null)
if [ -n "$units" ]; then
  echo "--- systemd-analyze verify ---"
  if ! systemd-analyze verify --root="$root" --man=no $units; then
    echo "FAIL: systemd-analyze verify reported problems"; fail=1
  fi
else
  echo "FAIL: no systemd units found"; fail=1
fi
# 5) source/patch manifests are present
[ -f "$root/usr/share/doc/liuqin/sensor-stack-sources.manifest" ] || { echo "FAIL: missing sensor source manifest"; fail=1; }
[ -f "$root/usr/share/doc/liuqin/sensor-stack-patches.manifest" ] || { echo "FAIL: missing sensor patch manifest"; fail=1; }
[ -f "$root/usr/share/doc/liuqin-fingerprint/SOURCE_LOCK.json" ] || { echo "FAIL: missing fingerprint source lock"; fail=1; }
# 6) no vendor trustzone/firmware binary is packaged
if find "$root" -type f \( -name '*.mbn' -o -name '*.b*' \) | grep -q .; then
  echo "FAIL: firmware/TA binary shipped in fingerprint package"; fail=1
fi
echo "----"
if [ "$fail" = 0 ]; then echo "VERIFY: PASS"; else echo "VERIFY: FAIL"; fi
exit "$fail"
