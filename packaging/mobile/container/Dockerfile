# Build environment for liuqin mobile userspace RPMs (aarch64, Fedora 45)
# Runs natively under qemu-user binfmt on x86_64 hosts.
FROM registry.fedoraproject.org/fedora:45
ARG http_proxy
ARG https_proxy
ENV http_proxy=${http_proxy} https_proxy=${https_proxy}
RUN dnf -y install --setopt=install_weak_deps=False \
        rpm-build rpmdevtools createrepo_c \
        gcc gcc-c++ meson ninja-build pkgconf-pkg-config make patch tar gzip git \
        glib2-devel gudev1-devel systemd-devel polkit-devel \
        libqmi-devel protobuf-c-devel qrtr-devel json-c-devel \
        openssl-devel pam-devel dbus-devel \
        python3 python3-devel \
    && dnf clean all
ENV LC_ALL=C.UTF-8
WORKDIR /build
