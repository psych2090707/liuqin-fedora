#!/usr/bin/env bash
# Build liuqin mobile userspace RPMs (sensors stack; fingerprint pipeline) for
# Fedora 45 aarch64, using an arm64 Fedora container under qemu-user binfmt.
#
# Usage:  scripts/build-mobile-rpms.sh [fetch|sensors|fingerprint|fingerprint-support|fingerprint-tod|all|verify]
#   fetch           fetch pinned sources + create deterministic tarballs only
#   sensors         build libssc / hexagonrpc / iio-sensor-proxy / liuqin-sensors-support
#   fingerprint     build qsee-supplicant / fprintd-oem / liuqin-fingerprint-support
#   fingerprint-support rebuild only the Fedora integration/support package
#   fingerprint-fprintd rebuild only the private fprintd-oem daemon
#   fingerprint-tod build libfprint-tod(+devel) from the liuqin-locked Ubuntu TOD
#                   open-source tarball and liuqin-fpc1264-tod (the FPC1264 adapter);
#                   see packaging/mobile/fingerprint/README-libfprint-tod.md
#   all             fetch + sensors + fingerprint + fingerprint-tod + repo metadata
#   verify          offline verification of built RPM payloads
set -euo pipefail
exec > >(tee -a /tmp/build-mobile-rpms.log) 2>&1

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${OUT_DIR:-$project_root/out/rpms-mobile}
mkdir -p "$out"
out=$(realpath "$out")
# Container bind mount: the project is mounted at /work, so a custom OUT_DIR
# must be translated instead of assuming the historical out/rpms-mobile path.
container_out=/work/${out#"$project_root"/}
work=$out/work
srccache=$out/src
tarballs=$out/src/tarballs
container=${CONTAINER:-mbuilder}
image=${IMAGE:-registry.fedoraproject.org/fedora:45}
jobs=${JOBS:-8}
source_date_epoch=${SOURCE_DATE_EPOCH:-1761000000}
export SOURCE_DATE_EPOCH=$source_date_epoch
manifest=$project_root/upstream/xiaomipad-6pro-mainline/device/sensors/sources.manifest
upstream_root=$project_root/upstream/xiaomipad-6pro-mainline
fingerprint_root=$upstream_root/device/fingerprint/oem
fingerprint_lock=$fingerprint_root/SOURCE_LOCK.json
fingerprint_doc=$project_root/packaging/mobile/fingerprint/README-libfprint-tod.md
patch_dir=$project_root/packaging/mobile/patches
spec_dir=$project_root/packaging/mobile/specs

say() { printf 'build-mobile-rpms: %s\n' "$*"; }
die() { printf 'build-mobile-rpms: ERROR: %s\n' "$*" >&2; exit 1; }

podman() { sudo -n podman "$@"; }
podman_exec() { sudo -n podman exec -u 0 "$@" ; }
user_exec() { sudo -n podman exec -u "$(id -u):$(id -g)" -e HOME=/tmp/mobile-home "$@"; }

ensure_container() {
  if ! podman container exists "$container" 2>/dev/null; then
    say "creating arm64 build container $container"
    podman run -d --name "$container" --arch arm64 --network=host \
      -v "$project_root":/work:z \
      -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
      "$image" sleep infinity >/dev/null
  fi
  if [ "$(podman inspect -f '{{.State.Running}}' "$container")" != true ]; then
    podman start "$container" >/dev/null
  fi
  if ! podman_exec "$container" test -f /opt/liuqin-mobile-build.deps-v1; then
    say "installing build dependencies in container (first run, qemu-user; slow)"
    podman cp "$project_root/packaging/mobile/container/install-deps.sh" "$container":/root/install-deps.sh
    podman_exec "$container" bash /root/install-deps.sh
  fi
  podman_exec "$container" mkdir -p /tmp/mobile-home
  podman_exec "$container" chown "$(id -u):$(id -g)" /tmp/mobile-home
}

fetch_sources() {
  mkdir -p "$srccache" "$tarballs" "$work/SOURCES"
  say "fetching pinned sensor sources"
  while IFS=$'\t' read -r component version repository commit tree; do
    case $component in ''|'#'*) continue ;; esac
    dir=$srccache/$component
    if [ ! -d "$dir/.git" ]; then
      git clone -q --filter=blob:none "$repository" "$dir" || die "clone failed: $component"
    fi
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$dir" fetch -q origin "$commit"
    git -C "$dir" checkout -q --detach "$commit"
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$component commit mismatch"
    [ "$(git -C "$dir" rev-parse 'HEAD^{tree}')" = "$tree" ] || die "$component tree mismatch"
    baseversion=${version%%-*}
    tarfile=$tarballs/$component-$baseversion.tar.gz
    if [ ! -f "$tarfile" ]; then
      say "creating deterministic tarball $component-$baseversion (commit $commit)"
      git -C "$dir" archive --format=tar --prefix="$component-$baseversion/" "$commit" \
        | gzip -n -9 >"$tarfile"
    fi
    cp "$tarfile" "$work/SOURCES/"
  done <"$manifest"
  # patches (from the pinned upstream repo, sha256-checked in the original tooling)
  cp "$patch_dir"/*.patch "$work/SOURCES/"
  say "sources: $(ls "$work/SOURCES" | wc -l) files"
}

support_tarball() {
  local stage=$work/support-stage/liuqin-sensors-support-1.0
  rm -rf "$work/support-stage"; mkdir -p "$stage"
  cp -a "$project_root/packaging/mobile/sensors-overlay/." "$stage/"
  {
    printf '# component\tversion\trepository\tcommit\ttree\ttarball-sha256\n'
    while IFS=$'\t' read -r component version repository commit tree; do
      case $component in ''|'#'*) continue ;; esac
      baseversion=${version%%-*}
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$component" "$version" "$repository" \
        "$commit" "$tree" "$(sha256sum "$tarballs/$component-$baseversion.tar.gz" | cut -d' ' -f1)"
    done <"$manifest"
  } >"$stage/usr/share/doc/liuqin/sensor-stack-sources.manifest"
  {
    printf '# patch\tsha256\n'
    (cd "$patch_dir" && sha256sum *.patch)
  } >"$stage/usr/share/doc/liuqin/sensor-stack-patches.manifest"
  tar --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@$SOURCE_DATE_EPOCH" -C "$work/support-stage" -czf \
      "$work/SOURCES/liuqin-sensors-support-1.0.tar.gz" liuqin-sensors-support-1.0
}

install_built_deps() {
  # Later specs BuildRequire earlier outputs; install them into the throwaway
  # container so rpmbuild's BuildRequires resolution works offline.
  case $1 in
    libssc)
      podman_exec "$container" bash -lc "rpm -Uvh --replacepkgs --nodeps --nosignature $container_out/rpms/aarch64/libssc-*.rpm >/dev/null && echo installed-libssc" ;;
    libfprint-tod)
      # libfprint-tod-devel is a BuildRequires of liuqin-fpc1264-tod (private
      # headers + pkg-config); the glob installs main + devel together.
      podman_exec "$container" bash -lc "rpm -Uvh --replacepkgs --nodeps --nosignature $container_out/rpms/aarch64/libfprint-tod-*.rpm >/dev/null && echo installed-libfprint-tod" ;;
  esac
}

rpmbuild_spec() {
  local spec=$1 name
  name=$(basename "$spec" .spec)
  if [ "${FORCE:-0}" != 1 ] && compgen -G "$out/rpms/*/${name}-[0-9]*.rpm" >/dev/null; then
    say "skip (already built): $name"
    install_built_deps "$name"
    return 0
  fi
  say "rpmbuild -bb $(basename "$spec")"
  user_exec "$container" rpmbuild -bb --define "_topdir $container_out/work" \
    --define "_sourcedir $container_out/work/SOURCES" \
    --define "_rpmdir $container_out/rpms" \
    --define "_srcrpmdir $container_out/SRPMS" \
    --define "_builddir $container_out/work/BUILD" \
    --define "_buildrootdir $container_out/work/BUILDROOT" \
    --define "debug_package %{nil}" \
    --define "jobs $jobs" \
    "/work/packaging/mobile/specs/$(basename "$spec")"
  install_built_deps "$name"
}

