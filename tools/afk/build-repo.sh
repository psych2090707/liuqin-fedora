#!/bin/bash
# AFK channel (TN0048) — build an offline aarch64 RPM repo for the tablet.
#
# The tablet has no Wi-Fi firmware and the delivery rootfs has no dnf, so the
# only way to add packages is over the USB link.  This script prepares:
#
#   out/afk/repo/            valid dnf repo (rpms + repodata/) to serve over HTTP
#   out/afk/repo/rpms/       the same RPMs (tar'd by install-overlay.sh --rpms)
#   out/afk/repo/afk-rpms.tar.gz   offline bundle for `rpm -Uvh` / scp
#   out/afk/repo/MANIFEST.txt      resolved package set + source repos + date
#
# How the dependency resolution stays honest: the download runs in a Fedora 44
# **aarch64** container (the project already has localhost/liuqin-rpmbuild:fc44)
# with `--installroot` pointing at a copy of the *device rootfs' rpmdb*.  dnf5
# therefore considers everything already on the tablet as installed and only
# downloads the missing closure (krdp: 15 RPM / ~5 MB instead of a whole Qt
# stack).
#
# Needs: podman (rootful via sudo), network (FlClash proxy env is honoured),
# and a copy of the device rootfs tree (out/tn0045-rootfs-*/rootfs).
set -euo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

OUT="$AFK_STATE_DIR/repo"
ROOTFS=""
IMAGE="${AFK_REPO_IMAGE:-localhost/liuqin-rpmbuild:fc44}"
FALLBACK_IMAGE="${AFK_REPO_FALLBACK_IMAGE:-quay.io/fedora/fedora:44}"
WITH_EXTRA=0
KEEP_WORK=0

# Fedora 44 mirrors (override for a local mirror or a snapshot).
OS_REPO="${AFK_OS_REPO:-https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/os/}"
UPD_REPO="${AFK_UPD_REPO:-https://dl.fedoraproject.org/pub/fedora/linux/updates/44/Everything/aarch64/}"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:?}"; shift 2 ;;
        --out=*) OUT="${1#*=}"; shift ;;
        --rootfs) ROOTFS="${2:?}"; shift 2 ;;
        --rootfs=*) ROOTFS="${1#*=}"; shift ;;
        --image) IMAGE="${2:?}"; shift 2 ;;
        --image=*) IMAGE="${1#*=}"; shift ;;
        --with-extra) WITH_EXTRA=1; shift ;;
        --keep-work) KEEP_WORK=1; shift ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_cmd podman "rootful podman is required to run the Fedora 44 downloader"

# ------------------------------------------------------------------ rootfs ----
if [ -z "$ROOTFS" ]; then
    # Newest device rootfs tree that has an rpmdb (out/ is git-ignored).
    ROOTFS="$(ls -1dt "$AFK_ROOT"/out/tn0045-rootfs-*/rootfs 2>/dev/null | head -n1 || true)"
fi
[ -n "$ROOTFS" ] || die "no device rootfs found; pass --rootfs PATH (needs usr/lib/sysimage/rpm/rpmdb.sqlite)"
[ -f "$ROOTFS/usr/lib/sysimage/rpm/rpmdb.sqlite" ] || \
    die "$ROOTFS does not look like a Fedora rootfs (no rpmdb)"
say "device rootfs (installed-package source): $ROOTFS"

# --------------------------------------------------------------- podman/sudo ---
SUDO=""
if [ "$(id -u)" != 0 ]; then
    if have_passwordless_sudo; then
        SUDO="sudo -n"
    else
        die "podman runs rootful here; run as root or enable passwordless sudo"
    fi
fi
as_root() { if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi; }

image_present() {
    as_root podman image exists "$1" >/dev/null 2>&1
}

if image_present "$IMAGE"; then
    say "using container image: $IMAGE"
elif image_present "$FALLBACK_IMAGE"; then
    warn "preferred image $IMAGE not present, using $FALLBACK_IMAGE (will install createrepo_c)"
    IMAGE="$FALLBACK_IMAGE"
