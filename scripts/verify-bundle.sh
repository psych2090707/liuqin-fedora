#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# verify-bundle.sh — offline structure verifier for liuqin (Xiaomi Pad 6 Pro)
# Fedora ARM64 build artifacts.
#
# Verifies ONLY artifact structure and bookkeeping. It never touches a device:
# no fastboot, no boot-partition write, no /dev block device. It is read-only
# with respect to the artifacts it inspects; it writes only its JSON report.
#
# Checks:
#   boot.img      Android boot image v2: magic, header v2, page size, load
#                 addresses, empty header cmdline (ABL supplies /chosen), payload
#                 sizes, < 192 MiB partition, dtb present, payload hashes.
#   dtb           FDT magic, size, ABL board identity (qcom,msm-id /
#                 qcom,board-id / xiaomi,miboard-id), /chosen bootargs,
#                 overlay-sink symbols.
#   initramfs     gzip/newc cpio, /init + BusyBox, metadata/hash agreement,
#                 firmware staging state.
#   metadata      build-info.json vs the actual boot.img, Image.gz and DTB;
#                 kernel source lock agreement (kernel/source.json).
#   checksums     SHA256SUMS files vs actual files (boot/ and initramfs/).
#   rootfs        Fedora /etc/os-release + release, package list (rootfs.packages.txt
#                 or rpmdb), key packages, systemd units, GNOME/KDE session + login
#                 manager, /etc/fstab labels (LABEL=LIUQIN_ROOT/HOME + growfs),
#                 aarch64-only ELF scan (no x86_64), no Ubuntu leftovers, no
#                 device-private/persist data, firmware redistribution markers.
#   bundle        bundle.json <-> SHA256SUMS <-> files consistency (upstream
#                 reference cache and future own bundles), kernel_commit vs lock.
#   repo          NOTICE/LICENSE, firmware-clause present, upstream pins,
#                 kernel/source.json, ADR-0002 target-release consistency.
#
# Output: human-readable PASS/FAIL/WARN/SKIP summary + one machine-readable JSON
# report (default: out/ci/verify-bundle-<UTC>.json).
#
# Exit codes: 0 = no FAIL (WARN allowed); 1 = at least one FAIL; 2 = usage error.
#
# Usage: scripts/verify-bundle.sh [options]
#   --boot PATH            boot.img (default: out/boot/boot-liuqin-dev.img)
#   --initramfs PATH       default: out/boot/initramfs/liuqin-firstboot.cpio.gz
#   --dtb PATH             default: out/boot/liuqin-abl-boot.dtb
#   --boot-metadata PATH   default: out/boot/build-info.json
#   --rootfs DIR           rootfs tree (default: auto: out/rootfs/rootfs, then
#                          out/env-smoke/mkosi-smoke/out/image)
#   --rootfs-profile P     auto|full|minimal (default: auto = detect GNOME or KDE)
#   --expected-release N   auto|44|45 (default: auto -> from rootfs os-release)
#   --bundle DIR           bundle directory with bundle.json
#                          (default: cache/upstream-v0.6.0 if present)
#   --bundle-partial       missing bundle files are WARN, not FAIL
#   --repo-root DIR        project root (default: parent of this script)
#   --json PATH            JSON report path (default: out/ci/verify-bundle-<ts>.json)
#   --json-only            print only the JSON report to stdout
#   --quiet                no human summary (JSON still written)
#   --no-boot|--no-rootfs|--no-bundle|--no-repo   skip a section
#   --fail-on-warn         treat WARN as failure
#   --release-gate         release gate: dev-only artifacts FAIL instead of WARN
#                          (device_ready, canonical stock-rom DTB, Fedora kernel
#                          SELinux, real contract, kernel release chain, login
#                          manager, flat layout, kernel RPM payload,
#                          no kernel-identity contract pins, docs sha,
#                          DSP firmware + AudioReach topology in the initramfs)
#   --docs-sha             run only the docs<->artifact sha256 consistency check
#   --advisory             exit 0 even when FAIL (report still says FAIL)
#   --no-color
#   -h, --help

set -uo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
JSON_OUT=""
JSON_ONLY=0
QUIET=0
FAIL_ON_WARN=0
ADVISORY=0
NO_COLOR=0
RELEASE_GATE=0
DOCS_SHA_ONLY=0
SKIP_BOOT=0
SKIP_ROOTFS=0
SKIP_BUNDLE=0
SKIP_REPO=0
BOOT_ARG=""
INITRAMFS_ARG=""
DTB_ARG=""
META_ARG=""
ROOTFS_ARG=""
PROFILE="auto"
EXPECTED_RELEASE="auto"
BUNDLE_ARG=""
BUNDLE_PARTIAL=0
BUNDLE_EXPLICIT=0

usage() { sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die() { printf 'verify-bundle: error: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --boot) BOOT_ARG=${2:?--boot needs a path}; shift 2 ;;
        --initramfs) INITRAMFS_ARG=${2:?--initramfs needs a path}; shift 2 ;;
        --dtb) DTB_ARG=${2:?--dtb needs a path}; shift 2 ;;
        --boot-metadata) META_ARG=${2:?--boot-metadata needs a path}; shift 2 ;;
        --rootfs) ROOTFS_ARG=${2:?--rootfs needs a directory}; shift 2 ;;
        --rootfs-profile) PROFILE=${2:?}; shift 2 ;;
        --expected-release) EXPECTED_RELEASE=${2:?}; shift 2 ;;
        --bundle) BUNDLE_ARG=${2:?--bundle needs a directory}; BUNDLE_EXPLICIT=1; shift 2 ;;
        --bundle-partial) BUNDLE_PARTIAL=1; shift ;;
        --repo-root) PROJECT_ROOT=${2:?--repo-root needs a path}; shift 2 ;;
        --json) JSON_OUT=${2:?--json needs a path}; shift 2 ;;
        --json-only) JSON_ONLY=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --no-boot) SKIP_BOOT=1; shift ;;
        --no-rootfs) SKIP_ROOTFS=1; shift ;;
        --no-bundle) SKIP_BUNDLE=1; shift ;;
        --no-repo) SKIP_REPO=1; shift ;;
        --fail-on-warn) FAIL_ON_WARN=1; shift ;;
        --advisory) ADVISORY=1; shift ;;
        --release-gate) RELEASE_GATE=1; shift ;;
        --docs-sha) DOCS_SHA_ONLY=1; shift ;;
        --no-color) NO_COLOR=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

case "$PROFILE" in auto|full|minimal) ;; *) die "--rootfs-profile must be auto|full|minimal" ;; esac
case "$EXPECTED_RELEASE" in auto|''|*[!0-9]*) [ "$EXPECTED_RELEASE" = auto ] || die "--expected-release must be auto or a number" ;; *) ;; esac

