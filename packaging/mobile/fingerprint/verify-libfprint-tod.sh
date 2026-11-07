#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# TN0034 offline verification entry point for the libfprint-tod /
# liuqin-fpc1264-tod RPMs. Runs on the host and orchestrates:
#   1. container-side RPM/layout/ABI/install/systemd checks  (mbuilder)
#   2. a throwaway arm64 container with a FAKE char device at /dev/fpc1020
#      (/dev/null bind-mounted) to prove TOD discovery/adapter/enumeration.
#
# Output: out/fingerprint-tod/verify/{rpm-verify,probe-verify}.log
# This is verified-offline only. No real device is touched; fingerprint
# enrollment/unlock remains pending-device.
set -uo pipefail
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
container=${CONTAINER:-mbuilder}
probe_container=${PROBE_CONTAINER:-tn0034-fpc-probe}
probe_image=${PROBE_IMAGE:-localhost/liuqin-rpmbuild:fc45}
verify_dir=$project_root/out/fingerprint-tod/verify
mkdir -p "$verify_dir"
fail=0

ensure_container() {
  local name=$1 image=$2
  if ! sudo -n podman container exists "$name" 2>/dev/null; then
    echo "creating container $name from $image"
    sudo -n podman run -d --name "$name" --arch arm64 --network=host \
      -v "$project_root":/work:z \
      -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
      -e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
      "$image" sleep infinity >/dev/null
  fi
}

echo "=== [1/2] RPM/layout/ABI/install checks in $container ==="
ensure_container "$container" registry.fedoraproject.org/fedora:45
sudo -n podman cp "$project_root/packaging/mobile/fingerprint/verify-libfprint-tod-container.sh" \
  "$container":/root/verify-libfprint-tod-container.sh
sudo -n podman exec "$container" bash /root/verify-libfprint-tod-container.sh 2>&1 \
  | tee "$verify_dir/rpm-verify.log"
inner_rc=${PIPESTATUS[0]}
[ "$inner_rc" -eq 0 ] || fail=$((fail+1))

echo
echo "=== [2/2] fake /dev/fpc1020 TOD enumeration (throwaway container) ==="
sudo -n podman rm -f "$probe_container" >/dev/null 2>&1 || true
sudo -n podman run -d --name "$probe_container" --arch arm64 --network=host \
  -v "$project_root":/work:z \
  -v /dev/null:/dev/fpc1020:ro \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
  "$probe_image" sleep infinity >/dev/null
sudo -n podman cp "$project_root/packaging/mobile/fingerprint/fp-tod-probe.c" \
  "$probe_container":/root/fp-tod-probe.c
sudo -n podman cp "$project_root/packaging/mobile/fingerprint/verify-libfprint-tod-probe.sh" \
  "$probe_container":/root/verify-libfprint-tod-probe.sh
sudo -n podman exec "$probe_container" bash /root/verify-libfprint-tod-probe.sh 2>&1 \
  | tee "$verify_dir/probe-verify.log"
probe_rc=${PIPESTATUS[0]}
[ "$probe_rc" -eq 0 ] || fail=$((fail+1))
sudo -n podman rm -f "$probe_container" >/dev/null 2>&1 || true

echo
if [ "$fail" -eq 0 ]; then
  echo "TN0034 VERIFY: PASS (verified-offline only; fingerprint unlock = pending-device)"
  echo "logs: $verify_dir/rpm-verify.log, $verify_dir/probe-verify.log"
  exit 0
else
  echo "TN0034 VERIFY: FAIL ($fail stage(s))"
  echo "logs: $verify_dir/rpm-verify.log, $verify_dir/probe-verify.log"
  exit 1
fi
