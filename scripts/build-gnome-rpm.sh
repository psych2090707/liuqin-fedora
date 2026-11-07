#!/bin/bash
# Build only the noarch GNOME integration RPM using the existing Fedora builder.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/out/tn0083-gnome-independent/rpmbuild"}
mkdir -p "$out"
out=$(realpath "$out")
stage=$out/SOURCES/liuqin-gnome-support-1.0
[ ! -e "$stage" ] || { echo "stage exists: $stage; choose a new output" >&2; exit 1; }
mkdir -p "$stage/payload" "$out/SPECS"
cp -a "$root/overlays/gnome/etc" "$root/overlays/gnome/usr" "$stage/payload/"
# Preserve the original builder's installed modes regardless of checkout modes.
install -m0644 "$root/overlays/gnome/etc/systemd/logind.conf.d/96-liuqin-gnome-lid.conf" \
    "$stage/payload/etc/systemd/logind.conf.d/96-liuqin-gnome-lid.conf"
install -m0644 "$root/overlays/gnome/etc/dconf/db/local.d/20-liuqin-gnome-input" \
    "$stage/payload/etc/dconf/db/local.d/20-liuqin-gnome-input"
install -m0644 "$root/overlays/gnome/etc/dconf/db/local.d/10-liuqin-gnome-power" \
    "$stage/payload/etc/dconf/db/local.d/10-liuqin-gnome-power"
install -m0755 "$root/overlays/gnome/usr/libexec/liuqin/gnome-power-key-action" \
    "$stage/payload/usr/libexec/liuqin/gnome-power-key-action"
cp "$root/LICENSE" "$stage/LICENSE"
cp "$root/packaging/gnome/README.md" "$stage/README.md"
cp "$root/packaging/gnome/liuqin-gnome-support.spec" "$out/SPECS/"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@1793145600 \
    -czf "$out/SOURCES/liuqin-gnome-support-1.0.tar.gz" -C "$out/SOURCES" liuqin-gnome-support-1.0
sudo -n podman run --rm --network=none --security-opt label=disable \
    -v "$out:/build" localhost/liuqin-rpmbuild:fc45 \
    rpmbuild -bb --define '_topdir /build' /build/SPECS/liuqin-gnome-support.spec