build_sensors() {
  ensure_container
  fetch_sources
  support_tarball
  for spec in libssc hexagonrpc iio-sensor-proxy liuqin-sensors-support; do
    rpmbuild_spec "$spec_dir/$spec.spec"
  done
  say "sensors RPMs built"
}

fetch_fingerprint_sources() {
  mkdir -p "$srccache" "$tarballs" "$work/SOURCES"
  say "fetching pinned fingerprint sources (fprintd 1.94.5 / QCBOR 1.6.1 / qsee-supplicant 0.1.1)"
  local entries=(
    "fprintd|1.94.5|https://gitlab.freedesktop.org/libfprint/fprintd.git|b54a007ccf58ac0ae074c7151b223f35cbd17306"
    "qcbor|1.6.1|https://github.com/laurencelundblade/QCBOR.git|930708bb86481e88879eb1d87fd4d664f1d69503"
    "qsee-supplicant|0.1.1|https://github.com/wrobelda/qsee-supplicant.git|36e06680cf7f690fccbdcd07abc2a64c4bb061d8"
  )
  local entry component version repository commit dir tarfile
  for entry in "${entries[@]}"; do
    IFS='|' read -r component version repository commit <<<"$entry"
    dir=$srccache/$component
    if [ ! -d "$dir/.git" ]; then
      git clone -q --filter=blob:none "$repository" "$dir" || die "clone failed: $component"
    fi
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$dir" fetch -q origin "$commit"
    git -C "$dir" checkout -q --detach "$commit"
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$component commit mismatch"
    local prefix=$component
    [ "$component" = fprintd ] && prefix=fprintd-oem
    tarfile=$tarballs/$prefix-$version.tar.gz
    if [ ! -f "$tarfile" ]; then
      say "creating deterministic tarball $prefix-$version"
      git -C "$dir" archive --format=tar --prefix="$prefix-$version/" "$commit" | gzip -n -9 >"$tarfile"
    fi
    cp "$tarfile" "$work/SOURCES/"
  done
  # verify the pinned fprintd vendor hashes used by prepare.py
  python3 - "$srccache/fprintd" "$project_root/packaging/mobile/fingerprint/FPRINTD_SOURCE_HASHES.json" <<'PYHASH'
import hashlib, json, pathlib, sys
base, ref = pathlib.Path(sys.argv[1]), json.load(open(sys.argv[2]))
for name, digest in ref.items():
    got = hashlib.sha256((base / name).read_bytes()).hexdigest()
    if got != digest:
        raise SystemExit('fprintd source hash mismatch: ' + name)
print('fprintd source hashes verified:', len(ref), 'files')
PYHASH
  cp "$project_root"/packaging/mobile/fingerprint/{oem-update.inc,prepare.py,FPRINTD_SOURCE_HASHES.json,fprintd-oem-update.patch} "$work/SOURCES/"
  cp "$project_root"/packaging/mobile/patches/fingerprint/*.patch "$work/SOURCES/"
}

fingerprint_support_tarball() {
  local stage=$work/fp-support-stage/liuqin-fingerprint-support-1.0
  rm -rf "$work/fp-support-stage"; mkdir -p "$work/fp-support-stage"
  python3 "$project_root/packaging/mobile/fingerprint/stage-payload.py" \
      "$fingerprint_root" "$stage" >/dev/null
  mkdir -p "$stage/src/oem"
  cp "$fingerprint_root/src/fingerprint/oem/qsee_gatekeeper.c"      "$fingerprint_root/src/fingerprint/oem/fpc_build_info.c"      "$fingerprint_root/src/fingerprint/oem/pam-input.c" "$stage/src/oem/"
  patch -d "$stage" -p1 < "$patch_dir/fingerprint/0004-fpc-check-lift-after-state-command.patch"
  cp "$upstream_root/LICENSE" "$stage/LICENSE"
  tar --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@$SOURCE_DATE_EPOCH" -C "$work/fp-support-stage" -czf \
      "$work/SOURCES/liuqin-fingerprint-support-1.0.tar.gz" liuqin-fingerprint-support-1.0
}

build_fingerprint() {
  ensure_container
  fetch_fingerprint_sources
  fingerprint_support_tarball
  for spec in qsee-supplicant fprintd-oem liuqin-fingerprint-support; do
    rpmbuild_spec "$spec_dir/$spec.spec"
  done
  say "fingerprint base RPMs built; run 'fingerprint-tod' for libfprint-tod + the FPC1264 adapter"
}

tod_source_fields() {
  # Prints "<source url> <orig sha256>" from the liuqin-locked SOURCE_LOCK.json.
  python3 - "$fingerprint_lock" <<'PYLOCK'
import json, sys
lock = json.load(open(sys.argv[1]))["libfprint"]
print(lock["source_url"], lock["orig_sha256"])
PYLOCK
}

fetch_tod_sources() {
  mkdir -p "$srccache" "$tarballs" "$work/SOURCES"
  local url sha tarball
  read -r url sha < <(tod_source_fields)
  tarball=$tarballs/$(basename "$url")
  if [ ! -f "$tarball" ]; then
    say "fetching locked libfprint TOD source (Ubuntu-maintained open source): $url"
    curl -fL --retry 3 --connect-timeout 20 -o "$tarball.part" "$url" \
      || die "TOD source download failed: $url"
    mv "$tarball.part" "$tarball"
  fi
  echo "$sha  $tarball" | sha256sum -c - >/dev/null \
    || die "TOD source sha256 mismatch: $tarball"
  cp "$tarball" "$work/SOURCES/"
  cp "$fingerprint_doc" "$work/SOURCES/"
  say "TOD source verified: $(basename "$tarball") sha256=$sha"
}

tod_adapter_tarball() {
  # Deterministic source tarball of the liuqin FPC1264 TOD adapter (the two C
  # files are upstream liuqin source, SPDX LGPL-2.1-or-later per file header).
  local stage=$work/tod-adapter-stage/liuqin-fpc1264-tod-1.0
  local src=$fingerprint_root/src/fingerprint/libfprint-tod
  local url tarball
  read -r url _ < <(tod_source_fields)
  tarball=$tarballs/$(basename "$url")
  rm -rf "$work/tod-adapter-stage"; mkdir -p "$stage"
  cp "$src/fpc1264-oem.c" "$src/fpc-oem-print.c" "$src/README.md" "$stage/"
  cp "$upstream_root/LICENSE" "$stage/LICENSE-MIT"
  cp "$fingerprint_lock" "$stage/SOURCE_LOCK.json"
  # The LIBFPRINT TOD tarball carries the LGPL-2.1 text the adapter files refer to.
  tar -xOjf "$tarball" --wildcards '*/COPYING' >"$stage/LICENSE-LGPL-2.1"
  {
    printf '# file\tsha256\n'
    (cd "$stage" && sha256sum fpc1264-oem.c fpc-oem-print.c README.md \
        LICENSE-MIT LICENSE-LGPL-2.1 SOURCE_LOCK.json)
  } >"$stage/SOURCE_MANIFEST"
  tar --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@$SOURCE_DATE_EPOCH" -C "$work/tod-adapter-stage" -czf \
      "$work/SOURCES/liuqin-fpc1264-tod-1.0.tar.gz" liuqin-fpc1264-tod-1.0
  say "adapter source tarball: liuqin-fpc1264-tod-1.0.tar.gz"
}

