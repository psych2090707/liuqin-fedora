#!/bin/bash
# Idempotent build-dependency install inside the arm64 Fedora 45 container.
set -euo pipefail
marker=/opt/liuqin-mobile-build.deps-v1
if [ -f "$marker" ]; then echo "deps already installed ($marker)"; exit 0; fi
dnf -y --setopt=install_weak_deps=False install \
    rpm-build rpmdevtools createrepo_c \
    gcc gcc-c++ meson ninja-build pkgconf-pkg-config make patch tar gzip git \
    which findutils diffutils \
    glib2-devel libgudev-devel systemd-devel polkit-devel \
    libqmi-devel protobuf-c-devel qrtr-devel libqrtr-glib-devel json-c-devel \
    openssl-devel pam-devel dbus-devel python3 python3-devel libfprint-devel gettext \
    glibc-static kernel-headers systemd
touch "$marker"