if [ "$RELEASE_GATE" -eq 1 ] && [ "$BUNDLE_EXPLICIT" -eq 0 ] && [ "$SKIP_BUNDLE" -eq 0 ]; then
    # release gate: prefer the newest assembled bundle under images/
    newest_bundle=$(ls -dt "$PROJECT_ROOT"/images/*/bundle.json 2>/dev/null | head -1)
    if [ -n "$newest_bundle" ]; then
        BUNDLE_ARG=$(dirname -- "$newest_bundle")
        BUNDLE_EXPLICIT=1
    fi
fi
if [ -z "$BUNDLE_ARG" ]; then
    for c in "$PROJECT_ROOT/out/bundle" "$PROJECT_ROOT/cache/upstream-v0.6.0"; do
        if [ -f "$c/bundle.json" ] || [ -f "$c/SHA256SUMS" ]; then BUNDLE_ARG=$c; break; fi
    done
fi

# ---------------------------------------------------------------- autodetect --
# When a bundle is explicitly selected, the delivery artifacts
# INSIDE that bundle are the verification subject.  Never fall back to unrelated
# out/boot / out/rootfs trees (those are stale historical artifacts).
BUNDLE_FIRST=0
if [ "$BUNDLE_EXPLICIT" -eq 1 ] && [ -n "$BUNDLE_ARG" ] && [ -f "$BUNDLE_ARG/bundle.json" ]; then
    BUNDLE_FIRST=1
fi
if [ "$BUNDLE_FIRST" -eq 1 ]; then
    if [ -z "$BOOT_ARG" ] && [ -f "$BUNDLE_ARG/boot.img" ]; then
        BOOT_ARG="$BUNDLE_ARG/boot.img"
    fi
    if [ -z "$META_ARG" ] && [ -f "$BUNDLE_ARG/manifests/boot-build-info.json" ]; then
        META_ARG="$BUNDLE_ARG/manifests/boot-build-info.json"
    fi
    if [ -z "$ROOTFS_ARG" ]; then
        for c in "$PROJECT_ROOT/out/image-build/$(basename -- "$BUNDLE_ARG")/rootfs/root"; do
            [ -d "$c" ] && ROOTFS_ARG=$c
        done
    fi
fi
if [ "$BUNDLE_FIRST" -eq 0 ] && [ -z "$BOOT_ARG" ]; then
    for c in "$PROJECT_ROOT/out/boot/boot-liuqin-dev.img" "$PROJECT_ROOT"/out/boot/boot-*.img; do
        [ -f "$c" ] && { BOOT_ARG=$c; break; }
    done
fi
if [ "$BUNDLE_FIRST" -eq 0 ] && [ -z "$INITRAMFS_ARG" ] && [ -n "$BOOT_ARG" ]; then
    cand=$(dirname -- "$BOOT_ARG")/initramfs/liuqin-firstboot.cpio.gz
    [ -f "$cand" ] && INITRAMFS_ARG=$cand
fi
if [ "$BUNDLE_FIRST" -eq 0 ] && [ -z "$INITRAMFS_ARG" ] && [ -f "$PROJECT_ROOT/out/boot/initramfs/liuqin-firstboot.cpio.gz" ]; then
    INITRAMFS_ARG="$PROJECT_ROOT/out/boot/initramfs/liuqin-firstboot.cpio.gz"
fi
if [ "$BUNDLE_FIRST" -eq 0 ] && [ -z "$DTB_ARG" ]; then
    for c in "$PROJECT_ROOT/out/boot/liuqin-abl-boot.dtb" "$(dirname -- "${BOOT_ARG:-/nonexistent}")/liuqin-abl-boot.dtb"; do
        [ -f "$c" ] && { DTB_ARG=$c; break; }
    done
fi
if [ "$BUNDLE_FIRST" -eq 0 ] && [ -z "$META_ARG" ] && [ -n "$BOOT_ARG" ]; then
    cand=$(dirname -- "$BOOT_ARG")/build-info.json
    [ -f "$cand" ] && META_ARG=$cand
fi
if [ "$BUNDLE_FIRST" -eq 0 ] && [ -z "$ROOTFS_ARG" ]; then
    for c in "$PROJECT_ROOT/out/rootfs/rootfs" "$PROJECT_ROOT/out/env-smoke/mkosi-smoke/out/image"; do
        [ -d "$c" ] && { ROOTFS_ARG=$c; break; }
    done
fi

if [ "$DOCS_SHA_ONLY" -eq 1 ]; then
    SKIP_BOOT=1; SKIP_ROOTFS=1; SKIP_BUNDLE=1; SKIP_REPO=1
fi
if [ "$BUNDLE_EXPLICIT" -eq 0 ] && [ -n "$BUNDLE_ARG" ] && [ "$(basename -- "$BUNDLE_ARG")" = "upstream-v0.6.0" ]; then
    # The upstream v0.6.0 release cache is intentionally partial (only the files
    # this project needed were downloaded). Missing files are WARN, not FAIL.
    BUNDLE_PARTIAL=1
fi

if [ -z "$JSON_OUT" ]; then
    JSON_OUT="$PROJECT_ROOT/out/ci/verify-bundle-$TIMESTAMP.json"
fi
mkdir -p -- "$(dirname -- "$JSON_OUT")" || die "cannot create report directory for $JSON_OUT"

export VB_PROJECT="$PROJECT_ROOT"
export VB_BOOT="$BOOT_ARG" VB_INITRAMFS="$INITRAMFS_ARG" VB_DTB="$DTB_ARG" VB_META="$META_ARG"
export VB_ROOTFS="$ROOTFS_ARG" VB_PROFILE="$PROFILE" VB_EXPECTED_RELEASE="$EXPECTED_RELEASE"
export VB_BUNDLE="$BUNDLE_ARG" VB_BUNDLE_PARTIAL="$BUNDLE_PARTIAL" VB_BUNDLE_EXPLICIT="$BUNDLE_EXPLICIT"
export VB_JSON="$JSON_OUT" VB_JSON_ONLY="$JSON_ONLY" VB_QUIET="$QUIET"
export VB_FAIL_ON_WARN="$FAIL_ON_WARN" VB_ADVISORY="$ADVISORY" VB_NO_COLOR="$NO_COLOR"
export VB_RELEASE_GATE="$RELEASE_GATE" VB_DOCS_SHA_ONLY="$DOCS_SHA_ONLY"
export VB_SKIP_BOOT="$SKIP_BOOT" VB_SKIP_ROOTFS="$SKIP_ROOTFS" VB_SKIP_BUNDLE="$SKIP_BUNDLE" VB_SKIP_REPO="$SKIP_REPO"
export VB_TIMESTAMP="$TIMESTAMP"

python3 - <<'PY'
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

E = os.environ
PROJECT = Path(E["VB_PROJECT"])
BOOT = Path(E["VB_BOOT"]) if E["VB_BOOT"] else None
INITRAMFS = Path(E["VB_INITRAMFS"]) if E["VB_INITRAMFS"] else None
DTB = Path(E["VB_DTB"]) if E["VB_DTB"] else None
META = Path(E["VB_META"]) if E["VB_META"] else None
ROOTFS = Path(E["VB_ROOTFS"]) if E["VB_ROOTFS"] else None
BUNDLE = Path(E["VB_BUNDLE"]) if E["VB_BUNDLE"] else None
JSON_OUT = Path(E["VB_JSON"])
PROFILE = E["VB_PROFILE"]
EXPECTED_RELEASE = E["VB_EXPECTED_RELEASE"]
BUNDLE_PARTIAL = E["VB_BUNDLE_PARTIAL"] == "1"
QUIET = E["VB_QUIET"] == "1"
JSON_ONLY = E["VB_JSON_ONLY"] == "1"
FAIL_ON_WARN = E["VB_FAIL_ON_WARN"] == "1"
ADVISORY = E["VB_ADVISORY"] == "1"
COLOR = sys.stdout.isatty() and E["VB_NO_COLOR"] != "1"

RELEASES = ("44", "45")
checks = []
CATEGORIES = {}


def add(cid, category, status, detail, path=None, extra=None):
    assert status in ("PASS", "FAIL", "WARN", "SKIP")
    item = {"id": cid, "category": category, "status": status, "detail": detail}
    if path is not None:
        item["path"] = str(path)
    if extra:
        item["extra"] = extra
    checks.append(item)
    CATEGORIES[category] = CATEGORIES.get(category, 0) + 1
    return item


def sha256(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except Exception as exc:  # noqa: BLE001
        return None


def exists(p, what):
    if p is None:
        add(f"{what}.auto", what, "SKIP", "not auto-detected (pass an explicit path to check)")
        return False
    if not p.exists():
        add(f"{what}.exists", what, "FAIL", f"missing: {p}", path=p)
        return False
    add(f"{what}.exists", what, "PASS", str(p), path=p)
    return True


# ---------------------------------------------------------------- boot image --
BOOT_INFO = None
BOOT_PAYLOAD = {}


def find_unpacker():
    cands = [
        PROJECT / "cache/upstream-v0.6.0/mkbootimg/unpack_bootimg.py",
        PROJECT / "tools/local/aosp-mkbootimg/unpack_bootimg.py",
        PROJECT / "cache/upstream-v0.6.0/mkbootimg/unpack_bootimg",
    ]
    for c in cands:
        if c.is_file():
            return c
    w = shutil.which("unpack_bootimg.py") or shutil.which("unpack_bootimg")
    return Path(w) if w else None


def parse_boot_builtin(path):
    """Minimal Android boot v2 parser.

    Offsets below were validated byte-for-byte against the AOSP
    unpack_bootimg.py output for out/boot/boot-liuqin-dev.img
    (header v2, 1660-byte header, page size 4096):
        8 kernel_size, 12 kernel_addr, 16 ramdisk_size, 20 ramdisk_addr,
        24 second_size, 28 second_addr, 32 tags_addr, 36 page_size,
        40 header_version, 44 cmdline[576], 620 id[48]? -> v2 tail:
        1644 header_size, 1648 dtb_size, 1652 dtb_addr.
    """
    data = path.read_bytes()
    hdr = data[:2048]
    if hdr[:8] != b"ANDROID!":
        return None
    info = {
        "magic": "ANDROID!",
        "kernel_size": struct.unpack_from("<I", hdr, 8)[0],
        "kernel_addr": struct.unpack_from("<I", hdr, 12)[0],
        "ramdisk_size": struct.unpack_from("<I", hdr, 16)[0],
        "ramdisk_addr": struct.unpack_from("<I", hdr, 20)[0],
        "second_size": struct.unpack_from("<I", hdr, 24)[0],
        "second_addr": struct.unpack_from("<I", hdr, 28)[0],
        "tags_addr": struct.unpack_from("<I", hdr, 32)[0],
        "page_size": struct.unpack_from("<I", hdr, 36)[0],
        "header_version": struct.unpack_from("<I", hdr, 40)[0],
        "cmdline": hdr[44:44 + 512].split(b"\x00", 1)[0].decode("utf-8", "replace"),
        "header_size": struct.unpack_from("<I", hdr, 1644)[0],
        "dtb_size": struct.unpack_from("<I", hdr, 1648)[0],
        "dtb_addr": struct.unpack_from("<Q", hdr, 1652)[0],
        "total_bytes": len(data),
    }
    ps = info["page_size"] or 4096

    def align(n):
        return (n + ps - 1) // ps * ps

    off = ps
    k_size = info["kernel_size"]
    if k_size and off + k_size <= len(data):
        BOOT_PAYLOAD["kernel"] = data[off:off + k_size]
    off += align(k_size)
    r_size = info["ramdisk_size"]
    if r_size and off + r_size <= len(data):
        BOOT_PAYLOAD["ramdisk"] = data[off:off + r_size]
    off += align(r_size)
    s_size = info["second_size"]
    off += align(s_size)
    d_size = info["dtb_size"]
    if d_size and off + d_size <= len(data):
        BOOT_PAYLOAD["dtb"] = data[off:off + d_size]
    return info


def boot_ramdisk(path):
    """Return the raw ramdisk bytes of an Android boot v2 image."""
    data = path.read_bytes()
    hdr = data[:2048]
    if hdr[:8] != b"ANDROID!":
        raise ValueError(str(path) + " is not an Android boot image")
    page_size = struct.unpack_from("<I", hdr, 36)[0] or 4096
    kernel_size = struct.unpack_from("<I", hdr, 8)[0]
    ramdisk_size = struct.unpack_from("<I", hdr, 16)[0]

    def align(n):
        return (n + page_size - 1) // page_size * page_size

    offset = page_size + align(kernel_size)
    if offset + ramdisk_size > len(data):
        raise ValueError("ramdisk extends past the end of " + str(path))
    return data[offset:offset + ramdisk_size]


def cpio_members(cpio):
    """Return {name-without-leading-./: bytes} for every newc-cpio member."""
    members = {}
    pos = 0
    while cpio[pos:pos + 6] in (b"070701", b"070702"):
        fields = [int(cpio[pos + 6 + i * 8: pos + 14 + i * 8], 16) for i in range(13)]
        namesize = fields[11]
        filesize = fields[6]
        name = cpio[pos + 110: pos + 110 + namesize - 1].decode("utf-8", "replace")
        data_start = (pos + 110 + namesize + 3) // 4 * 4
        members[name.lstrip("./")] = cpio[data_start:data_start + filesize]
        pos = (data_start + filesize + 3) // 4 * 4
    return members


def cpio_member(cpio, wanted):
    """Return the bytes of one newc-cpio member (name without leading ./)."""
    wanted = wanted.lstrip("./")
    pos = 0
    while cpio[pos:pos + 6] in (b"070701", b"070702"):
        fields = [int(cpio[pos + 6 + i * 8: pos + 14 + i * 8], 16) for i in range(13)]
        namesize = fields[11]
        filesize = fields[6]
        name = cpio[pos + 110: pos + 110 + namesize - 1].decode("utf-8", "replace")
        data_start = (pos + 110 + namesize + 3) // 4 * 4
        if name.lstrip("./") == wanted:
            return cpio[data_start:data_start + filesize]
        pos = (data_start + filesize + 3) // 4 * 4
    return None


def load_boot():
    global BOOT_INFO
    if E["VB_SKIP_BOOT"] == "1" or not exists(BOOT, "boot"):
        if E["VB_SKIP_BOOT"] == "1":
            add("boot.skipped", "boot", "SKIP", "disabled by --no-boot")
        return
    assert BOOT is not None
    size = BOOT.stat().st_size
    add("boot.bytes", "boot", "PASS", f"{size} bytes", path=BOOT, extra={"bytes": size})
    # Prefer the pinned AOSP unpacker; fall back to the validated built-in parser.
    unpacker = find_unpacker()
    info = None
    if unpacker is not None:
        tmp = Path(tempfile.mkdtemp(prefix="verify-boot-"))
        r = run([sys.executable, str(unpacker), "--boot_img", str(BOOT), "--out", str(tmp), "--format", "info"])
        if r is not None and r.returncode == 0:
            info = parse_info_text(r.stdout)
            for name in ("kernel", "ramdisk", "dtb"):
                p = tmp / name
                if p.is_file() and p.stat().st_size > 0:
                    BOOT_PAYLOAD[name] = p.read_bytes()
            add("boot.unpacker", "boot", "PASS", f"unpack_bootimg.py: {unpacker}", path=unpacker)
        else:
            add("boot.unpacker", "boot", "WARN", "pinned unpack_bootimg.py failed; using built-in parser")
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        add("boot.unpacker", "boot", "WARN", "unpack_bootimg.py not found; using built-in parser")
    if info is None:
        info = parse_boot_builtin(BOOT)
    if not info:
        add("boot.magic", "boot", "FAIL", "missing ANDROID! magic", path=BOOT)
        return
    BOOT_INFO = info
    add("boot.magic", "boot", "PASS", "ANDROID!")
    add("boot.header_version", "boot",
        "PASS" if info.get("header_version") == 2 else "FAIL",
        f"header v{info.get('header_version')} (expected v2)",
        extra={"header_version": info.get("header_version")})
    add("boot.page_size", "boot",
        "PASS" if info.get("page_size") == 4096 else "FAIL",
        f"page size {info.get('page_size')} (expected 4096)",
        extra={"page_size": info.get("page_size")})
    addr = {
        "kernel_addr": (info.get("kernel_addr"), 0x00008000),
        "ramdisk_addr": (info.get("ramdisk_addr"), 0x01000000),
        "tags_addr": (info.get("tags_addr"), 0x00000100),
        "dtb_addr": (info.get("dtb_addr"), 0x01F00000),
    }
    bad = [f"{k}={v:#x}!=expected {e:#x}" for k, (v, e) in addr.items() if v != e]
    add("boot.addresses", "boot", "PASS" if not bad else "FAIL",
        "kernel=0x8000 ramdisk=0x01000000 tags=0x100 dtb=0x01f00000"
        if not bad else "; ".join(bad))
    cmdline = (info.get("cmdline") or "").strip()
    add("boot.cmdline_empty", "boot",
        "PASS" if cmdline == "" else "WARN",
        "header cmdline empty (ABL supplies /chosen bootargs)"
        if cmdline == "" else f"header cmdline is not empty: {cmdline!r} (policy: ABL must supply it)")
    sizes = {k: int(info.get(k) or 0) for k in ("kernel_size", "ramdisk_size", "dtb_size")}
    ok_sizes = sizes["kernel_size"] > 0 and sizes["ramdisk_size"] > 0 and sizes["dtb_size"] > 0
    add("boot.payload_sizes", "boot", "PASS" if ok_sizes else "FAIL",
        f"kernel={sizes['kernel_size']} ramdisk={sizes['ramdisk_size']} dtb={sizes['dtb_size']}",
        extra=sizes)
    partition = 201326592  # 96 * 4096 * 128 sectors = 192 MiB liuqin boot partition
    add("boot.partition_fit", "boot",
        "PASS" if size <= partition else "FAIL",
        f"{size} / {partition} bytes ({partition - size} headroom)" if size <= partition
        else f"image {size} exceeds liuqin boot partition {partition} bytes",
        extra={"bytes": size, "partition_bytes": partition})
    if "kernel" in BOOT_PAYLOAD:
        k = BOOT_PAYLOAD["kernel"]
        add("boot.kernel_gzip", "boot", "PASS" if k[:2] == b"\x1f\x8b" else "WARN",
            "kernel payload is gzip (Image.gz)" if k[:2] == b"\x1f\x8b" else "kernel payload is not gzip")
        add("boot.kernel_sha256", "boot", "PASS", hashlib.sha256(k).hexdigest(),
            extra={"sha256": hashlib.sha256(k).hexdigest()})
    if "ramdisk" in BOOT_PAYLOAD:
        r = BOOT_PAYLOAD["ramdisk"]
        add("boot.ramdisk_sha256", "boot", "PASS", hashlib.sha256(r).hexdigest(),
            extra={"sha256": hashlib.sha256(r).hexdigest()})
        if INITRAMFS is not None and INITRAMFS.is_file():
            cur = sha256(INITRAMFS)
            embed = hashlib.sha256(r).hexdigest()
            if cur == embed:
                add("boot.ramdisk_matches_initramfs", "boot", "PASS",
                    "boot.img embeds the current initramfs file")
            else:
                add("boot.ramdisk_matches_initramfs", "boot", "WARN",
                    f"boot.img ramdisk {embed[:12]}… != current {cur[:12]}…; rebuild boot.img after "
                    f"initramfs changes (scripts/build-bootimg.sh)")
    if "dtb" in BOOT_PAYLOAD:
        d = BOOT_PAYLOAD["dtb"]
        add("boot.dtb_magic", "boot", "PASS" if d[:4] == b"\xd0\x0d\xfe\xed" else "FAIL",
            "FDT magic d00dfeed" if d[:4] == b"\xd0\x0d\xfe\xed" else "dtb payload lacks FDT magic")
    add("boot.sha256", "boot", "PASS" if BOOT.is_file() else "SKIP", sha256(BOOT) if BOOT.is_file() else "",
        extra={"sha256": sha256(BOOT) if BOOT.is_file() else None})


def parse_info_text(text):
    out = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        m = {
            "kernel_size": ("kernel_size", int),
            "ramdisk size": ("ramdisk_size", int),
            "kernel load address": ("kernel_addr", lambda v: int(v, 16)),
            "ramdisk load address": ("ramdisk_addr", lambda v: int(v, 16)),
            "kernel tags load address": ("tags_addr", lambda v: int(v, 16)),
            "dtb address": ("dtb_addr", lambda v: int(v, 16)),
            "dtb size": ("dtb_size", int),
            "page size": ("page_size", int),
            "boot image header version": ("header_version", int),
            "boot header size": ("header_size", int),
            "second bootloader size": ("second_size", int),
            "command line args": ("cmdline", str),
            "additional command line args": ("extra_cmdline", str),
        }
        if key in m:
            name, conv = m[key]
            try:
                out[name] = conv(val) if conv is not str else val
            except ValueError:
                pass
    return out


# ---------------------------------------------------------------------- dtb --
def load_dtb():
    if E["VB_SKIP_BOOT"] == "1" or not exists(DTB, "dtb"):
        return
    assert DTB is not None
    data = DTB.read_bytes()
    add("dtb.magic", "dtb", "PASS" if data[:4] == b"\xd0\x0d\xfe\xed" else "FAIL",
        "FDT magic d00dfeed" if data[:4] == b"\xd0\x0d\xfe\xed" else "no FDT magic", path=DTB)
    add("dtb.size", "dtb", "PASS", f"{len(data)} bytes", extra={"bytes": len(data)})
    # liuqin 7.3 normal-slot display handoff: ABL must see linux_splash, not
    # splash_region, before Linux cold-initializes the panel.
    splash_ok = b"linux_splash@b8000000" in data and b"splash_region@b8000000" not in data
    add("dtb.linux_splash", "dtb", "PASS" if splash_ok else "FAIL",
        "reserved-memory node is linux_splash@b8000000"
        if splash_ok else "missing linux_splash@b8000000 or still carries splash_region@b8000000")
    if b"gnome.is_vm=0" not in data:
        add("dtb.gnome_is_vm", "dtb", "FAIL", "cmdline lacks gnome.is_vm=0")
    else:
        add("dtb.gnome_is_vm", "dtb", "PASS", "cmdline carries gnome.is_vm=0")
    if b"console=drm_log" in data:
        add("dtb.console_drm_log", "dtb", "WARN",
            "cmdline still uses console=drm_log; verified A-slot cmdline uses console=tty0")
    if BOOT_INFO is not None and BOOT_INFO.get("dtb_size"):
        add("dtb.size_matches_boot", "dtb",
            "PASS" if len(data) == BOOT_INFO["dtb_size"] else "FAIL",
            f"dtb {len(data)} == boot payload {BOOT_INFO['dtb_size']}"
            if len(data) == BOOT_INFO["dtb_size"]
            else f"dtb file {len(data)} != boot payload {BOOT_INFO['dtb_size']}")
    identity = {
        "qcom,msm-id": b"qcom,msm-id",
        "qcom,board-id": b"qcom,board-id",
        "xiaomi,miboard-id": b"xiaomi,miboard-id",
        "chosen": b"chosen",
        "bootargs": b"bootargs",
        "symbols": b"__symbols__",
    }
    missing = [k for k, needle in identity.items() if needle not in data]
    if not missing:
        add("dtb.abl_contract", "dtb", "PASS",
            "board identity (msm-id/board-id/miboard-id), /chosen bootargs and __symbols__ present")
    else:
        add("dtb.abl_contract", "dtb", "WARN",
            "missing ABL contract strings: " + ", ".join(missing) +
            " (a stock-ROM rebuild injects the overlay sink; upstream-artifact DTB carries it)")
    if META is not None and META.is_file():
        try:
            meta = read_json(META)
            db = meta.get("payload", {}).get("dtb", {})
            if db.get("sha256"):
                add("dtb.sha256_vs_metadata", "dtb",
                    "PASS" if db["sha256"] == sha256(DTB) else "FAIL",
                    "matches build-info.json" if db["sha256"] == sha256(DTB)
                    else f"build-info dtb sha256 {db['sha256'][:16]}… != file {sha256(DTB)[:16]}…")
            if db.get("dt_bootargs"):
                has = db["dt_bootargs"].encode() in data
                add("dtb.bootargs_match_metadata", "dtb", "PASS" if has else "WARN",
                    "build-info dt_bootargs found in DTB" if has else "build-info dt_bootargs not found in DTB bytes")
        except Exception as exc:  # noqa: BLE001
            add("dtb.metadata", "dtb", "WARN", f"could not cross-check build-info: {exc}")


# ---------------------------------------------------------------- initramfs --
def load_initramfs():
    if not exists(INITRAMFS, "initramfs"):
        return
    assert INITRAMFS is not None
    raw = INITRAMFS.read_bytes()
    add("initramfs.gzip", "initramfs", "PASS" if raw[:2] == b"\x1f\x8b" else "FAIL",
        "gzip stream" if raw[:2] == b"\x1f\x8b" else "not a gzip stream", path=INITRAMFS)
    entries = []
    if raw[:2] == b"\x1f\x8b":
        try:
            cpio = gzip.decompress(raw)
            pos, total = 0, len(cpio)
            while pos + 110 <= total:
                if cpio[pos:pos + 6] not in (b"070701", b"070702"):
                    break
                fields = [cpio[pos + 6 + i * 8: pos + 6 + i * 8 + 8] for i in range(13)]
                namesize = int(fields[11], 16)
                filesize = int(fields[6], 16)
                name = cpio[pos + 110: pos + 110 + namesize - 1].decode("utf-8", "replace")
                entries.append((name, filesize))
                pos = pos + 110 + namesize
                pos = (pos + 3) & ~3
                pos += (filesize + 3) & ~3
            add("initramfs.cpio", "initramfs", "PASS",
                f"newc cpio parsed: {len(entries)} entries", extra={"entries": len(entries)})
            names = {n.lstrip("./") for n, _ in entries}
            for want in ("init", "bin/busybox", "bin/sh"):
                hit = want in names or any(n.endswith("/" + want.rsplit("/", 1)[-1]) for n in names)
                add(f"initramfs.{want.replace('/', '_')}", "initramfs",
                    "PASS" if hit else "WARN", f"{want} present" if hit else f"{want} not found")
            # qcom_q6v5_pas probes adsp.mbn at ~2.6 s, still inside the
            # initramfs, and never retries after switch_root.  Without the DSP
            # firmware (and the AudioReach topology the card loads) the DSPs stay
            # offline, q6prm exports no LPASS clocks, and every SoundWire/macro/
            # card probe defers: the device boots to "no soundcards" and no audio
            # at all.  Offline checks that only compare files on the rootfs miss
            # this, because the file exists — it is just not reachable in time.
            dsp_fw = "lib/firmware/qcom/sm8475/liuqin/adsp.mbn"
            tplg = "lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin"
            has_dsp = dsp_fw in names
            has_tplg = tplg in names
            add("initramfs.dsp_firmware", "initramfs",
                "PASS" if has_dsp else "WARN",
                "DSP firmware staged in the ramdisk" if has_dsp else
                "no " + dsp_fw + " in the ramdisk: ADSP/CDSP stay offline and the "
                "device reports no soundcards")
            add("initramfs.audio_topology", "initramfs",
                "PASS" if has_tplg else "WARN",
                "AudioReach topology staged in the ramdisk" if has_tplg else
                "no " + tplg + " in the ramdisk: the q6apm card cannot load its "
                "topology (missing audio firmware)")
            gate_add("gate.initramfs.dsp_audio",
                     has_dsp and has_tplg,
                     "initramfs carries DSP firmware and AudioReach topology"
                     if (has_dsp and has_tplg) else
                     "initramfs lacks the DSP firmware/topology: this image boots with "
                     "no sound card on liuqin; build with --firmware-pool "
                     "(dsp-sm8475) and --audio-topology")
        except Exception as exc:  # noqa: BLE001
            add("initramfs.cpio", "initramfs", "FAIL", f"could not parse cpio: {exc}")
    info_json = INITRAMFS.parent / "initramfs-info.json"
    if info_json.is_file():
        try:
            info = read_json(info_json)
            actual = sha256(INITRAMFS)
            recorded = info.get("artifact_sha256", "")
            add("initramfs.info_sha256", "initramfs",
                "PASS" if recorded == actual else "FAIL",
                "initramfs-info.json matches the file" if recorded == actual
                else f"stale metadata: initramfs-info.json says {recorded[:16]}…, file is {actual[:16]}…",
                path=info_json)
            staged = info.get("firmware_staged", [])
            skipped = info.get("firmware_skipped", [])
            if not staged:
                add("initramfs.firmware_free", "initramfs", "WARN",
                    "firmware-free dev image (firmware_staged empty; skipped: " + ", ".join(skipped) + ")"
                    " — expected for offline structure validation; device image needs firmware pool")
            else:
                add("initramfs.firmware_present", "initramfs", "WARN",
                    f"{len(staged)} firmware categories staged; verify redistribution rights "
                    f"(see NOTICE / docs/research/liuqin-assets.json)")
            if info.get("device_ready") is False:
                add("initramfs.device_ready", "initramfs", "WARN",
                    "device_ready=false: structure-only image, not a device artifact")
        except Exception as exc:  # noqa: BLE001
            add("initramfs.info", "initramfs", "WARN", f"cannot read initramfs-info.json: {exc}")


# ------------------------------------------------------------------ metadata --
def verify_kernel_config(kernel, config_meta, metadata_path):
    """Bind a claimed config snapshot to the kernel bytes being audited."""
    expected = config_meta.get("config_sha256")
    if not expected:
        return  # historical artifacts did not claim a config snapshot
    snapshot = config_meta.get("config_snapshot")
    config_path = metadata_path.parent / "kernel.config"
    snapshot_ok = snapshot == "kernel.config" and config_path.is_file()
    actual = sha256(config_path) if snapshot_ok else None
    add("metadata.kernel_config_snapshot", "metadata",
        "PASS" if actual == expected else "FAIL",
        f"config snapshot {actual} vs build-info {expected}", path=config_path)
    if kernel is None:
        add("metadata.kernel_config_embedded", "metadata", "FAIL",
            "cannot verify claimed config without the delivered kernel payload")
        return
    try:
        image = gzip.decompress(kernel) if kernel[:2] == b"\x1f\x8b" else kernel
        start = image.find(b"IKCFG_ST")
        if start < 0:
            add("metadata.kernel_config_embedded", "metadata", "FAIL",
                "claimed config cannot be bound to kernel: embedded IKCONFIG missing")
            return
        end = image.index(b"IKCFG_ED", start + 8)
        embedded = gzip.decompress(image[start + 8:end])
        embedded_sha = hashlib.sha256(embedded).hexdigest()
        add("metadata.kernel_config_embedded", "metadata",
            "PASS" if embedded_sha == expected else "FAIL",
            f"delivered kernel IKCONFIG {embedded_sha} vs build-info {expected}")
    except (OSError, EOFError, ValueError, zlib.error) as exc:
        add("metadata.kernel_config_embedded", "metadata", "FAIL",
            f"cannot extract delivered kernel IKCONFIG: {exc}")


def load_metadata():
    if not exists(META, "metadata"):
        return
    assert META is not None
    try:
        meta = read_json(META)
    except Exception as exc:  # noqa: BLE001
        add("metadata.json", "metadata", "FAIL", f"invalid JSON: {exc}", path=META)
        return
    add("metadata.json", "metadata", "PASS", "build-info.json parses", path=META)
    art = meta.get("artifact", "?")
    add("metadata.device", "metadata",
        "PASS" if meta.get("device", "").startswith("liuqin") else "WARN",
        f"device={meta.get('device')} artifact={art} format={meta.get('format')}")
    if BOOT is not None and BOOT.is_file():
        actual_sha, actual_bytes = sha256(BOOT), BOOT.stat().st_size
        add("metadata.artifact_sha256", "metadata",
            "PASS" if meta.get("artifact_sha256") == actual_sha else "FAIL",
            "build-info artifact sha256 matches boot.img"
            if meta.get("artifact_sha256") == actual_sha
            else f"build-info {str(meta.get('artifact_sha256'))[:16]}… != file {actual_sha[:16]}…")
        add("metadata.artifact_bytes", "metadata",
            "PASS" if meta.get("artifact_bytes") == actual_bytes else "FAIL",
            f"build-info bytes {meta.get('artifact_bytes')} vs file {actual_bytes}")
    hdr = meta.get("header", {})
    if BOOT_INFO:
        mism = []
        if hdr.get("version") != BOOT_INFO.get("header_version"):
            mism.append("version")
        if hdr.get("pagesize") != BOOT_INFO.get("page_size"):
            mism.append("pagesize")
        if (hdr.get("cmdline") or "") != (BOOT_INFO.get("cmdline") or ""):
            mism.append("cmdline")
        add("metadata.header", "metadata", "PASS" if not mism else "FAIL",
            "build-info header matches boot.img" if not mism else "header mismatch: " + ", ".join(mism))
    payload = meta.get("payload", {})
    k = payload.get("kernel", {})
    # Compare against the kernel payload ACTUALLY inside the
    # audited boot.img; falling back to a sidecar Image.gz (out/boot/Image.gz)
    # compares a stale artifact and turns a correct delivery into a FAIL.
    delivered_kernel = BOOT_PAYLOAD.get("kernel")
    if E["VB_SKIP_BOOT"] != "1":
        verify_kernel_config(delivered_kernel, k, META)
    if k.get("gzip_sha256") and delivered_kernel is not None:
        delivered_kernel_sha = hashlib.sha256(delivered_kernel).hexdigest()
        add("metadata.kernel_file", "metadata",
            "PASS" if delivered_kernel_sha == k["gzip_sha256"] else "FAIL",
            "delivered boot.img kernel payload matches build-info gzip sha256"
            if delivered_kernel_sha == k["gzip_sha256"] else
            f"delivered boot.img kernel {delivered_kernel_sha[:12]}… != build-info "
            f"{str(k.get('gzip_sha256'))[:12]}…")
    else:
        kfile = None
        for cand in ((META.parent / "Image.gz") if META is not None else None,
                     (BOOT.parent / "Image.gz") if BOOT is not None else None,
                     PROJECT / "out/boot/Image.gz"):
            if cand is not None and cand.is_file():
                kfile = cand
                break
        if k.get("gzip_sha256") and kfile is not None:
            add("metadata.kernel_file", "metadata",
                "PASS" if sha256(kfile) == k["gzip_sha256"] else "FAIL",
                f"{kfile.name} matches build-info kernel gzip sha256"
                if sha256(kfile) == k["gzip_sha256"] else f"{kfile.name} hash mismatch")
    r = payload.get("ramdisk", {})
    if r.get("sha256") and INITRAMFS is not None and INITRAMFS.is_file():
        cur = sha256(INITRAMFS)
        add("metadata.ramdisk_file", "metadata",
            "PASS" if cur == r["sha256"] else "WARN",
            "build-info ramdisk hash matches current initramfs"
            if cur == r["sha256"] else
            f"stale metadata/artifact chain: build-info ramdisk {r['sha256'][:12]}… != current file {cur[:12]}… ; "
            f"rebuild out/boot (build-initramfs.sh + build-bootimg.sh) so metadata matches")
    add("metadata.partition", "metadata",
        "PASS" if meta.get("fits_partition") is True else "WARN",
        f"fits_partition={meta.get('fits_partition')} partition_bytes={meta.get('partition_bytes')}")
    ks = meta.get("kernel_source_commit", {})
    lock_file = None
    for cand in (PROJECT / "kernel/source.json",
                 PROJECT / "upstream/xiaomipad-6pro-mainline/kernel/source.json"):
        if cand.is_file():
            lock_file = cand
            break
    if lock_file is not None:
        try:
            lock = read_json(lock_file)
            add("metadata.kernel_lock", "metadata",
                "PASS" if ks.get("project_lock_commit") == lock.get("commit") else "FAIL",
                f"build-info project_lock_commit {str(ks.get('project_lock_commit'))[:12]}… vs "
                f"kernel/source.json {str(lock.get('commit'))[:12]}…")
        except Exception as exc:  # noqa: BLE001
            add("metadata.kernel_lock", "metadata", "WARN", f"cannot read kernel/source.json: {exc}")
    else:
        add("metadata.kernel_lock", "metadata", "WARN", "kernel/source.json missing")


# ----------------------------------------------------------------- checksums --
def parse_sums(path):
    entries = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", line)
        if not m:
            entries.append((None, line))
            continue
        entries.append((m.group(1).lower(), m.group(2).strip()))
    return entries


def verify_sums(sums_path, base_dir, label):
    if not exists(sums_path, f"checksums.{label}"):
        return
    assert sums_path is not None
    entries = parse_sums(sums_path)
    bad = [line for h, line in entries if h is None]
    add(f"checksums.{label}.format", "checksums",
        "PASS" if not bad else "FAIL",
        f"{len(entries)} entries" if not bad else "malformed lines: " + "; ".join(bad[:3]))
    ok = miss = mismatch = 0
    problems = []
    for digest, rel in entries:
        if digest is None:
            continue
        target = (base_dir / rel).resolve()
        try:
            target.relative_to(base_dir.resolve())
        except ValueError:
            mismatch += 1
            problems.append(f"path escapes base dir: {rel}")
            continue
        if not target.is_file():
            miss += 1
            problems.append(f"missing: {rel}")
            continue
        if sha256(target) == digest:
            ok += 1
        else:
            mismatch += 1
            problems.append(f"hash mismatch: {rel} (sums {digest[:12]}… actual {sha256(target)[:12]}…)")
    status = "PASS" if mismatch == 0 and miss == 0 else "FAIL"
    add(f"checksums.{label}.files", "checksums", status,
        f"{ok} ok, {mismatch} mismatch, {miss} missing" + ("" if status == "PASS" else " | " + "; ".join(problems[:5])),
        path=sums_path, extra={"ok": ok, "mismatch": mismatch, "missing": miss, "problems": problems[:20]})


# ------------------------------------------------------------------- rootfs --
def read_os_release(rootfs):
    p = rootfs / "etc/os-release"
    out = {}
    if p.is_file():
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip().strip('"')
    return out


def rpmdb_names(rootfs):
    candidates = [
        rootfs / "usr/lib/sysimage/rpm/rpmdb.sqlite",
        rootfs / "var/lib/rpm/rpmdb.sqlite",
    ]
    for db in candidates:
        if not db.is_file():
            continue
        tmp = Path(tempfile.mkdtemp(prefix="verify-rpmdb-"))
        try:
            for suffix in ("", "-wal", "-shm"):
                src = Path(str(db) + suffix)
                if src.is_file():
                    shutil.copyfile(src, tmp / ("rpmdb.sqlite" + suffix))
            con = sqlite3.connect(str(tmp / "rpmdb.sqlite"))
            try:
                names = [r[0] for r in con.execute("select distinct key from Name order by key")]
                count = con.execute("select count(*) from Packages").fetchone()[0]
            finally:
                con.close()
            return names, count
        except Exception:  # noqa: BLE001
            continue
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return None, None


def load_rootfs():
    global ROOTFS
    if E["VB_SKIP_ROOTFS"] == "1":
        add("rootfs.skipped", "rootfs", "SKIP", "disabled by --no-rootfs")
        return
    if ROOTFS is None:
        if BUNDLE is not None:
            add("rootfs.auto", "rootfs", "SKIP",
                f"no assembled rootfs tree associated with bundle {BUNDLE.name}; "
                "pass --rootfs for the matching staging tree")
        else:
            add("rootfs.auto", "rootfs", "SKIP",
                "no rootfs tree found (out/rootfs/rootfs or out/env-smoke/mkosi-smoke/out/image)")
        return
    if not ROOTFS.is_dir():
        add("rootfs.exists", "rootfs", "FAIL", f"missing: {ROOTFS}", path=ROOTFS)
        return
    add("rootfs.exists", "rootfs", "PASS", str(ROOTFS), path=ROOTFS)
    osr = read_os_release(ROOTFS)
    osr_ok = osr.get("ID") == "fedora" or (
        osr.get("ID") == "liuqin" and "fedora" in osr.get("ID_LIKE", "").split()
        and (ROOTFS / "etc/liuqin-fedora-root").read_text().strip() == "liuqin-fedora-root-v1")
    add("rootfs.os_release", "rootfs", "PASS" if osr_ok else "FAIL",
        f"ID={osr.get('ID')} VERSION_ID={osr.get('VERSION_ID')} RELEASE_TYPE={osr.get('RELEASE_TYPE')}",
        path=ROOTFS / "etc/os-release")
    rel = osr.get("VERSION_ID")
    expected = EXPECTED_RELEASE if EXPECTED_RELEASE not in ("auto", "") else rel
    add("rootfs.release", "rootfs",
        "PASS" if rel == expected else "FAIL",
        f"Fedora {rel} (expected {expected})" if rel == expected
        else f"rootfs is Fedora {rel}, expected {expected}")
    # profile detection
    full = PROFILE == "full"
    if PROFILE == "auto":
        full = (ROOTFS / "usr/bin/plasmashell").is_file() or \
               (ROOTFS / "usr/bin/gnome-shell").is_file() or \
               (ROOTFS / "usr/share/wayland-sessions/plasma.desktop").is_file() or \
               (ROOTFS / "usr/share/wayland-sessions/gnome.desktop").is_file() or \
               (ROOTFS / "usr/lib/systemd/system/gdm.service").is_file() or \
               (ROOTFS / "usr/lib/systemd/system/plasmalogin.service").is_file()
        add("rootfs.profile", "rootfs", "PASS",
            "detected profile: full (desktop)" if full else "detected profile: minimal (no desktop)")
    else:
        add("rootfs.profile", "rootfs", "PASS", f"profile forced: {PROFILE}")
    # packages
    pkgs_txt = ROOTFS.parent / "rootfs.packages.txt"
    names, pkg_count = (None, None)
    if pkgs_txt.is_file():
        names = []
        for line in pkgs_txt.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            m = re.match(r"^(.+)-(?:\d[^-]*)-(?:[^-]+)\.(?:[a-z0-9_]+)$", line)
            names.append(m.group(1) if m else line.rsplit("-", 2)[0])
        pkg_count = len(names)
        add("rootfs.packages_source", "rootfs", "PASS", f"rootfs.packages.txt ({pkg_count} packages)",
            path=pkgs_txt)
    else:
        names, pkg_count = rpmdb_names(ROOTFS)
        if names is not None:
            add("rootfs.packages_source", "rootfs", "PASS",
                f"rpmdb.sqlite fallback ({pkg_count} packages)", path=ROOTFS)
        else:
            add("rootfs.packages_source", "rootfs", "WARN",
                "no rootfs.packages.txt and no readable rpmdb (package-level checks limited)")
    if pkg_count is not None:
        need = 50 if full else 5
        add("rootfs.package_count", "rootfs", "PASS" if pkg_count >= need else "FAIL",
            f"{pkg_count} packages (>= {need} required for {'full' if full else 'minimal'} profile)")
    if names:
        nameset = set(names)
        base = ["systemd", "bash", "dnf5" if "dnf5" in nameset else "dnf", "glibc", "filesystem"]
        missing_base = [p for p in base if p not in nameset]
        add("rootfs.base_packages", "rootfs", "PASS" if not missing_base else "WARN",
            "core packages present" if not missing_base else "missing: " + ", ".join(missing_base))
        if full:
            is_kde = ("plasma-desktop" in nameset or "plasmalogin" in nameset or
                      "plasma-workspace" in nameset)
            if is_kde:
                desktop_pkgs = ["plasma-desktop", "plasma-workspace", "kwin",
                                "plasma-login-manager", "kde-settings-plasmalogin",
                                "plasma-keyboard", "xdg-desktop-portal-kde"]
                label = "KDE Plasma"
            else:
                desktop_pkgs = ["gnome-shell", "gnome-session", "gnome-control-center",
                                "gnome-settings-daemon", "gdm", "nautilus",
                                "gnome-software", "xdg-desktop-portal-gnome"]
                label = "GNOME"
            missing_desktop = [p for p in desktop_pkgs if p not in nameset]
            add("rootfs.desktop_packages", "rootfs", "PASS" if not missing_desktop else "FAIL",
                f"{label} package set present" if not missing_desktop
                else f"missing {label} packages: " + ", ".join(missing_desktop))
            base_net = ["NetworkManager", "pipewire", "wireplumber", "tuned", "iio-sensor-proxy"]
            missing_net = [p for p in base_net if p not in nameset]
            add("rootfs.tablet_packages", "rootfs", "PASS" if not missing_net else "WARN",
                "tablet/runtime packages present" if not missing_net
                else "missing runtime packages: " + ", ".join(missing_net))
        ubuntu_pkgs = [p for p in names if p.lower() in (
            "ubuntu-minimal", "ubuntu-base", "ubuntu-standard", "casper", "snapd")]
        add("rootfs.no_ubuntu_packages", "rootfs", "PASS" if not ubuntu_pkgs else "FAIL",
            "no Ubuntu-only packages" if not ubuntu_pkgs else "found: " + ", ".join(ubuntu_pkgs))
    # systemd
    unit_dirs = [ROOTFS / "usr/lib/systemd/system", ROOTFS / "etc/systemd/system"]
    units = set()
    for d in unit_dirs:
        if d.is_dir():
            units.update(p.name for p in d.glob("*.service"))
    unit_count = len(units)
    sys_status = "PASS" if unit_count >= 5 else ("WARN" if not full else "FAIL")
    sys_detail = f"{unit_count} .service units installed"
    if unit_count < 5 and not full:
        sys_detail += " (minimal smoke rootfs: no systemd package installed; expected)"
    add("rootfs.systemd_units", "rootfs", sys_status, sys_detail,
        extra={"service_count": unit_count})
    if full:
        required_units = ["NetworkManager.service", "sshd.service"]
        missing_units = [u for u in required_units if u not in units]
        add("rootfs.systemd_required", "rootfs", "PASS" if not missing_units else "FAIL",
            "required services present" if not missing_units else "missing: " + ", ".join(missing_units))
        login_units = [u for u in ("plasmalogin.service", "sddm.service", "gdm.service") if u in units]
        add("rootfs.login_manager", "rootfs", "PASS" if login_units else "FAIL",
            "login manager unit: " + ", ".join(login_units) if login_units else
            "no plasmalogin/sddm/gdm unit installed")
        plasma_session = ROOTFS / "usr/share/wayland-sessions/plasma.desktop"
        gnome_session = ROOTFS / "usr/share/wayland-sessions/gnome.desktop"
        session = plasma_session if plasma_session.is_file() else gnome_session
        add("rootfs.desktop_session", "rootfs", "PASS" if session.is_file() else "FAIL",
            f"{session.name} installed" if session.is_file() else "no Plasma/GNOME Wayland session",
            path=session)
        liuqin_units = sorted(u for u in units if u.startswith("liuqin-"))
        add("rootfs.device_layer", "rootfs", "WARN",
            f"{len(liuqin_units)} liuqin-* units present" if liuqin_units else
            "no liuqin-* units: device layer is injected at image assembly (expected for rootfs build)")
        fstab = ROOTFS / "etc/fstab"
        if fstab.is_file():
            txt = fstab.read_text(errors="replace")
            assembled = "Written by scripts/build-image.sh" in txt
            root_line = next((l for l in txt.splitlines()
                              if l.strip() and not l.lstrip().startswith("#")
                              and len(l.split()) >= 2 and l.split()[1] == "/"),
                             "")
            problems = []
            if assembled:
                # Flat image contract: /home is part of the root partition.
                # The initramfs mounts the root by LABEL=LIUQIN_ROOT; systemd
                # uses this line for growfs.  A LABEL=LIUQIN_HOME entry points
                # at a partition that does not exist on this layout.
                if "LABEL=LIUQIN_ROOT" not in root_line:
                    problems.append("root line lacks LABEL=LIUQIN_ROOT")
                if "x-systemd.growfs" not in root_line:
                    problems.append("root line lacks x-systemd.growfs")
                if "LABEL=LIUQIN_HOME" in txt:
                    problems.append("flat root still carries LABEL=LIUQIN_HOME")
                add("rootfs.fstab", "rootfs", "PASS" if not problems else "FAIL",
                    "assembled flat-root fstab: root label + growfs, no home mount"
                    if not problems else "; ".join(problems), path=fstab)
            else:
                if "LABEL=LIUQIN_ROOT" not in txt:
                    problems.append("missing root label LABEL=LIUQIN_ROOT")
                if "LABEL=LIUQIN_HOME" not in txt:
                    problems.append("missing home label LABEL=LIUQIN_HOME")
                if "x-systemd.growfs" not in root_line:
                    problems.append("root line lacks x-systemd.growfs")
                if "ROOTFS_UUID_PLACEHOLDER" in txt:
                    problems.append("contains ROOTFS_UUID_PLACEHOLDER")
                add("rootfs.fstab", "rootfs", "PASS" if not problems else "FAIL",
                    "fstab labels + growfs OK" if not problems else "; ".join(problems), path=fstab)
        else:
            add("rootfs.fstab", "rootfs", "FAIL", "/etc/fstab missing (installer expects LIUQIN_ROOT/HOME)")
        slpi_marker = ROOTFS / "etc/liuqin-slpi-disabled"
        add("rootfs.slpi_disabled", "rootfs",
            "PASS" if slpi_marker.is_file() else "FAIL",
            "SLPI disable marker present" if slpi_marker.is_file()
            else "missing /etc/liuqin-slpi-disabled; SLPI startup resets this tablet",
            path=slpi_marker)
    else:
        add("rootfs.login_manager", "rootfs", "SKIP", "minimal profile: no login manager expected")
        add("rootfs.desktop_session", "rootfs", "SKIP", "minimal profile: no desktop session expected")
        fstab = ROOTFS / "etc/fstab"
        add("rootfs.fstab", "rootfs", "SKIP",
            "minimal smoke rootfs: /etc/fstab " + ("absent" if not fstab.is_file() else "present but not installer image"))
    # ELF scan
    elf_total = aarch64 = x86_64 = other = 0
    x86_files = []
    key_bins = ["usr/bin/bash", "usr/lib/systemd/systemd", "usr/bin/rpm"]
    key_machine = {}
    for root, dirs, files in os.walk(ROOTFS):
        dirs[:] = [d for d in dirs if d not in ("proc", "sys", "dev", "run")]
        for f in files:
            p = Path(root) / f
            try:
                if p.is_symlink() or not p.is_file():
                    continue
                with open(p, "rb") as fh:
                    head = fh.read(20)
            except OSError:
                continue
            if head[:4] != b"\x7fELF":
                continue
            elf_total += 1
            if len(head) < 20:
                other += 1
                continue
            machine = struct.unpack_from("<H", head, 18)[0]
            relp = str(p.relative_to(ROOTFS))
            if machine == 183:
                aarch64 += 1
                if relp in key_bins:
                    key_machine[relp] = "aarch64"
            elif machine == 62:
                x86_64 += 1
                if len(x86_files) < 20:
                    x86_files.append(relp)
            else:
                other += 1
    add("rootfs.elf_scan", "rootfs", "PASS",
        f"{elf_total} ELF files: {aarch64} aarch64, {x86_64} x86_64, {other} other",
        extra={"elf_total": elf_total, "aarch64": aarch64, "x86_64": x86_64})
    add("rootfs.elf_aarch64", "rootfs", "PASS" if aarch64 > 0 else "FAIL",
        f"{aarch64} aarch64 ELF binaries")
    add("rootfs.no_x86_64", "rootfs", "PASS" if x86_64 == 0 else "FAIL",
        "no x86_64 ELF binaries" if x86_64 == 0 else f"{x86_64} x86_64 ELFs e.g. {x86_files[:5]}")
    missing_key = [b for b in key_bins if (ROOTFS / b).is_file() and b not in key_machine]
    if key_machine:
        add("rootfs.key_binaries", "rootfs", "PASS" if not missing_key else "WARN",
            "key ELF binaries are aarch64" if not missing_key else "non-aarch64 key binaries: " + ", ".join(missing_key))
    # package manager may be a python script (dnf5) or an ELF; presence is what matters
    pkgmgr = [b for b in ("usr/bin/dnf", "usr/bin/dnf5", "usr/bin/rpm") if (ROOTFS / b).is_file()]
    add("rootfs.package_manager", "rootfs", "PASS" if pkgmgr else "FAIL",
        "package manager: " + ", ".join(pkgmgr) if pkgmgr else "no dnf/dnf5/rpm in rootfs")
    # Ubuntu/Fedora residue
    bad_paths = ["etc/apt", "usr/bin/apt", "usr/bin/dpkg", "var/lib/dpkg", "usr/bin/snap",
                 "etc/lsb-release", "initrd.img", "vmlinuz", "boot/grub"]
    found = [p for p in bad_paths if (ROOTFS / p).exists()]
    # Fedora rootfs may legitimately ship /etc/lsb-release? treat as WARN not FAIL.
    lsbrel_ubuntu = False
    lsb = ROOTFS / "etc/lsb-release"
    if lsb.is_file():
        lsbrel_ubuntu = "Ubuntu" in lsb.read_text(errors="replace")
    found = [p for p in found if p != "etc/lsb-release" or lsbrel_ubuntu]
    add("rootfs.no_ubuntu_residue", "rootfs", "PASS" if not found else "FAIL",
        "no Ubuntu-only paths" if not found else "found Ubuntu paths: " + ", ".join(found))
    forbidden = ["persist", "factory", "var/lib/liuqin/device", "etc/liuqin/persist",
                 "var/lib/liuqin/switch"]
    bad = [p for p in forbidden if (ROOTFS / p).exists()]
    add("rootfs.no_device_private_data", "rootfs", "PASS" if not bad else "FAIL",
        "no persist/factory/switch-store data" if not bad else "device-private paths present: " + ", ".join(bad))
    # firmware provenance
    fw_dirs = ["usr/lib/firmware/novatek/liuqin", "usr/lib/firmware/qcom/sm8475",
               "usr/lib/firmware/updates/qcom"]
    fw_present = [d for d in fw_dirs if (ROOTFS / d).exists()]
    if fw_present:
        marker = ROOTFS / "usr/share/liuqin/firmware-provenance.json"
        add("rootfs.firmware_provenance", "rootfs",
            "PASS" if marker.is_file() else "WARN",
            "firmware provenance manifest present" if marker.is_file() else
            "device firmware present without /usr/share/liuqin/firmware-provenance.json; "
            "record source/licence (NOTICE, docs/research/liuqin-assets.json)")
    else:
        add("rootfs.firmware_provenance", "rootfs", "SKIP",
            "no device-specific firmware in this rootfs (device layer injected at assembly)")


# -------------------------------------------------------------------- rpms --
def load_rpms():
    """Verify built RPM sets when present (out/rpms*/): RPM magic, arch, sums."""
    roots = [PROJECT / d for d in ("out/rpms", "out/rpms/kernel", "out/rpms-device",
                                   "out/rpms-mobile", "out/rpms/device")]
    found = []
    for root in roots:
        if root.is_dir():
            found.extend(sorted(root.glob("*.rpm")))
    # de-duplicate by path (nested roots overlap)
    seen = set()
    rpms = []
    for r in found:
        if r not in seen:
            seen.add(r)
            rpms.append(r)
    if not rpms:
        add("rpms.artifacts", "rpms", "SKIP",
            "no built RPMs found under out/rpms*/ (RPM packaging stage not completed yet)")
        return
    bad_magic, bad_arch, ok = [], [], 0
    for r in rpms:
        try:
            head = r.read_bytes()[:4]
        except OSError:
            bad_magic.append(f"{r.name}: unreadable")
            continue
        if head != b"\xed\xab\xee\xdb":
            bad_magic.append(f"{r.name}: not an RPM (magic {head.hex()})")
            continue
        ok += 1
        m = re.match(r"^(?P<name>.+)-(?P<ver>[^-]+)-(?P<rel>[^-]+)\.(?P<arch>aarch64|noarch|x86_64|i686|src)$", r.name)
        if m and m.group("arch") in ("x86_64", "i686"):
            bad_arch.append(r.name)
    add("rpms.magic", "rpms", "PASS" if not bad_magic else "FAIL",
        f"{ok}/{len(rpms)} RPM payloads valid" if not bad_magic else "; ".join(bad_magic[:5]),
        extra={"rpms": [str(x.relative_to(PROJECT)) for x in rpms[:100]]})
    add("rpms.arch", "rpms", "PASS" if not bad_arch else "FAIL",
        "all RPMs are aarch64/noarch/src" if not bad_arch else "x86_64 RPMs: " + ", ".join(bad_arch[:10]))
    # SHA256SUMS next to any rpm directory
    for d in sorted({r.parent for r in rpms}):
        sums = d / "SHA256SUMS"
        if sums.is_file():
            verify_sums(sums, d, f"rpm-{d.name}")
        else:
            add(f"rpms.sums_{d.name}", "rpms", "WARN",
                f"no SHA256SUMS in {d.relative_to(PROJECT)}", path=d)
    add("rpms.count", "rpms", "PASS", f"{len(rpms)} RPM files present", extra={"count": len(rpms)})


# ---------------------------------------------------------- rootfs manifests --
def load_rootfs_manifest():
    """Validate out/rootfs/{rootfs.manifest,rootfs.packages.txt,
    rootfs.files.sha256,build-info.json} when the full rootfs build exists."""
    if ROOTFS is None:
        add("rootfs.manifest", "manifests", "SKIP", "no rootfs tree")
        return
    base = ROOTFS.parent
    manifest = base / "rootfs.manifest"
    pkgs_txt = base / "rootfs.packages.txt"
    files_sha = base / "rootfs.files.sha256"
    build_info = base / "build-info.json"
    present = [p.name for p in (manifest, pkgs_txt, files_sha, build_info) if p.is_file()]
    if not present:
        add("rootfs.manifest", "manifests", "SKIP",
            "no out/rootfs manifest set next to the rootfs (smoke rootfs or assembly not finished)")
        return
    add("rootfs.manifest.files", "manifests", "PASS",
        "rootfs build artifacts present: " + ", ".join(present))
    if not manifest.is_file():
        add("rootfs.manifest.json", "manifests", "WARN", "rootfs.manifest missing")
        return
    try:
        man = read_json(manifest)
    except Exception as exc:  # noqa: BLE001
        add("rootfs.manifest.json", "manifests", "FAIL", f"invalid rootfs.manifest: {exc}", path=manifest)
        return
    add("rootfs.manifest.format", "manifests",
        "PASS" if man.get("format") == "liuqin-rootfs-manifest/v1" else "FAIL",
        f"format={man.get('format')}", path=manifest)
    image = man.get("image", {})
    add("rootfs.manifest.image", "manifests",
        "PASS" if image.get("device") == "liuqin" and image.get("architecture") == "aarch64" else "FAIL",
        f"device={image.get('device')} arch={image.get('architecture')} "
        f"distribution={image.get('distribution')} release={image.get('release')}")
    if EXPECTED_RELEASE not in ("auto", "") and image.get("release") not in (None, ""):
        add("rootfs.manifest.release", "manifests",
            "PASS" if str(image.get("release")) == EXPECTED_RELEASE else "FAIL",
            f"manifest release {image.get('release')} vs expected {EXPECTED_RELEASE}")
    art = man.get("artifact", {})
    if pkgs_txt.is_file():
        actual = sha256(pkgs_txt)
        add("rootfs.manifest.packages_txt", "manifests",
            "PASS" if art.get("packages_txt_sha256") == actual else "FAIL",
            "rootfs.manifest packages_txt_sha256 matches rootfs.packages.txt"
            if art.get("packages_txt_sha256") == actual else
            f"packages_txt_sha256 {str(art.get('packages_txt_sha256'))[:12]}… != {actual[:12]}…")
        add("rootfs.manifest.package_count", "manifests",
            "PASS" if int(man.get("package_count", -1)) == len(pkgs_txt.read_text().splitlines())
            else "WARN",
            f"manifest package_count={man.get('package_count')}")
    if files_sha.is_file():
        n = len([l for l in files_sha.read_text(errors="replace").splitlines() if l.strip()])
        add("rootfs.manifest.files_sha256", "manifests",
            "PASS" if art.get("files_sha256_sha256") == sha256(files_sha) else "FAIL",
            f"files_sha256: {n} entries, hash matches manifest"
            if art.get("files_sha256_sha256") == sha256(files_sha) else
            "rootfs.files.sha256 hash mismatch vs manifest")
        if art.get("files_sha256_count") not in (None, ""):
            add("rootfs.manifest.files_count", "manifests",
                "PASS" if int(art["files_sha256_count"]) == n else "FAIL",
                f"manifest files_sha256_count={art['files_sha256_count']} actual={n}")
    if build_info.is_file():
        try:
            bi = read_json(build_info)
            add("rootfs.build_info", "manifests", "PASS",
                f"build-info.json keys={len(bi)} release={bi.get('release') or bi.get('fedora_release')}")
        except Exception as exc:  # noqa: BLE001
            add("rootfs.build_info", "manifests", "FAIL", f"invalid out/rootfs/build-info.json: {exc}")

# ------------------------------------------------------------------- bundle --
def load_bundle():
    if E["VB_SKIP_BUNDLE"] == "1" or BUNDLE is None:
        add("bundle.skipped", "bundle", "SKIP", "no bundle directory (pass --bundle DIR)")
        return
    if not BUNDLE.is_dir():
        add("bundle.exists", "bundle", "FAIL", f"missing: {BUNDLE}", path=BUNDLE)
        return
    add("bundle.exists", "bundle", "PASS", str(BUNDLE), path=BUNDLE)
    bjson = BUNDLE / "bundle.json"
    sums = BUNDLE / "SHA256SUMS"
    bdata = None
    if bjson.is_file():
        try:
            bdata = read_json(bjson)
            add("bundle.json", "bundle", "PASS", "bundle.json parses", path=bjson)
        except Exception as exc:  # noqa: BLE001
            add("bundle.json", "bundle", "FAIL", f"invalid bundle.json: {exc}", path=bjson)
    else:
        add("bundle.json", "bundle", "WARN", "bundle.json missing", path=bjson)
    sums_map = {}
    if sums.is_file():
        for digest, rel in parse_sums(sums):
            if digest:
                sums_map[rel] = digest
        add("bundle.sha256sums", "bundle", "PASS", f"SHA256SUMS parses ({len(sums_map)} entries)", path=sums)
    else:
        add("bundle.sha256sums", "bundle", "WARN", "SHA256SUMS missing", path=sums)
    files = (bdata or {}).get("files", {})
    if not isinstance(files, dict) or not files:
        add("bundle.files", "bundle", "SKIP", "bundle.json has no files map; only SHA256SUMS checked")
        return
    missing, bad, ok = [], [], 0
    for name, digest in files.items():
        p = BUNDLE / name
        if not p.is_file():
            missing.append(name)
            if BUNDLE_PARTIAL:
                continue
            continue
        actual = sha256(p)
        if actual != digest:
            bad.append(f"{name}: bundle.json {digest[:12]}… != file {actual[:12]}…")
        else:
            ok += 1
        if name in sums_map and sums_map[name] != digest:
            bad.append(f"{name}: SHA256SUMS/bundle.json disagree")
    add("bundle.files", "bundle",
        "PASS" if not bad and (BUNDLE_PARTIAL or not missing) else "FAIL",
        f"{ok} verified, {len(missing)} missing (partial cache), {len(bad)} mismatch"
        if not bad and (missing and BUNDLE_PARTIAL) else
        f"{ok} verified, {len(missing)} missing, {len(bad)} mismatch | " +
        "; ".join((missing[:5] if not BUNDLE_PARTIAL else []) + bad[:5]),
        extra={"ok": ok, "missing": missing[:50], "mismatch": bad[:20]})
    only_sums = [n for n in sums_map if n not in files and n != "bundle.json"]
    if only_sums:
        add("bundle.sums_extra", "bundle", "PASS",
            f"{len(only_sums)} SHA256SUMS entries not referenced by bundle.json (allowed, e.g. split parts)")
    lock = PROJECT / "kernel/source.json"
    if bdata and lock.is_file():
        try:
            lk = read_json(lock)
            kc = bdata.get("kernel_commit")
            add("bundle.kernel_commit", "bundle",
                "PASS" if kc == lk.get("commit") else "WARN",
                f"bundle kernel_commit {str(kc)[:12]}… matches kernel/source.json"
                if kc == lk.get("commit") else
                f"bundle kernel_commit {str(kc)[:12]}… != kernel/source.json {str(lk.get('commit'))[:12]}…")
        except Exception:  # noqa: BLE001
            pass
    if bdata and "device" in bdata:
        add("bundle.device", "bundle", "PASS" if bdata.get("device") == "liuqin" else "WARN",
            f"device={bdata.get('device')} status={bdata.get('status')}")


# --------------------------------------------------------------------- repo --
def load_repo():
    if E["VB_SKIP_REPO"] == "1":
        add("repo.skipped", "repo", "SKIP", "disabled by --no-repo")
        return
    for name in ("NOTICE", "LICENSE", "README.md"):
        p = PROJECT / name
        add(f"repo.{name}", "repo", "PASS" if p.is_file() else "FAIL",
            "present" if p.is_file() else "missing", path=p)
    notice = PROJECT / "NOTICE"
    if notice.is_file():
        txt = notice.read_text(encoding="utf-8", errors="replace").lower()
        has = any(k in txt for k in (
            "不可再分发", "不得再分发", "不再分发", "严禁再分发", "禁止再分发",
            "not redistribut", "non-redistribut", "no rights", "distribution terms",
            "not shipped", "obtained by the user"))
        add("repo.firmware_clause", "repo", "PASS" if has else "WARN",
            "NOTICE records firmware redistribution restriction" if has
            else "NOTICE lacks an explicit firmware non-redistribution clause")
    tracking = PROJECT / "docs/maintenance/upstream-tracking.md"
    pins = {
        "device": "f5a535f5c1c980f042b58cb77467ff8f02a5518e",
        "kernel": "fe81794b5e1b8a3f11a165f3acbfdb8fa671dbb3",
        "pipa": "1c9cbd3983210a2c585311ee86b46ef8cb2c3c32",
    }
    if tracking.is_file():
        txt = tracking.read_text(encoding="utf-8", errors="replace")
        missing = [k for k, v in pins.items() if v not in txt]
        add("repo.upstream_pins", "repo", "PASS" if not missing else "WARN",
            "upstream-tracking.md pins device/kernel/pipa commits" if not missing
            else "pins missing for: " + ", ".join(missing), path=tracking)
    else:
        add("repo.upstream_pins", "repo", "FAIL", "docs/maintenance/upstream-tracking.md missing")
    lock = PROJECT / "kernel/source.json"
    if lock.is_file():
        try:
            lk = read_json(lock)
            ok = bool(lk.get("commit")) and bool(lk.get("config_fragments"))
            add("repo.kernel_lock_json", "repo", "PASS" if ok else "WARN",
                f"kernel/source.json commit={str(lk.get('commit'))[:12]}… fragments={len(lk.get('config_fragments', []))}")
        except Exception as exc:  # noqa: BLE001
            add("repo.kernel_lock_json", "repo", "FAIL", f"invalid kernel/source.json: {exc}")
    adr = PROJECT / "docs/adr/0002-build-pipeline.md"
    if adr.is_file() and EXPECTED_RELEASE not in ("auto", ""):
        txt = adr.read_text(encoding="utf-8", errors="replace")
        target = "44"
        m = re.search(r"目标 Fedora 版本\s*=\s*Fedora\s*(\d+)", txt)
        if m:
            target = m.group(1)
        add("repo.adr_release", "repo",
            "PASS" if target == EXPECTED_RELEASE else "WARN",
            f"ADR-0002 targets Fedora {target}; verifier expected {EXPECTED_RELEASE}"
            + ("" if target == EXPECTED_RELEASE else " — update ADR/docs before switching release"))


# ------------------------------------------------------------ release gate --
GATE = E["VB_RELEASE_GATE"] == "1"
DOCS_SHA_ONLY = E["VB_DOCS_SHA_ONLY"] == "1"


def gate_add(cid, ok, detail, path=None, extra=None):
    """Release-gate check: PASS/FAIL in gate mode, not emitted in dev mode."""
    if not GATE:
        return bool(ok)
    add(cid, "release_gate", "PASS" if ok else "FAIL", detail, path=path, extra=extra)
    return bool(ok)


def docs_add(cid, ok, detail, path=None, extra=None):
    """Docs check: FAIL in gate mode, WARN otherwise (dev mode stays non-blocking)."""
    status = "PASS" if ok else ("FAIL" if GATE else "WARN")
    add(cid, "docs", status, detail, path=path, extra=extra)
    return bool(ok)


def _read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _sha_file(path):
    try:
        return sha256(Path(path))
    except OSError:
        return None


def _staged_rootfs():
    """Return (path, layout) of the newest assembled rootfs staging tree.

    ADR-0004 D4: the delivery layout is FLAT (partition root == rootfs root).
    A historical out/image-build/*/rootfs/native-root tree is still discovered so
    an old bundle can be audited, but it is reported as the obsolete layout and
    the release gate rejects it.
    """
    if ROOTFS is not None and (ROOTFS / "etc/liuqin-fedora-root").is_file():
        return ROOTFS, "flat" if ROOTFS.name in ("root", "rootfs") else ROOTFS.name
    if BUNDLE is not None:
        # The explicitly selected bundle is the verification subject.  Only its
        # own assembled tree may be used: falling back to the newest unrelated
        # out/image-build tree would attribute another build's rootfs to this
        # bundle.  A custom --work tree must be passed via
        # --rootfs explicitly.
        bases = [PROJECT / "out/image-build" / BUNDLE.name]
    else:
        bases = sorted((PROJECT / "out/image-build").glob("*"), reverse=True)
    cands = []
    for base in bases:
        for name, layout in (("rootfs/root", "flat"), ("rootfs", "flat"),
                             ("rootfs/native-root", "native-root")):
            d = base / name
            if d.is_dir() and (d / "etc/liuqin-fedora-root").is_file():
                cands.append((d.stat().st_mtime, d, layout))
    if cands:
        cands.sort(key=lambda x: x[0], reverse=True)
        return cands[0][1], cands[0][2]
    return None, None


def _bundle_meta():
    if E.get("VB_SKIP_BUNDLE") == "1" or BUNDLE is None or not (BUNDLE / "bundle.json").is_file():
        return None
    try:
        return read_json(BUNDLE / "bundle.json")
    except Exception:  # noqa: BLE001
        return None


def _read_rpm_payload(rpm_path, member):
    bsd = shutil.which("bsdtar")
    if not bsd:
        return None
    r = run([bsd, "-xOf", str(rpm_path), f"./{member}"])
    if r is None or r.returncode != 0:
        return None
    return r.stdout


def _list_rpm(rpm_path):
    bsd = shutil.which("bsdtar")
    if not bsd:
        return None
    r = run([bsd, "-tf", str(rpm_path)])
    if r is None or r.returncode != 0:
        return None
    return r.stdout.splitlines()


def _ext4_label_and_magic(path):
    try:
        with open(path, "rb") as f:
            f.seek(1024)
            sb = f.read(1024)
    except OSError:
        return None, None
    if len(sb) < 200:
        return None, None
    magic = struct.unpack_from("<H", sb, 56)[0]
    label = sb[120:136].split(b"\x00", 1)[0].decode("utf-8", "replace")
    return magic, label


def load_docs_sha():
    """Docs<->artifact sha256 consistency (docs/maintenance/kernel-build.md etc.)."""
    allowed = set()
    docs = [
        PROJECT / "docs/maintenance/kernel-build.md",
        PROJECT / "docs/maintenance/boot-initramfs.md",
        PROJECT / "docs/maintenance/kernel-rpm.md",
        PROJECT / "docs/build/image-build.md",
    ]
    # every current artifact file digest is allowed to be quoted in docs
    artifact_globs = [
        "out/boot/*", "out/boot/initramfs/*", "out/boot/toolchain/*",
        "out/kernel/dist/*", "out/kernel-fedora/dist/*",
        "out/rpms-kernel/**/*", "images/**/*", "cache/upstream-v0.6.0/*",
    ]
    for pattern in artifact_globs:
        for f in PROJECT.glob(pattern):
            if f.is_file() and f.stat().st_size < 512 * 1024 * 1024:
                digest = _sha_file(f)
                if digest:
                    allowed.add(digest)
    # reference-release digests (upstream baseline, not all files are cached)
    for sums in (PROJECT / "cache/upstream-v0.6.0/SHA256SUMS",
                 PROJECT / "out/kernel/SHA256SUMS", PROJECT / "out/kernel-fedora/SHA256SUMS"):
        if sums.is_file():
            for digest, _rel in parse_sums(sums):
                if digest:
                    allowed.add(digest)
    # project source files whose sha256 is quoted in provenance text (e.g. the
    # initramfs/init fork sha in docs/maintenance/boot-initramfs.md); these are repository
    # files, not build artifacts, so they must be allowed explicitly.
    for source_rel in ("initramfs/init", "tools/build-root-contract.py"):
        source_file = PROJECT / source_rel
        if source_file.is_file():
            digest = _sha_file(source_file)
            if digest:
                allowed.add(digest)
    # hashes recorded inside build metadata (e.g. busybox source tarball sha)
    meta_files = [
        PROJECT / "out/boot/build-info.json",
        PROJECT / "out/boot/initramfs/initramfs-info.json",
        PROJECT / "out/boot/toolchain/busybox-build-info.json",
        PROJECT / "out/kernel/build-info.json",
        PROJECT / "out/kernel-fedora/build-info.json",
        PROJECT / "out/installer/build-info.json",
        PROJECT / "out/rpms-kernel/build-info.json",
        PROJECT / "out/rpms-kernel/dist/build-info.json",
    ]
    def _collect_digests(obj):
        if isinstance(obj, str):
            if re.fullmatch(r"[0-9a-f]{64}", obj):
                allowed.add(obj)
        elif isinstance(obj, dict):
            for v in obj.values():
                _collect_digests(v)
        elif isinstance(obj, list):
            for v in obj:
                _collect_digests(v)
    for mf in meta_files:
        if mf.is_file():
            try:
                _collect_digests(read_json(mf))
            except Exception:  # noqa: BLE001
                pass
    for bi in (PROJECT / "images").glob("*/manifests/*.json"):
        try:
            _collect_digests(read_json(bi))
        except Exception:  # noqa: BLE001
            pass
    bj = PROJECT / "cache/upstream-v0.6.0/bundle.json"
    if bj.is_file():
        try:
            for digest in read_json(bj).get("files", {}).values():
                allowed.add(digest)
        except Exception:  # noqa: BLE001
            pass
    zip_path = PROJECT / "cache/upstream-v0.6.0/kernel-build-proof.zip"
    if zip_path.is_file():
        try:
            import zipfile
            with zipfile.ZipFile(zip_path) as zf:
                if "SHA256SUMS" in zf.namelist():
                    for line in zf.read("SHA256SUMS").decode("utf-8", "replace").splitlines():
                        m = re.match(r"^([0-9a-f]{64})\s+", line)
                        if m:
                            allowed.add(m.group(1))
                if "build-info.json" in zf.namelist():
                    bi = json.loads(zf.read("build-info.json"))
                    for v in (bi.get("artifacts") or {}).values():
                        if isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v):
                            allowed.add(v)
                    cfg = bi.get("config_sha256")
                    if isinstance(cfg, str):
                        allowed.add(cfg)
        except Exception:  # noqa: BLE001
            pass
    # checked-in synthetic example manifest hashes (documented as fake)
    for man in (PROJECT / "tools/examples").glob("*manifest*"):
        for line in _read_text(man).splitlines():
            m = re.match(r"^([0-9a-f]{64})\s+/", line)
            if m:
                allowed.add(m.group(1))
    # git commit pins quoted in the docs (40-hex; abbreviated prefixes pass prefix match)
    commit_sources = [PROJECT / "docs/maintenance/upstream-tracking.md", PROJECT / "scripts/fetch-upstream.sh",
                      PROJECT / "kernel/source.json"]
    for src in commit_sources:
        if src.is_file():
            for m in re.finditer(r"\b[0-9a-f]{40}\b", _read_text(src)):
                allowed.add(m.group(0))
    for src in (PROJECT / "upstream/xiaomipad-6pro-mainline/kernel/source.json",
                PROJECT / "cache/upstream-v0.6.0/bundle.json"):
        if src.is_file():
            try:
                obj = read_json(src)
                for key in ("commit", "upstream_base", "kernel_commit", "project_commit",
                            "root_build_project_commit"):
                    v = obj.get(key)
                    if isinstance(v, str) and re.fullmatch(r"[0-9a-f]{40}", v):
                        allowed.add(v)
            except Exception:  # noqa: BLE001
                pass
    # baseline digests that docs legitimately quote (upstream device-tested build)
    allowed.update({
        "7a368e58291f974f1cebd1e91e81ce8edc7256a19f75c4baea3fffd883157900",  # v0.6.0 boot.img
        "885faaab7dad9de85a2f4fd89307ed57459e4893d8d83477cfdc918950aa8619",  # final DTB
        "d5a22bc04cff813012b5618a4c7c888b561ab8c530bc39f036006c7d73d18b44",  # upstream Image
        "2eac03a8d9bc607db8e761f62c0fcc11a2a9ef9de8b171ad12f4bad2fbd90d55",  # upstream Image.gz
        "bbb3e271b965a49fb50e18bde32ba647ae801acd6a6bf6e706272993f8a2d4ea",  # raw board DTB
        "29a4fd23019bd1179770485b9507b418b357f141ac9e0f949f120fdc4ea4639f",  # upstream .config
    })
    allowed_prefixes = {d[:max(8, len(d))] for d in allowed}
    unknown = []
    total = 0
    for doc in docs:
        if not doc.is_file():
            continue
        text = _read_text(doc)
        for m in re.finditer(r"\b([0-9a-f]{64})\b", text):
            total += 1
            digest = m.group(1)
            if digest not in allowed:
                unknown.append(f"{doc.name}:{digest[:12]}")
        # abbreviated digests quoted with an ellipsis, e.g. `94a7e680dbc90ad4…`
        for m in re.finditer(r"\b([0-9a-f]{8,64})(?:…|\.\.\.)", text):
            total += 1
            prefix = m.group(1)
            if not any(d.startswith(prefix) for d in allowed):
                unknown.append(f"{doc.name}:{prefix[:12]}…")
    docs_add("docs.sha.scan", True, f"scanned {total} sha256 references in artifact docs")
    docs_add("docs.sha.known", not unknown,
             "every quoted artifact sha256 matches a current artifact or the upstream baseline"
             if not unknown else
             f"{len(unknown)} stale/unresolvable sha256 reference(s): " + ", ".join(unknown[:8]))
    image_shas = [x for x in (_sha_file(PROJECT / "out/kernel-fedora/dist/Image"),
                              _sha_file(PROJECT / "out/kernel/dist/Image")) if x]
    kb = _read_text(PROJECT / "docs/maintenance/kernel-build.md")
    image_ok = bool(image_shas) and any(
        (x in kb) or (x[:16] in kb) for x in image_shas)
    docs_add("docs.sha.kernel_image", image_ok,
             "docs/maintenance/kernel-build.md quotes the current kernel Image sha256"
             if image_ok else
             "docs/maintenance/kernel-build.md does not quote the current kernel Image sha256")


def load_release_gate():
    if not GATE:
        return
    # --- bundle ------------------------------------------------------------
    bdata = _bundle_meta()
    gate_add("gate.bundle.present", bdata is not None,
             f"release bundle: {BUNDLE}" if bdata is not None else
             "no assembled bundle under images/*/bundle.json (run scripts/build-image.sh --build-mode release)")
    if bdata:
        gate_add("gate.bundle.device_ready", bdata.get("device_ready") is True,
                 f"device_ready={bdata.get('device_ready')!r}")
        gate_add("gate.bundle.offline_only", bdata.get("offline_only") is False,
                 f"offline_only={bdata.get('offline_only')!r}")
        reasons = bdata.get("device_ready_reasons") or []
        gate_add("gate.bundle.reasons", not reasons,
                 "no device_ready reasons" if not reasons else "device_ready reasons: " + "; ".join(map(str, reasons[:4])))
        contract = bdata.get("contract")
        gate_add("gate.bundle.contract", bool(contract), f"contract={contract!r}")
        ctr = contract if isinstance(contract, dict) else {}
        gate_add("gate.bundle.contract_v2",
                 ctr.get("header") == "LIUQIN_FEDORA_ROOT_CONTRACT_V2"
                 and int(ctr.get("topology_entries") or 0) >= 8,
                 f"bundle carries contract v2: entries={ctr.get('topology_entries')} "
                 f"sha256={str(ctr.get('sha256'))[:16]}…")
        gate_add("gate.bundle.contract_no_content_pins",
                 int(ctr.get("content_pins") or 0) == 0,
                 "bundle contract has no v1 sha256 content pins (ADR-0004 D2)")
        manifest_contract = None
        if ctr.get("source"):
            manifest_contract = BUNDLE / str(ctr["source"])
        if manifest_contract is not None and manifest_contract.is_file():
            want = manifest_contract.read_bytes()
            embedded = {}
            for image_name in ("boot.img", "installer.img"):
                image = BUNDLE / image_name
                if not image.is_file():
                    embedded[image_name] = "missing image"
                    continue
                try:
                    cpio = gzip.decompress(boot_ramdisk(image))
                    got = cpio_member(cpio, "etc/liuqin-fedora-root.contract")
                except Exception as exc:  # noqa: BLE001
                    embedded[image_name] = "extract error: " + str(exc)
                    continue
                embedded[image_name] = "ok" if got == want else "differs from bundle manifest copy"
            gate_add("gate.bundle.contract_embedded",
                     all(v == "ok" for v in embedded.values()),
                     "boot.img and installer.img embed the same contract v2 as the bundle manifest: "
                     + json.dumps(embedded))
        else:
            gate_add("gate.bundle.contract_embedded", False,
                     "bundle has no manifests/liuqin-fedora-root.contract to compare the embedded copies with")
        # qcom_q6v5_pas asks for adsp.mbn ~2.6 s into the boot, while the
        # kernel is still running the ramdisk, and never retries after
        # switch_root.  An image whose ramdisk lacks the DSP firmware (and the
        # AudioReach topology the card loads) boots to "no soundcards" on liuqin
        # even though the same files are present on the rootfs.  Checking the
        # delivered boot.img payload is the only offline check that sees this.
        dsp_audio = {}
        cpio = None
        boot_image = BUNDLE / "boot.img"
        if boot_image.is_file():
            try:
                cpio = gzip.decompress(boot_ramdisk(boot_image))
                dsp_audio["adsp.mbn"] = cpio_member(
                    cpio, "lib/firmware/qcom/sm8475/liuqin/adsp.mbn") is not None
                dsp_audio["tplg"] = cpio_member(
                    cpio, "lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin") is not None
            except Exception as exc:  # noqa: BLE001
                dsp_audio["error"] = str(exc)
        else:
            dsp_audio["error"] = "bundle has no boot.img"
        gate_add("gate.bundle.dsp_audio_ramdisk",
                 bool(dsp_audio.get("adsp.mbn")) and bool(dsp_audio.get("tplg")),
                 "boot.img ramdisk carries the DSP firmware and AudioReach topology: "
                 + json.dumps(dsp_audio, sort_keys=True))
        # The firmware pool record must match the shipped per-file
        # manifest, and the ramdisk must carry every stage-1-critical category.
        firmware = bdata.get("firmware") or {}
        pool_detail = "no firmware record in bundle.json (built without --firmware-pool)"
        pool_ok = False
        if firmware:
            manifest_name = firmware.get("manifest") or "manifests/firmware-pool.manifest"
            manifest_path = BUNDLE / str(manifest_name)
            recorded = firmware.get("manifest_sha256")
            actual = sha256(manifest_path) if manifest_path.is_file() else None
            entries = 0
            if manifest_path.is_file():
                entries = len([line for line in manifest_path.read_text().splitlines()
                               if line.strip()])
            want_files = int(firmware.get("files") or 0)
            pool_ok = (bool(recorded) and recorded == actual and
                       want_files > 0 and entries == want_files)
            pool_detail = ("firmware pool: files=%s manifest entries=%d "
                           "manifest sha256=%s recorded=%s"
                           % (firmware.get("files"), entries,
                              str(actual)[:16] + "…" if actual else None,
                              str(recorded)[:16] + "…" if recorded else None))
        gate_add("gate.bundle.firmware_pool", pool_ok, pool_detail)
        required_fw = {
            "touch": "lib/firmware/novatek/liuqin/",
            "bluetooth": "lib/firmware/qca/",
            "wlan": "lib/firmware/ath11k/WCN6855/hw2.0/",
            "wlan-hsp2": "lib/firmware/updates/ath11k/WCN6855/hw2.1/amss.bin",
            "regulatory": "lib/firmware/regulatory.db",
            "gpu": "lib/firmware/qcom/a730_sqe.fw",
            "dsp": "lib/firmware/qcom/sm8475/liuqin/adsp.mbn",
            "audio-topology": "lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin",
        }
        fw_missing = []
        if cpio is None:
            fw_missing = ["boot.img ramdisk is unreadable"]
        else:
            names = cpio_members(cpio)
            for category, needle in required_fw.items():
                if needle.endswith("/"):
                    if not any(name.startswith(needle) for name in names):
                        fw_missing.append(category)
                elif needle not in names:
                    fw_missing.append(category)
        gate_add("gate.bundle.firmware_complete", not fw_missing,
                 "boot.img ramdisk carries all stage-1-critical firmware categories"
                 if not fw_missing else
                 "missing firmware categories in the ramdisk: " + ", ".join(fw_missing))
        privileges = bdata.get("privileged_expectations") or {}
        gate_add("gate.bundle.privileged_expectations",
                 bool(privileges.get("entries")),
                 f"privileged-file expectations: entries={privileges.get('entries')} "
                 f"setuid/setgid={privileges.get('setuid_setgid')} "
                 f"capabilities={privileges.get('capabilities')} "
                 f"sha256={str(privileges.get('sha256'))[:16]}… "
                 f"(derived from the assembled rootfs)")
        manifest_privileges = None
        if privileges.get("source"):
            manifest_privileges = BUNDLE / str(privileges["source"])
        if manifest_privileges is not None and manifest_privileges.is_file():
            want = manifest_privileges.read_bytes()
            try:
                cpio = gzip.decompress(boot_ramdisk(BUNDLE / "installer.img"))
                got = cpio_member(cpio, "etc/liuqin-installer-privileges")
                helper = cpio_member(cpio, "usr/lib/liuqin/install-privileges.sh")
            except Exception as exc:  # noqa: BLE001
                got = helper = None
                gate_add("gate.bundle.privileges_embedded", False,
                         "cannot unpack installer.img ramdisk: " + str(exc))
            else:
                gate_add("gate.bundle.privileges_embedded",
                         got == want and helper is not None and len(helper) > 0,
                         "installer.img embeds the same rootfs-derived privileged-file "
                         "expectations and the validator helper as the bundle manifest")
        else:
            gate_add("gate.bundle.privileges_embedded", False,
                     "bundle has no manifests/installer-privileges.txt")
        # Cross-check the bundle's installer-image.json against
        # the ACTUAL installer.img ramdisk.  SHA256SUMS only proves the manifest
        # file was not modified; this proves its content describes the shipped
        # ramdisk (file hashes, contract, privileged expectations).
        installer_manifest = BUNDLE / "manifests/installer-image.json"
        installer_image = BUNDLE / "installer.img"
        if installer_manifest.is_file() and installer_image.is_file():
            try:
                im = read_json(installer_manifest)
                members = cpio_members(gzip.decompress(boot_ramdisk(installer_image)))
                expected = im.get("files") or {}
                missing = [rel for rel in expected
                           if rel.lstrip("./") not in members]
                mismatch = [rel for rel, digest in expected.items()
                            if rel.lstrip("./") in members
                            and hashlib.sha256(members[rel.lstrip("./")]).hexdigest() != digest]
                contract_meta = im.get("contract") or {}
                priv_meta = im.get("privileged_expectations") or {}
                contract_bytes = members.get("etc/liuqin-fedora-root.contract")
                priv_bytes = members.get("etc/liuqin-installer-privileges")
                contract_ok = bool(contract_meta.get("sha256")) and contract_bytes is not None and \
                    hashlib.sha256(contract_bytes).hexdigest() == contract_meta["sha256"]
                priv_ok = (not priv_meta.get("sha256")) or (
                    priv_bytes is not None
                    and hashlib.sha256(priv_bytes).hexdigest() == priv_meta["sha256"])
                detail = (f"installer-image.json vs installer.img ramdisk: "
                          f"{len(expected)} files ({len(missing)} missing, "
                          f"{len(mismatch)} hash mismatch); contract="
                          f"{'ok' if contract_ok else 'STALE'}; "
                          f"privileges={'ok' if priv_ok else 'STALE'}")
                if missing:
                    detail += "; missing=" + ", ".join(missing[:5])
                if mismatch:
                    detail += "; mismatched=" + ", ".join(mismatch[:5])
                gate_add("gate.bundle.installer_manifest_match",
                         not missing and not mismatch and contract_ok and priv_ok, detail)
            except Exception as exc:  # noqa: BLE001
                gate_add("gate.bundle.installer_manifest_match", False,
                         "cannot cross-check installer-image.json: " + str(exc))
        else:
            gate_add("gate.bundle.installer_manifest_match", False,
                     "bundle lacks manifests/installer-image.json or installer.img")

        files = bdata.get("files") or {}
        required = ("boot.img", "root.img", "rootfs.tar.gz", "installer.img")
        problems = []
        for name in required:
            p = BUNDLE / name
            if not p.is_file():
                problems.append(f"missing {name}")
            elif files.get(name) and _sha_file(p) != files[name]:
                problems.append(f"{name} sha256 mismatch")
        gate_add("gate.bundle.payloads", not problems,
                 "boot.img/root.img/rootfs.tar.gz/installer.img present and hashed"
                 if not problems else "; ".join(problems), path=BUNDLE)
        # POSITIVE kernel provenance.  The bundle's recorded
        # source must equal the delivered boot.img build-info label, the release
        # must agree, and the kernel bytes inside boot.img must match the payload
        # sha that build-info recorded (no "does not contain a bad string" test).
        src = str(bdata.get("kernel_payload_source") or "")
        boot_meta = None
        bmeta_path = BUNDLE / "manifests/boot-build-info.json"
        if bmeta_path.is_file():
            try:
                boot_meta = read_json(bmeta_path)
            except Exception:  # noqa: BLE001
                boot_meta = None
        bk = ((boot_meta or {}).get("payload") or {}).get("kernel") or {}
        delivered_kernel = BOOT_PAYLOAD.get("kernel")
        delivered_sha = (hashlib.sha256(delivered_kernel).hexdigest()
                         if delivered_kernel else None)
        kernel_checks = {
            "source recorded": bool(src),
            "source is kernel-liuqin RPM": ("kernel-liuqin RPM" in src
                                            and "out/kernel/dist" not in src),
            "boot build-info label == bundle source": bool(boot_meta) and bk.get("provenance") == src,
            "release agrees with boot build-info": bool(bdata.get("kernel_release"))
            and bk.get("release") == bdata.get("kernel_release"),
            "kernel payload sha recorded": bool(bk.get("gzip_sha256") or bk.get("image_sha256")),
            "delivered boot.img kernel sha == build-info": bool(bk.get("gzip_sha256"))
            and delivered_sha == bk.get("gzip_sha256"),
        }
        gate_add("gate.bundle.kernel_source", all(kernel_checks.values()),
                 "; ".join(f"{key}={'ok' if value else 'NO'}"
                           for key, value in kernel_checks.items())
                 + f"; bundle_source={src!r}; boot_build_info_kernel="
                   f"source={bk.get('source')!r} provenance={bk.get('provenance')!r} "
                   f"release={bk.get('release')!r} gzip_sha256={str(bk.get('gzip_sha256'))[:16]}…")
    # --- boot metadata / canonical DTB ------------------------------------
    meta = None
    if META is not None and META.is_file():
        try:
            meta = read_json(META)
        except Exception:  # noqa: BLE001
            meta = None
    gate_add("gate.boot.metadata", meta is not None, f"build-info.json: {META}")
    if meta:
        gate_add("gate.boot.device_ready", meta.get("device_ready") is True,
                 f"boot build-info device_ready={meta.get('device_ready')!r}")
        dtb = (meta.get("payload") or {}).get("dtb") or {}
        k = (meta.get("payload") or {}).get("kernel") or {}
        gate_add("gate.boot.dtb_source", dtb.get("source") == "stock-rom",
                 f"DTB source={dtb.get('source')!r} (canonical path must be 'stock-rom')")
        gate_add("gate.boot.canonical_stock_rom",
                 meta.get("canonical_stock_rom_rebuild") is True or dtb.get("source") == "stock-rom",
                 f"canonical_stock_rom_rebuild={meta.get('canonical_stock_rom_rebuild')!r}")
        gate_add("gate.boot.kernel_source", k.get("source") == "kernel-build",
                 f"kernel source={k.get('source')!r}")
        gate_add("gate.boot.dtb_size", int(dtb.get("bytes") or 0) >= 200000,
                 f"final DTB {dtb.get('bytes')} bytes (ABL overlay-grown DTB expected >=200000)")
    # --- kernel config (Fedora fragment / SELinux) ------------------------
    kcfg = PROJECT / "out/kernel-fedora/dist/config"
    kaudit = PROJECT / "out/kernel-fedora/config-audit.json"
    audit = None
    if kaudit.is_file():
        try:
            audit = read_json(kaudit)
        except Exception:  # noqa: BLE001
            audit = None
    if kcfg.is_file():
        txt = _read_text(kcfg)
        missing = []
        for needle in ("CONFIG_SECURITY_SELINUX=y", "CONFIG_SECURITY_SELINUX_BOOTPARAM=y",
                       "CONFIG_DEFAULT_SECURITY_SELINUX=y"):
            if needle not in txt:
                missing.append(needle)
        if "CONFIG_LSM=" not in txt or "selinux" not in txt.split("CONFIG_LSM=")[1].splitlines()[0]:
            missing.append("CONFIG_LSM contains selinux")
        if "CONFIG_SECURITY_APPARMOR=y" in txt or "CONFIG_DEFAULT_SECURITY_APPARMOR=y" in txt:
            missing.append("AppArmor still enabled as LSM")
        gate_add("gate.kernel.selinux", not missing,
                 "kernel config has SELinux=y, Fedora LSM order, AppArmor off"
                 if not missing else "kernel config missing: " + ", ".join(missing), path=kcfg)
    else:
        gate_add("gate.kernel.selinux", False,
                 "out/kernel-fedora/dist/config missing (release kernel must be built with kernel/config/liuqin-fedora.config)")
    gate_add("gate.kernel.fedora_ready",
             bool(audit and audit.get("fedora_ready") is True and not audit.get("missing")),
             f"config-audit fedora_ready={audit.get('fedora_ready') if audit else 'missing'} "
             f"missing={audit.get('missing') if audit else 'missing'}", path=kaudit)
    # --- rootfs staging / contract / login manager / SELinux / layout -----
    staged, layout = _staged_rootfs()
    gate_add("gate.rootfs.staged", staged is not None,
             f"staged rootfs: {staged} (layout={layout})" if staged else
             "no assembled rootfs staging tree (out/image-build/*/rootfs/root, flat layout); run build-image.sh")
    # Prefer the contract that is actually delivered in the bundle (ADR-0004
    # D1: the bundle is self-describing); fall back to the initramfs build dir
    # only when no bundle contract is available.
    contract = None
    bundle_contract = None
    if BUNDLE is not None:
        candidate = BUNDLE / "manifests/liuqin-fedora-root.contract"
        if candidate.is_file():
            bundle_contract = candidate
    if bundle_contract is not None:
        contract = bundle_contract
    elif INITRAMFS is not None:
        cp = INITRAMFS.parent / "liuqin-fedora-root.contract"
        if cp.is_file():
            contract = cp
    contract_lines = []
    if contract is not None:
        contract_lines = [l for l in _read_text(contract).splitlines() if l.strip()]
    info = {}
    info_path = INITRAMFS.parent / "initramfs-info.json" if INITRAMFS is not None else None
    if info_path is not None and info_path.is_file():
        try:
            info = read_json(info_path)
        except Exception:  # noqa: BLE001
            info = {}
    rc = info.get("root_contract") or {}
    # A contract shipped in the bundle was generated by build-image from the
    # assembled rootfs (never the synthetic example manifest).
    synthetic = (False if bundle_contract is not None
                 else rc.get("generated_from_synthetic_example_manifest"))
    gate_add("gate.contract.present", contract is not None, f"contract: {contract}")
    gate_add("gate.contract.non_synthetic", synthetic is False,
             f"generated_from_synthetic_example_manifest={synthetic!r}")
    topology_lines = [l for l in contract_lines
                      if l and not l.startswith("#") and l != "LIUQIN_FEDORA_ROOT_CONTRACT_V2"]
    v1_content_pins = [l for l in contract_lines if re.fullmatch(r"[0-9a-f]{64}  /\S+", l)]
    gate_add("gate.contract.v2_topology_entries", len(topology_lines) >= 8,
             f"{len(topology_lines)} v2 topology entries (>=8 required)")
    if contract is not None:
        gate_add("gate.contract.header_v2",
                 contract_lines[:1] == ["LIUQIN_FEDORA_ROOT_CONTRACT_V2"],
                 "header LIUQIN_FEDORA_ROOT_CONTRACT_V2"
                 if contract_lines[:1] == ["LIUQIN_FEDORA_ROOT_CONTRACT_V2"] else "bad contract header")
    gate_add("gate.contract.no_content_pins", not v1_content_pins,
             "contract has no v1 sha256 content pins (dnf upgrades and config edits stay bootable)"
             if not v1_content_pins else
             "P0 OPEN: the delivered contract still contains v1 sha256 content pins; ordinary package "
             "upgrades/config edits would be rejected at boot (ADR-0004 D2)")
    # Kernel identity must be present as a topology 'file' entry, never as a
    # content pin: the release check is documented as warn-only at boot.
    kernel_entries = [l for l in contract_lines if l.endswith("/usr/share/liuqin/kernel.release")]
    gate_add("gate.contract.kernel_identity_topology_only",
             kernel_entries == ["file /usr/share/liuqin/kernel.release"],
             "kernel.release is a topology entry only (no content hash, ADR-0004 D2-C)"
             if kernel_entries == ["file /usr/share/liuqin/kernel.release"] else
             f"kernel.release entries are {kernel_entries!r}; expected exactly the topology 'file' entry")
    gate_add("gate.contract.no_kernel_identity_pins", not kernel_entries or all(
        not re.fullmatch(r"[0-9a-f]{64}  /\S+", l) for l in kernel_entries),
        "contract does not hash-pin kernel identity (dnf kernel upgrade safe)")
    marker = staged / "etc/liuqin-fedora-root" if staged else None
    if marker is not None and marker.is_file():
        content = marker.read_bytes()
        mode = oct(marker.stat().st_mode & 0o777)
        gate_add("gate.rootfs.marker",
                 content == b"liuqin-fedora-root-v1\n" and mode == "0o644",
                 f"/etc/liuqin-fedora-root content={content!r} mode={mode}")
    else:
        gate_add("gate.rootfs.marker", False, "staged rootfs marker /etc/liuqin-fedora-root missing")
    # login manager: initramfs assertion vs rootfs display-manager.service vs image-contract
    lm_init = lm_root = lm_contract = None
    initramfs_bytes = None
    if INITRAMFS is not None and INITRAMFS.is_file():
        initramfs_bytes = INITRAMFS.read_bytes()
    elif BOOT_PAYLOAD.get("ramdisk"):
        # The boot ramdisk that is actually DELIVERED inside
        # boot.img is the one to audit; do not require a separate out/boot file.
        initramfs_bytes = BOOT_PAYLOAD["ramdisk"]
    if initramfs_bytes is not None:
        try:
            raw = gzip.decompress(initramfs_bytes)
            if b"/usr/bin/plasmalogin" in raw:
                lm_init = "plasmalogin"
            elif b"/usr/bin/gdm" in raw:
                lm_init = "gdm"
            elif b"/usr/bin/sddm" in raw:
                lm_init = "sddm"
        except Exception:  # noqa: BLE001
            lm_init = None
    dm = staged / "etc/systemd/system/display-manager.service" if staged else None
    if dm is not None and dm.is_symlink():
        lm_root = Path(os.readlink(dm)).name.removesuffix(".service")
    ic = staged / "etc/liuqin/image-contract" if staged else None
    if ic is not None and ic.is_file():
        for line in _read_text(ic).splitlines():
            if line.startswith("LOGIN_MANAGER="):
                lm_contract = line.split("=", 1)[1].strip()
    gate_add("gate.login_manager",
             lm_init is not None and lm_init == lm_root == lm_contract and
             lm_contract in ("plasmalogin", "sddm", "gdm") and
             (staged / f"usr/lib/systemd/system/{lm_contract}.service").is_file() and
             (staged / f"usr/bin/{lm_contract}").is_file(),
             f"initramfs={lm_init!r} display-manager={lm_root!r} image-contract={lm_contract!r} "
             f"(all must agree; unit+executable present)")
    # SELinux userland decision
    sel = staged / "etc/selinux/config" if staged else None
    sel_value = None
    if sel is not None and sel.is_file():
        for line in _read_text(sel).splitlines():
            if line.strip().startswith("SELINUX="):
                sel_value = line.split("=", 1)[1].strip()
    gate_add("gate.selinux.userland", sel_value in ("permissive", "enforcing"),
             f"/etc/selinux/config SELINUX={sel_value!r} (must be permissive/enforcing when kernel SELinux=y)")
    # FLAT layout (ADR-0004 D4) + root.img label
    gate_add("gate.rootfs.flat_layout", layout == "flat" if layout else False,
             f"root layout={layout!r} (release root must BE the partition root: flat install)")
    dbg_native = ROOTFS is not None and (ROOTFS / "native-root").is_dir()
    gate_add("gate.rootfs.no_native_root", not dbg_native,
             "no nested native-root/ level in the staged tree"
             if not dbg_native else "staged tree still contains a native-root/ directory (obsolete layout)")
    if bdata:
        rootimg = BUNDLE / "root.img"
        if rootimg.is_file():
            magic, label = _ext4_label_and_magic(rootimg)
            gate_add("gate.bundle.rootimg", magic == 0xEF53 and label == "LIUQIN_ROOT",
                     f"root.img ext4 magic={magic!r} label={label!r}")
        else:
            gate_add("gate.bundle.rootimg", False, "bundle root.img missing")
    # --- kernel release chain ---------------------------------------------
    vals = {}
    if meta:
        vals["boot.build-info"] = str((meta.get("payload") or {}).get("kernel", {}).get("release") or "")
    if info:
        vals["initramfs-info"] = str(info.get("kernel_release_expected") or "")
    if bdata:
        vals["bundle.json"] = str(bdata.get("kernel_release") or "")
    kbi = PROJECT / "out/kernel-fedora/build-info.json"
    if kbi.is_file():
        try:
            vals["kernel-fedora/build-info"] = str(read_json(kbi).get("kernel_release") or "")
        except Exception:  # noqa: BLE001
            pass
    if staged is not None:
        kr = staged / "usr/share/liuqin/kernel.release"
        if kr.is_file():
            vals["staged-rootfs"] = kr.read_text(errors="replace").strip()
        km = staged / "usr/share/liuqin/kernel-modules.manifest"
        if km.is_file():
            gate_add("gate.rootfs.modules_manifest", km.stat().st_size > 0,
                     f"kernel-modules.manifest {km.stat().st_size} bytes")
    rpms = sorted((PROJECT / "out/rpms-kernel").rglob("kernel-liuqin-*.aarch64.rpm")) if \
        (PROJECT / "out/rpms-kernel").is_dir() else []
    rpm_release = None
    if rpms:
        rpm_release = _read_rpm_payload(rpms[0], "usr/share/liuqin/kernel.release")
        rpm_release = rpm_release.strip() if rpm_release else None
        if rpm_release:
            vals["kernel-rpm"] = rpm_release
    nonempty = {k: v for k, v in vals.items() if v}
    unique = set(nonempty.values())
    gate_add("gate.release.chain",
             len(nonempty) >= 4 and len(unique) == 1 and all(v.count("-") >= 1 for v in unique),
             "release chain: " + "; ".join(f"{k}={v or '<missing>'}" for k, v in sorted(vals.items()))
             if nonempty else "cannot determine kernel release chain")
    if len(nonempty) >= 4 and len(unique) == 1 and staged is not None:
        kver = unique.pop()
        gate_add("gate.rootfs.modules_path",
                 (staged / "usr/lib/modules" / kver).is_dir(),
                 f"/usr/lib/modules/{kver} present in staged rootfs")
    # --- kernel RPM payload ------------------------------------------------
    gate_add("gate.rpm.present", bool(rpms),
             f"kernel-liuqin RPM: {rpms[0]}" if rpms else
             "no out/rpms-kernel/**/kernel-liuqin-*.aarch64.rpm")
    if rpms:
        rpm = rpms[0]
        sums = None
        for cand in (rpm.parent.parent / "SHA256SUMS", rpm.parent / "SHA256SUMS",
                     PROJECT / "out/rpms-kernel/dist/SHA256SUMS",
                     PROJECT / "out/rpms-kernel/SHA256SUMS"):
            if cand.is_file():
                sums = cand
                break
        sum_ok = True
        if sums is not None:
            entries = {rel: dig for dig, rel in parse_sums(sums) if dig}
            if entries:
                sum_ok = any(Path(rel).name == rpm.name and digest == _sha_file(rpm)
                             for rel, digest in entries.items())
        gate_add("gate.rpm.sha256", sum_ok, f"SHA256SUMS: {sums}" if sum_ok else f"RPM sha256 not verifiable via {sums}")
        files = _list_rpm(rpm) or []
        ko = [f for f in files if f.endswith(".ko")]
        good = (rpm_release is not None
                and any("99-liuqin-android-boot.install" in f for f in files)
                and any(f.endswith("/liuqin-apply-boot") for f in files)
                and any("kernel-modules.manifest" in f for f in files)
                and any("kernel.release" in f for f in files)
                and len(ko) >= 400)
        cfg_rpm = _read_rpm_payload(rpm, "usr/share/liuqin/kernel-config") or ""
        sel_ok = "CONFIG_SECURITY_SELINUX=y" in cfg_rpm and "selinux" in cfg_rpm
        gate_add("gate.rpm.payload", good,
                 f"{rpm.name}: {len(ko)} .ko, kernel.release={rpm_release!r}, hook/apply-boot/manifest present")
        gate_add("gate.rpm.selinux_config", sel_ok,
                 "RPM-embedded kernel-config has SELinux=y" if sel_ok else
                 "RPM-embedded kernel-config lacks SELinux=y (RPM built from non-Fedora-config kernel)")
    # --- on-device update prerequisites (P0 refresh pipeline) -------------
    if staged is not None:
        rfm = staged / "usr/share/liuqin/rootfs.files.sha256"
        gate_add("gate.update.rootfs_manifest", rfm.is_file(),
                 "on-device rootfs hash manifest present (/usr/share/liuqin/rootfs.files.sha256)"
                 if rfm.is_file() else
                 "missing /usr/share/liuqin/rootfs.files.sha256 in rootfs: the kernel-update refresh "
                 "pipeline (liuqin-bootimg-refresh) requires it; ship it from image assembly")
    refresh = PROJECT / "kernel/fedora/liuqin-bootimg-refresh"
    gate_add("gate.update.refresh_tool", refresh.is_file(),
             f"on-device refresh tool: {refresh}" if refresh.is_file() else
             "missing kernel/fedora/liuqin-bootimg-refresh")
    if refresh.is_file() and contract is not None:
        # Contract v2 is topology-only, so rebuilding it from a stale manifest
        # cannot resurrect stale content hashes; this gate documents that the
        # on-device refresh inherits the same property.
        gate_add("gate.update.refresh_rebuilds_contract",
                 not v1_content_pins,
                 "refresh pipeline rebuilds the same topology v2 contract (no content pins to go stale)"
                 if not v1_content_pins else
                 "the shipped contract still carries content pins; a kernel/package upgrade makes the "
                 "rebuilt contract disagree with the tree and admission fails (ADR-0004 D2)")
    # --- update-path tooling safety ---------------------------------------
    hook = PROJECT / "kernel/fedora/99-liuqin-android-boot.install"
    if hook.is_file():
        txt = "\n".join(l for l in _read_text(hook).splitlines()
                         if not l.lstrip().startswith("#"))
        bad = []
        for pat, label in (
                (r"(?:^|[|;&(]\s*)(?:sudo\s+)?(?:qbootctl|fastboot)\b", "qbootctl/fastboot command"),
                (r"--set-active", "--set-active"),
                (r"of=/dev/", "raw device write")):
            if re.search(pat, txt):
                bad.append(label)
        gate_add("gate.update.hook_safety", not bad,
                 "staging hook has no qbootctl/fastboot/device-write tokens" if not bad
                 else "staging hook contains forbidden tokens: " + ", ".join(bad), path=hook)
        gate_add("gate.update.hook_device_ready", "device_ready" in txt,
                 "staging hook refuses device_ready!=true" if "device_ready" in txt
                 else "staging hook does not gate on device_ready")
    ab = PROJECT / "kernel/fedora/liuqin-apply-boot"
    if ab.is_file():
        txt = _read_text(ab)
        gate_add("gate.update.apply_boot_gate",
                 "LIUQIN_EXPERIMENTAL_DEVICE_WRITE" in txt and "--yes-write-device" in txt,
                 "liuqin-apply-boot has dry-run default + double write gate")
    # --- docs sha ----------------------------------------------------------
    load_docs_sha()