ensure_tod_build_deps() {
  # libfprint TOD additionally needs libgusb-devel + pixman-devel (glib2,
  # libgudev, systemd and openssl devel are already in container/install-deps.sh).
  if ! podman_exec "$container" rpm -q libgusb-devel pixman-devel >/dev/null 2>&1; then
    say "installing libfprint-tod build dependencies (libgusb-devel pixman-devel)"
    podman_exec "$container" dnf -y --setopt=install_weak_deps=False install libgusb-devel pixman-devel
  fi
}

build_fingerprint_tod() {
  ensure_container
  ensure_tod_build_deps
  fetch_tod_sources
  tod_adapter_tarball
  for spec in libfprint-tod liuqin-fpc1264-tod; do
    rpmbuild_spec "$spec_dir/$spec.spec"
  done
  say "fingerprint TOD RPMs built: libfprint-tod (+devel), liuqin-fpc1264-tod"
}

collect() {
  mkdir -p "$out"
  find "$out/rpms" -name '*.rpm' -type f -exec cp -f {} "$out/" \; 2>/dev/null || true
  createrepo_c --quiet --no-database "$out" >/dev/null 2>&1 || true
  (cd "$out" && find . -maxdepth 1 -name '*.rpm' -printf '%f\n' | sort | xargs -r sha256sum >SHA256SUMS)
  python3 - "$out" <<'PY'
import hashlib, json, pathlib, sys, datetime
out = pathlib.Path(sys.argv[1])
rpms = []
for f in sorted(out.glob('*.rpm')):
    rpms.append({'file': f.name, 'sha256': hashlib.sha256(f.read_bytes()).hexdigest(),
                 'size': f.stat().st_size})
info = {'built_at_utc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'target': 'fedora-44-aarch64', 'rpms': rpms}
(out / 'build-info.json').write_text(json.dumps(info, indent=2, ensure_ascii=False) + '\n')
print('wrote build-info.json with', len(rpms), 'RPMs')
PY
}

build_all() { fetch_sources; fetch_fingerprint_sources; build_sensors; build_fingerprint; build_fingerprint_tod; collect; }

case ${1:-all} in
  fetch) fetch_sources ;;
  sensors) build_sensors; collect ;;
  fingerprint-support) ensure_container; fetch_fingerprint_sources; fingerprint_support_tarball; rpmbuild_spec "$spec_dir/liuqin-fingerprint-support.spec"; collect ;;
  fingerprint-fprintd) ensure_container; fetch_fingerprint_sources; rpmbuild_spec "$spec_dir/fprintd-oem.spec"; collect ;;
  fingerprint) build_fingerprint; collect ;;
  fingerprint-tod) build_fingerprint_tod; collect ;;
  all) build_all ;;
  verify) "$project_root/packaging/mobile/verify-mobile-rpms.sh" ;;
  *) die "unknown action: $1" ;;
esac