else
    say "pulling $FALLBACK_IMAGE"
    as_root podman pull "$FALLBACK_IMAGE" || die "could not pull a Fedora 44 aarch64 image"
    IMAGE="$FALLBACK_IMAGE"
fi

# ---------------------------------------------------------------------- work ---
mkdir -p "$OUT/rpms"
work="$(mktemp -d "${TMPDIR:-/tmp}/afk-repo.XXXXXX")"
cleanup() {
    if [ "$KEEP_WORK" = 1 ]; then
        note "kept build work dir: $work"
    elif [ -n "${SUDO:-}" ]; then
        # dnf5 inside the container wrote root-owned files under the installroot.
        as_root rm -rf -- "$work" 2>/dev/null || warn "could not remove $work (root-owned leftovers?)"
    else
        rm -rf -- "$work"
    fi
}
trap cleanup EXIT

instroot="$work/instroot"
mkdir -p "$instroot/etc" "$instroot/usr/lib/sysimage"
cp -a "$ROOTFS/etc/os-release" "$instroot/etc/" 2>/dev/null || true
cp -a "$ROOTFS/etc/fedora-release" "$instroot/etc/" 2>/dev/null || true
say "copying the device rpmdb as dnf --installroot (67 MB)"
cp -a "$ROOTFS/usr/lib/sysimage/rpm" "$instroot/usr/lib/sysimage/rpm"
chmod -R u+rwX "$instroot" 2>/dev/null || true

pkg_list="$(grep -v '^[[:space:]]*#' "$TOOLS_DIR/packages.txt" | grep -v '^[[:space:]]*$' | tr '\n' ' ')"
if [ "$WITH_EXTRA" = 1 ] && [ -f "$TOOLS_DIR/packages-extra.txt" ]; then
    pkg_list="$pkg_list $(grep -v '^[[:space:]]*#' "$TOOLS_DIR/packages-extra.txt" | grep -v '^[[:space:]]*$' | tr '\n' ' ')"
fi
say "packages: $pkg_list"

# Keep the operator's proxy environment (FlClash: 127.0.0.1:7890) for the container.
proxy_env=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [ -n "${!v:-}" ]; then
        proxy_env+=(-e "$v=${!v}")
        # 127.0.0.1 inside the container is the container itself; with
        # --network=host the proxy is reachable as-is, so nothing to rewrite.
    fi
done

