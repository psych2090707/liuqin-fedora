#!/usr/bin/env python3
"""compare-rootfs-releases.py — diff two liuqin rootfs manifests (44 vs 45, etc.).

Reads the machine-readable `rootfs.manifest` (format liuqin-rootfs-manifest/v1)
emitted by scripts/build-rootfs.sh and prints a markdown report comparing:

  * package set (added / removed names)
  * version changes for the components that matter on liuqin (KDE/Plasma, Qt,
    Mesa, linux-firmware & split firmware packages, systemd, glibc, GCC runtime,
    NetworkManager, PipeWire, Firefox, ...)
  * sizes read from sibling build-info.json when available

Usage:
  tools/compare-rootfs-releases.py OUT_A/rootfs.manifest OUT_B/rootfs.manifest [--out FILE]

Example:
  tools/compare-rootfs-releases.py out/rootfs/rootfs.manifest \
      out/rootfs-f45/rootfs.manifest --out out/rootfs-f45/diff-44-45.md

The script is read-only and stdlib-only; it never touches the rootfs trees.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Components whose version movement decides whether a release switch is safe.
KEY_PACKAGES = [
    # distribution / runtime
    "fedora-release",
    "glibc",
    "systemd",
    "libgcc",
    "libstdc++",
    "openssl-libs",
    "dbus-broker",
    # graphics / KDE
    "mesa-dri-drivers",
    "mesa-libEGL",
    "mesa-vulkan-drivers",
    "qt6-qtbase",
    "qt6-qtwayland",
    "plasma-workspace",
    "plasma-desktop",
    "kwin",
    "plasma-login-manager",
    "plasma-keyboard",
    "kscreen",
    "powerdevil",
    "xdg-desktop-portal-kde",
    "kf6-kcoreaddons",
    # apps / firmware / platform
    "firefox",
    "linux-firmware",
    "atheros-firmware",
    "cirrus-audio-firmware",
    "qcom-firmware",
    "NetworkManager",
    "pipewire",
    "wireplumber",
    "bluez",
    "iio-sensor-proxy",
    "libfprint",
    "fprintd",
    "libqmi",
    "libqrtr-glib",
    "qbootctl",
]


def load(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if data.get("format") != "liuqin-rootfs-manifest/v1":
        sys.exit(f"{path}: unsupported manifest format {data.get('format')!r}")
    return data


def by_name(manifest: dict) -> dict[str, dict]:
    return {p["name"]: p for p in manifest.get("packages", [])}


def norm_version(p: dict) -> tuple:
    """Arch/epoch + version + release without the Fedora dist suffix.

    A pure .fc44 -> .fc45 suffix bump means "same code rebuilt for the new
    release"; that should not be reported as a version change.
    """
    return (p.get("epoch", "0"), p["version"], re.sub(r"\.fc\d+$", "", p["release"]))


def fmt_evr(p: dict | None) -> str:
    if not p:
        return "—"
    evr = f"{p['version']}-{p['release']}"
    if p.get("epoch") and p["epoch"] != "0":
        evr = f"{p['epoch']}:{evr}"
    return evr


def size_of(manifest_path: Path) -> dict:
    """Read sibling build-info.json (same output dir) if present."""
    info = manifest_path.parent / "build-info.json"
    try:
        with open(info, encoding="utf-8") as f:
            data = json.load(f)
        out = data.get("outputs", {})
        return {
            "bytes": out.get("rootfs_size_bytes"),
            "files": out.get("rootfs_file_count"),
            "duration": data.get("build", {}).get("duration_seconds"),
            "plasma": data.get("target", {}).get("plasma_workspace"),
            "release": data.get("target", {}).get("release"),
        }
    except (OSError, json.JSONDecodeError):
        return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest_a", type=Path, help="old release manifest (e.g. Fedora 44)")
    ap.add_argument("manifest_b", type=Path, help="new release manifest (e.g. Fedora 45)")
    ap.add_argument("--out", type=Path, help="write markdown report to this file")
    ap.add_argument("-q", "--quiet", action="store_true", help="do not print the report to stdout")
    args = ap.parse_args()

    a, b = load(args.manifest_a), load(args.manifest_b)
    pa, pb = by_name(a), by_name(b)
    info_a, info_b = size_of(args.manifest_a), size_of(args.manifest_b)

    rel_a = a.get("image", {}).get("release", "?")
    rel_b = b.get("image", {}).get("release", "?")
    lines: list[str] = []
    w = lines.append

    w(f"# Fedora {rel_a} → Fedora {rel_b} rootfs diff")
    w("")
    w(f"- A: `{args.manifest_a}`")
    w(f"- B: `{args.manifest_b}`")
    w("")

    # ---- summary ---------------------------------------------------------
    w("## Summary")
    w("")
    w(f"| metric | Fedora {rel_a} | Fedora {rel_b} | delta |")
    w("|---|---|---|---|")
    n_a, n_b = len(pa), len(pb)
    w(f"| packages | {n_a} | {n_b} | {n_b - n_a:+d} |")

    def human(n: int | None) -> str:
        if not n:
            return "—"
        return f"{n / (1024 ** 3):.2f} GiB ({n} B)"

    sa, sb = info_a.get("bytes"), info_b.get("bytes")
    w(f"| rootfs size | {human(sa)} | {human(sb)} | "
      f"{(f'{(sb - sa) / (1024 ** 2):+.0f} MiB' if sa and sb else '—')} |")
    fa, fb = info_a.get("files"), info_b.get("files")
    w(f"| files | {fa or '—'} | {fb or '—'} | "
      f"{(f'{fb - fa:+d}' if fa and fb else '—')} |")
    da, db = info_a.get("duration"), info_b.get("duration")
    w(f"| build duration (s) | {da or '—'} | {db or '—'} | — |")
    w(f"| plasma-workspace | {info_a.get('plasma') or fmt_evr(pa.get('plasma-workspace'))} | "
      f"{info_b.get('plasma') or fmt_evr(pb.get('plasma-workspace'))} | — |")
    w("")

    # ---- key component versions -----------------------------------------
    w("## Key component versions")
    w("")
    w(f"| package | Fedora {rel_a} | Fedora {rel_b} | changed |")
    w("|---|---|---|---|")
    for name in KEY_PACKAGES:
        pa_ = pa.get(name)
        pb_ = pb.get(name)
        if not pa_ and not pb_:
            continue
        va, vb = fmt_evr(pa_), fmt_evr(pb_)
        changed = "**yes**" if (pa_ and pb_ and norm_version(pa_) != norm_version(pb_)) else ""
        if not pa_:
            changed = "**added**"
        elif not pb_:
            changed = "**removed**"
        w(f"| {name} | {va} | {vb} | {changed} |")
    w("")

    # ---- package set changes --------------------------------------------
    added = sorted(set(pb) - set(pa))
    removed = sorted(set(pa) - set(pb))
    w("## Package set changes")
    w("")
    w(f"### Added in Fedora {rel_b} ({len(added)})")
    w("")
    if added:
        for n in added:
            w(f"- `{n}` {fmt_evr(pb[n])}")
    else:
        w("- (none)")
    w("")
    w(f"### Removed in Fedora {rel_b} ({len(removed)})")
    w("")
    if removed:
        for n in removed:
            w(f"- `{n}` {fmt_evr(pa[n])}")
    else:
        w("- (none)")
    w("")

    # ---- version changes (full list is noisy; count + all changed) ------
    changed = [
        (n, pa[n], pb[n])
        for n in sorted(set(pa) & set(pb))
        if norm_version(pa[n]) != norm_version(pb[n])
    ]
    w(f"## Version changes ({len(changed)} packages)")
    w("")
    if changed:
        w("| package | old | new |")
        w("|---|---|---|")
        for n, x, y in changed:
            w(f"| {n} | {fmt_evr(x)} | {fmt_evr(y)} |")
    else:
        w("- (none)")
    w("")
    w("---")
    w("Generated by `tools/compare-rootfs-releases.py` from the machine-readable")
    w("rootfs manifests; see `docs/fedora-45-readiness.md`.")
    w("")

    report = "\n".join(lines)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(report + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    if not args.quiet:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