# ---------------------------------------------------------------- execute --
if DOCS_SHA_ONLY:
    try:
        load_docs_sha()
    except Exception as exc:  # noqa: BLE001
        add("internal.load_docs_sha", "internal", "FAIL",
            f"check crashed: {type(exc).__name__}: {exc}")
else:
    for fn in (load_boot, load_dtb, load_initramfs, load_metadata):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            add(f"internal.{fn.__name__}", "internal", "FAIL", f"check crashed: {type(exc).__name__}: {exc}")
    verify_sums(PROJECT / "out/boot/SHA256SUMS", PROJECT / "out/boot", "boot")
    verify_sums(PROJECT / "out/boot/initramfs/SHA256SUMS", PROJECT / "out/boot/initramfs", "initramfs")
    for fn in (load_rootfs, load_rootfs_manifest, load_rpms, load_bundle, load_repo):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            add(f"internal.{fn.__name__}", "internal", "FAIL", f"check crashed: {type(exc).__name__}: {exc}")
    if GATE:
        try:
            load_release_gate()
        except Exception as exc:  # noqa: BLE001
            add("internal.load_release_gate", "internal", "FAIL",
                f"release-gate crashed: {type(exc).__name__}: {exc}")

counts = {s: sum(1 for c in checks if c["status"] == s) for s in ("PASS", "FAIL", "WARN", "SKIP")}
result = "FAIL" if counts["FAIL"] else ("WARN" if counts["WARN"] else "PASS")
report = {
    "format": "liuqin-verify-bundle/v1",
    "generated_at": E["VB_TIMESTAMP"],
    "project_root": str(PROJECT),
    "mode": "release-gate" if GATE else ("docs-sha" if DOCS_SHA_ONLY else "dev"),
    "inputs": {
        "boot": str(BOOT) if BOOT else None,
        "initramfs": str(INITRAMFS) if INITRAMFS else None,
        "dtb": str(DTB) if DTB else None,
        "boot_metadata": str(META) if META else None,
        "rootfs": str(ROOTFS) if ROOTFS else None,
        "rootfs_profile": PROFILE,
        "expected_release": EXPECTED_RELEASE,
        "bundle": str(BUNDLE) if BUNDLE else None,
        "bundle_partial": BUNDLE_PARTIAL,
    },
    "summary": {**counts, "total": len(checks), "result": result},
    "categories": CATEGORIES,
    "checks": checks,
}
JSON_OUT.parent.mkdir(parents=True, exist_ok=True)
JSON_OUT.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n", encoding="utf-8")