say "downloading the missing aarch64 closure (container: $IMAGE)"
as_root podman run --rm --network=host \
    "${proxy_env[@]}" \
    -v "$instroot:/instroot:rw" \
    -v "$OUT:/out:rw" \
    "$IMAGE" bash -euc '
        export PATH=/usr/bin:/usr/sbin:/bin:/sbin
        dnf5 --installroot=/instroot --releasever=44 --forcearch=aarch64 \
             --repofrompath=os,'"$OS_REPO"' \
             --repofrompath=updates,'"$UPD_REPO"' \
             --setopt=reposdir=/dev/null \
             --setopt=os.gpgcheck=0 --setopt=updates.gpgcheck=0 \
             --setopt=install_weak_deps=False \
             --setopt=keepcache=0 \
             --setopt=cachedir=/var/tmp/dnfcache \
             download --resolve --destdir=/out/rpms '"$pkg_list"' \
          || { echo "INFO: dnf5 download failed, retrying with explicit dnf5-plugins install" >&2;
               dnf5 install -y dnf5-plugins >/dev/null 2>&1 || true;
               dnf5 --installroot=/instroot --releasever=44 --forcearch=aarch64 \
                 --repofrompath=os,'"$OS_REPO"' \
                 --repofrompath=updates,'"$UPD_REPO"' \
                 --setopt=reposdir=/dev/null \
                 --setopt=os.gpgcheck=0 --setopt=updates.gpgcheck=0 \
                 --setopt=install_weak_deps=False --setopt=keepcache=0 \
                 --setopt=cachedir=/var/tmp/dnfcache \
                 download --resolve --destdir=/out/rpms '"$pkg_list"'; }
        if ! command -v createrepo_c >/dev/null 2>&1; then
            echo "installing createrepo_c in the container" >&2
            dnf5 install -y createrepo_c >/dev/null
        fi
        createrepo_c --no-database --checksum sha256 --general-compress-type gz \
                     --outputdir /out/rpms /out/rpms >/dev/null

        # Prove the generated repo is consumable: dnf5 must see the packages and
        # must be able to depsolve a full install transaction against the
        # device-like installroot.  --assumeno stops before touching anything
        # (and exits non-zero, which is expected); we look for the summary line.
        echo "container: validating generated repo" >&2
        dnf5 --installroot=/instroot --releasever=44 --forcearch=aarch64 \
             --repofrompath=afk,file:///out/rpms \
             --setopt=reposdir=/dev/null --setopt=afk.gpgcheck=0 \
             --setopt=install_weak_deps=False --setopt=cachedir=/var/tmp/dnfcache2 \
             repoquery --available --qf '%{name}-%{evr}.%{arch}\n' '"$pkg_list"' \
             > /out/.repoquery.txt 2>/out/.repoquery.err \
          || { echo "container: ERROR repoquery failed" >&2; cat /out/.repoquery.err >&2; exit 1; }
        dnf5 --installroot=/instroot --releasever=44 --forcearch=aarch64 \
             --repofrompath=afk,file:///out/rpms \
             --setopt=reposdir=/dev/null --setopt=afk.gpgcheck=0 \
             --setopt=install_weak_deps=False --setopt=cachedir=/var/tmp/dnfcache2 \
             install --assumeno '"$pkg_list"' > /out/.depsolve.txt 2>&1 || true
        if grep -q "Transaction Summary" /out/.depsolve.txt; then
            echo "container: depsolve OK" >&2
        else
            echo "container: ERROR depsolve failed against the generated repo" >&2
            tail -n 20 /out/.depsolve.txt >&2
            exit 1
        fi
        echo "container: done"
    '

# RPMs are written by root inside the container; hand them back to the caller.
if [ -n "$SUDO" ]; then
    as_root chown -R "$(id -u):$(id -g)" "$OUT"
fi

# ----------------------------------------------------------------- manifest ---
count="$(find "$OUT/rpms" -maxdepth 1 -name '*.rpm' | wc -l)"
[ "$count" -gt 0 ] || die "no RPMs were downloaded; check the dnf5 output above"
{
    echo "# AFK offline aarch64 RPM repo (TN0048)"
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
    echo "container_image=$IMAGE"
    echo "device_rootfs=$ROOTFS"
    echo "fedora_release=44"
    echo "os_repo=$OS_REPO"
    echo "updates_repo=$UPD_REPO"
    echo "package_count=$count"
    echo
    echo "# resolved packages"
    find "$OUT/rpms" -maxdepth 1 -name '*.rpm' -printf '%f\n' | sort
    if [ -s "$OUT/.repoquery.txt" ]; then
        echo
        echo "# repoquery view of the same set (dnf5 read back the generated repodata)"
        sort "$OUT/.repoquery.txt"
    fi
} >"$OUT/MANIFEST.txt"

rm -f "$OUT/.repoquery.txt" "$OUT/.repoquery.err" "$OUT/.depsolve.txt"
tar -czf "$OUT/afk-rpms.tar.gz" -C "$OUT/rpms" .
( cd "$OUT/rpms" && sha256sum ./*.rpm >"$OUT/SHA256SUMS" )

say ""
ok "repo ready: $OUT"
say "  packages: $count ($(du -sh "$OUT/rpms" | cut -f1))"
say "  serve:    tools/afk/afk.sh repo serve"
say "  install:  tools/afk/install-overlay.sh --rpms"
say ""
say "device-side dnf (once dnf5 is installed):"
say "  dnf5 --repofrompath=afk,http://$AFK_HOST_IP:$AFK_REPO_PORT/ --setopt=afk.gpgcheck=0 install <pkg>"