if JSON_ONLY:
    print(json.dumps(report, indent=1, sort_keys=True))
    sys.exit(0 if (result != "FAIL" or ADVISORY) else 1)

if not QUIET:
    C = {"PASS": "\033[32m", "FAIL": "\033[31m", "WARN": "\033[33m", "SKIP": "\033[90m"} if COLOR else \
        {s: "" for s in ("PASS", "FAIL", "WARN", "SKIP")}
    RESET = "\033[0m" if COLOR else ""
    print("verify-bundle: liuqin Fedora ARM64 artifact structure verification")
    print(f"  boot     : {BOOT}")
    print(f"  initramfs: {INITRAMFS}")
    print(f"  dtb      : {DTB}")
    print(f"  rootfs   : {ROOTFS} (profile={PROFILE}, expected release={EXPECTED_RELEASE})")
    print(f"  bundle   : {BUNDLE} (partial={BUNDLE_PARTIAL})")
    print()
    last_cat = None
    for c in checks:
        if c["category"] != last_cat:
            print(f"-- {c['category']} --")
            last_cat = c["category"]
        print(f"  {C[c['status']]}[{c['status']}]{RESET} {c['id']}: {c['detail']}")
    print()
    print(f"SUMMARY: PASS {counts['PASS']}  FAIL {counts['FAIL']}  WARN {counts['WARN']}  "
          f"SKIP {counts['SKIP']}  total {len(checks)}  =>  RESULT: {result}")
    print(f"report: {JSON_OUT}")

fail = result == "FAIL" or (FAIL_ON_WARN and counts["WARN"] > 0)
if fail and not ADVISORY:
    if not QUIET:
        print("\nRESULT: FAIL — see failing checks above; re-run a single check by reading the JSON report.")
    sys.exit(1)
if fail and ADVISORY and not QUIET:
    print("\nADVISORY: failures reported but exit code forced to 0 (--advisory).")
sys.exit(0)
PY
