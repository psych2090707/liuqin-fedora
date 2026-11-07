#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a Fedora KDE or GNOME stage-1 admission contract for liuqin (v2).

This is the single contract producer (single-producer rule).  Consumers:

  * initramfs/init ``storage_fedora_root_ok()`` -- fail-closed boot admission;
  * installer/lib/install-root.sh -- RAM-installer pre/post-install topology
    check (the contract is embedded in installer.img, flat install contract);
  * scripts/build-image.sh -- embeds the one generated contract in boot.img and
    installer.img, so both boot paths agree on the same policy;
  * scripts/verify-bundle.sh -- audits the delivered contract.

Contract v2 changed the semantics from content hashes to *identity + topology*:

  * removed (topology contract-C): sha256 pins of /etc/hostname, /etc/locale.conf,
    /etc/vconsole.conf, /etc/fstab, /etc/selinux/config, /etc/environment.d/*,
    /etc/chrony*, /etc/plasmalogin.conf.d/*, /etc/skel/* and of project device
    payloads.  Those files are owned by RPM or edited by the user; pinning them
    turned a normal ``dnf upgrade`` or hostname change into a rescue boot;
  * kept fail-closed (topology contract-A/B): root role marker, PID1/login manager/
    Plasma session topology (existence, type, executable bit, ownership), and
    the device/storage identity gates that stay in initramfs/init and are not
    part of this file;
  * kernel identity is NOT a content pin: /usr/share/liuqin/kernel.release and
    kernel-modules.manifest are only required to exist as root-owned regular
    files here; the running-kernel comparison in initramfs/init is a warning,
    and the strict check belongs to the update/apply tools (metadata contract).

Contract file format (ASCII, LF, sorted/stable order, no trailing spaces)::

    LIUQIN_FEDORA_ROOT_CONTRACT_V2
    # comments start with '#'
    marker <abs-path> <mode-octal> <sha256-of-content>
    file <abs-path>
    exec <abs-path>
    resolve <abs-path> <expected-basename>
    display-manager <unit-name>

Semantics, all paths resolved inside the target root without chroot:

  marker           regular file, not a symlink, uid=gid=0, mode 0644, and its
                   content hashes to the declared sha256;
  file             regular file, not a symlink, owned by uid=gid=0;
  exec             like file, plus at least one executable bit;
  resolve          symlink chain (followed with absolute targets interpreted
                   inside the target root, at most 16 hops) that ends in an
                   existing root-owned regular file whose basename is the
                   expected one;
  display-manager  the distribution login manager is enabled either through the
                   systemd alias /etc/systemd/system/display-manager.service or
                   through a multi-user.target/graphical.target .wants symlink;
                   the resulting unit must exist.  Both Fedora forms are
                   accepted (topology contract).

At build time the generator must be given the assembled rootfs (``--rootfs``)
and/or its hash manifest (``--manifest``) so a contract that cannot pass on the
real tree is refused *before* an image is written; ``--rootfs`` additionally
executes the same topology predicate initramfs/init will run at boot.

Exit codes: 0 success; 1 contract could not be generated/validated; 2 usage.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
from pathlib import Path
from typing import Iterable

PROFILES = ("fedora",)

# Header consumed by initramfs/init: storage_fedora_root_ok() requires this
# exact first line.
CONTRACT_HEADERS = {"fedora": "LIUQIN_FEDORA_ROOT_CONTRACT_V2"}

# The role marker is written by the image assembler (not by rpm), mode 0644,
# owner 0:0, content "liuqin-fedora-root-v1\n" (22 bytes).  initramfs/init reads
# the expected digest from the contract itself; this constant is the producer
# side of that agreement.
MARKER_PATH = "/etc/liuqin-fedora-root"
MARKER_SHA256 = "3c32b153d6dc59ec4752badc5403f1c2df0ef6d88c722508cd08677903cfdda1"
MARKER_MODE = "0644"

# Stage-1 parser bounds, restated so a bad contract dies here instead of on the
# tablet.  v2 is a short topology list, not a pin list: 8..128 lines,
# 256..16384 bytes (comments count toward the line bound).
MIN_LINES, MAX_LINES = 8, 128
MIN_BYTES, MAX_BYTES = 256, 16384

# The contract itself: (kind, *fields).  Every entry is project-reviewed; the
# list is the Fedora 44 KDE stable topology (verified against a real mkosi
# rootfs: /home/user=1000:1000 0700, plasmashell=0755, mount=04755).
CONTRACT_ENTRIES: tuple[tuple[str, ...], ...] = (
    ("marker", MARKER_PATH, MARKER_MODE, MARKER_SHA256),
    # Login manager unit and the binaries the boot hands control to (D2-B).
    ("file", "/usr/lib/systemd/system/plasmalogin.service"),
    ("exec", "/usr/lib/systemd/systemd"),
    ("exec", "/usr/bin/plasmalogin"),
    # Plasma session: at least one exec bit is required, not an exact 0755
    # (topology contract; 0555 from a frozen tree must not be required either).
    ("exec", "/usr/bin/plasmashell"),
    ("exec", "/usr/bin/kwin_wayland"),
    ("exec", "/usr/bin/startplasma-wayland"),
    ("exec", "/usr/libexec/kscreenlocker_greet"),
    # Kernel identity interface: existence/type/owner only; content changes on
    # `dnf update` and must never be a boot admission condition (D2-C).
    ("file", "/usr/share/liuqin/kernel.release"),
    ("file", "/usr/share/liuqin/kernel-modules.manifest"),
    # PID1 handoff and default target, resolved inside the target root.
    ("resolve", "/usr/sbin/init", "systemd"),
    # The vendor default survives systemd's first-boot preset-all.  The
    # administrator's /etc alias can be removed by presets and is mutable
    # configuration, so it must not be a condition for admitting this root.
    ("resolve", "/usr/lib/systemd/system/default.target", "graphical.target"),
    # Login manager enablement: alias or .wants form, resolved to a real unit.
    ("display-manager", "plasmalogin.service"),
)

# A Fedora GNOME route uses the SAME identity/topology grammar, not upstream's
# Ubuntu "gnome" storage profile. Transition boot carries both complete lists.
GNOME_ENTRIES = (
    CONTRACT_ENTRIES[0],
    ("file", "/usr/lib/systemd/system/gdm.service"),
    ("exec", "/usr/lib/systemd/systemd"),
    ("exec", "/usr/bin/gdm"),
    ("exec", "/usr/libexec/gdm-session-worker"),
    ("exec", "/usr/bin/gnome-shell"),
    ("exec", "/usr/bin/gnome-session"),
    ("exec", "/usr/libexec/gnome-session-init-worker"),
    ("exec", "/usr/libexec/gnome-session-service"),
    ("file", "/usr/share/wayland-sessions/gnome.desktop"),
    *CONTRACT_ENTRIES[8:12],
    ("display-manager", "gdm.service"),
)


def desktop_entries(desktop: str) -> tuple[tuple[str, ...], ...]:
    return GNOME_ENTRIES if desktop == "gnome" else CONTRACT_ENTRIES

COMMENT_LINES = (
    "# Fedora/KDE stage-1 admission contract v2 (topology contract): device/partition",
    "# identity lives in initramfs/init; this file is the Fedora KDE topology.",
)

KINDS = frozenset({"marker", "file", "exec", "resolve", "display-manager"})


def die(message: str) -> "None":
    print(f"build-root-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_inside_root(path: str) -> str:
    """Normalize an absolute in-root path lexically (POSIX '..' semantics)."""
    if not path.startswith("/"):
        raise ValueError(f"not an absolute in-root path: {path!r}")
    out: list[str] = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not out:
                raise ValueError(f"path escapes the root: {path!r}")
            out.pop()
            continue
        out.append(part)
    return "/" + "/".join(out)


def resolve_inside_root(root: Path, path: str, hops: int = 16) -> str:
    """Follow a symlink chain inside ``root`` and return the final in-root path."""
    current = normalize_inside_root(path)
    for _ in range(hops):
        host_path = root / current.lstrip("/")
        try:
            info = host_path.lstat()
        except OSError as error:
            raise ValueError(f"cannot stat {current} in the root: {error}") from error
        if not stat.S_ISLNK(info.st_mode):
            return current
        target = os.readlink(host_path)
        if target.startswith("/"):
            current = normalize_inside_root(target)
        else:
            parent = current.rsplit("/", 1)[0] or "/"
            current = normalize_inside_root(parent.rstrip("/") + "/" + target)
    raise ValueError(f"symlink chain is too long: {path}")


def entry_error(root: Path, entry: tuple[str, ...]) -> str | None:
    """Return a human-readable error if ``entry`` fails on ``root``, else None."""
    kind = entry[0]
    if kind == "marker":
        _, path, mode, expected = entry
        host = root / path.lstrip("/")
        try:
            info = host.lstat()
        except OSError:
            return f"marker is missing: {path}"
        if stat.S_ISLNK(info.st_mode):
            return f"marker is a symlink: {path}"
        if not stat.S_ISREG(info.st_mode):
            return f"marker is not a regular file: {path}"
        if (info.st_uid, info.st_gid) != (0, 0):
            return f"marker owner is {info.st_uid}:{info.st_gid}, expected 0:0"
        if stat.S_IMODE(info.st_mode) != int(mode, 8):
            return f"marker mode is {stat.S_IMODE(info.st_mode):04o}, expected {mode}"
        digest = sha256_file(host)
        if digest != expected:
            return f"marker content hash is {digest}, expected {expected}"
        return None
    if kind in ("file", "exec"):
        path = entry[1]
        host = root / path.lstrip("/")
        try:
            info = host.lstat()
        except OSError:
            return f"missing: {path}"
        if stat.S_ISLNK(info.st_mode):
            return f"is a symlink, expected a regular file: {path}"
        if not stat.S_ISREG(info.st_mode):
            return f"is not a regular file: {path}"
        if (info.st_uid, info.st_gid) != (0, 0):
            return f"owner is {info.st_uid}:{info.st_gid}, expected 0:0: {path}"
        if kind == "exec" and not (stat.S_IMODE(info.st_mode) & 0o111):
            return f"has no executable bit: {path}"
        return None
    if kind == "resolve":
        path, expected_basename = entry[1], entry[2]
        try:
            resolved = resolve_inside_root(root, path)
        except ValueError as error:
            return str(error)
        if resolved.rsplit("/", 1)[-1] != expected_basename:
            return f"{path} resolves to {resolved}, expected basename {expected_basename}"
        host = root / resolved.lstrip("/")
        try:
            info = host.lstat()
        except OSError:
            return f"{path} resolves to a missing target: {resolved}"
        if not stat.S_ISREG(info.st_mode):
            return f"{path} resolves to a non-regular file: {resolved}"
        if (info.st_uid, info.st_gid) != (0, 0):
            return f"{path} resolves to a file not owned by root: {resolved}"
        return None
    if kind == "display-manager":
        unit = entry[1]
        candidates = [
            "/etc/systemd/system/display-manager.service",
            f"/etc/systemd/system/multi-user.target.wants/{unit}",
            f"/etc/systemd/system/graphical.target.wants/{unit}",
        ]
        problems = []
        for candidate in candidates:
            host = root / candidate.lstrip("/")
            try:
                info = host.lstat()
            except OSError:
                problems.append(f"{candidate}: missing")
                continue
            if not stat.S_ISLNK(info.st_mode):
                problems.append(f"{candidate}: not a symlink")
                continue
            try:
                resolved = resolve_inside_root(root, candidate)
            except ValueError as error:
                problems.append(f"{candidate}: {error}")
                continue
            if resolved.rsplit("/", 1)[-1] != unit:
                problems.append(f"{candidate}: resolves to {resolved}")
                continue
            target = root / resolved.lstrip("/")
            try:
                target_info = target.lstat()
            except OSError:
                problems.append(f"{candidate}: target missing ({resolved})")
                continue
            if not stat.S_ISREG(target_info.st_mode):
                problems.append(f"{candidate}: target is not a unit file ({resolved})")
                continue
            if (target_info.st_uid, target_info.st_gid) != (0, 0):
                problems.append(f"{candidate}: target is not root-owned ({resolved})")
                continue
            return None
        return "login manager does not resolve to an existing unit: " + "; ".join(problems)
    return f"unknown contract entry kind: {kind!r}"


def validate_contract_text(lines: Iterable[str]) -> list[str]:
    """Structural validation of a contract file's lines (no root needed)."""
    errors: list[str] = []
    materialized = list(lines)
    if not materialized:
        return ["contract is empty"]
    if not MIN_LINES <= len(materialized) <= MAX_LINES:
        errors.append(f"contract has {len(materialized)} lines, expected {MIN_LINES}..{MAX_LINES}")
    if materialized[0] != CONTRACT_HEADERS["fedora"]:
        errors.append(f"first line is not {CONTRACT_HEADERS['fedora']}: {materialized[0]!r}")
    seen: set[str] = set()
    markers = 0
    for number, raw in enumerate(materialized, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if number == 1:
            continue
        fields = line.split(" ")
        if "" in fields:
            errors.append(f"line {number} has repeated spaces: {raw!r}")
            continue
        kind = fields[0]
        if kind not in KINDS:
            errors.append(f"line {number} has unknown kind {kind!r}")
            continue
        expected_fields = {"marker": 4, "file": 2, "exec": 2, "resolve": 3,
                           "display-manager": 2}[kind]
        if len(fields) != expected_fields:
            errors.append(f"line {number} needs {expected_fields - 1} field(s): {raw!r}")
            continue
        # Only the path-bearing kinds are path fields; display-manager carries a
        # systemd unit name and must not be run through path normalization.
        if kind in ("marker", "file", "exec", "resolve"):
            try:
                normalized = normalize_inside_root(fields[1])
            except ValueError as error:
                errors.append(f"line {number}: {error}")
                continue
            if normalized != fields[1]:
                errors.append(f"line {number} path is not normalized: {fields[1]!r}")
        key = " ".join(fields[1:2])
        if key in seen:
            errors.append(f"line {number} repeats path {fields[1]!r}")
        seen.add(key)
        if kind == "marker":
            markers += 1
            if fields[2] != MARKER_MODE:
                errors.append(f"line {number} marker mode is not {MARKER_MODE}")
            digest = fields[3]
            if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                errors.append(f"line {number} marker sha256 is malformed")
        if kind == "resolve":
            basename = fields[2]
            if "/" in basename or not basename:
                errors.append(f"line {number} resolve target is not a plain basename")
        if kind == "display-manager" and not fields[1].endswith(".service"):
            errors.append(f"line {number} display-manager unit is not a .service name")
    if markers != 1:
        errors.append(f"contract must carry exactly one marker entry, found {markers}")
    return errors


def read_manifest(path: Path) -> dict[str, str]:
    """Parse a sha256sum-style manifest into {absolute path: sha256}."""
    if not path.is_file():
        die(f"manifest is unavailable: {path}")
    hashes: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        digest, sep, rel = line.partition("  ")
        if not sep or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            die(f"manifest line {number} is not '<sha256>  <path>': {raw!r}")
        if not rel.startswith("/"):
            die(f"manifest line {number} path is not absolute: {rel!r}")
        if rel in hashes:
            die(f"manifest repeats path: {rel}")
        hashes[rel] = digest
    if not hashes:
        die(f"manifest carries no entries: {path}")
    return hashes


def check_manifest(entries: tuple[tuple[str, ...], ...], manifest: Path) -> None:
    """Cross-check the declared regular files against the assembled manifest."""
    hashes = read_manifest(manifest)
    marker_entries = [entry for entry in entries if entry[0] == "marker"]
    marker = marker_entries[0]
    if hashes.get(marker[1]) != marker[3]:
        die(
            f"{marker[1]} in {manifest} has sha256 {hashes.get(marker[1])}, "
            f"expected {marker[3]} (content 'liuqin-fedora-root-v1\\n', 22 bytes)"
        )
    missing = [entry[1] for entry in entries
               if entry[0] in ("file", "exec") and entry[1] not in hashes]
    if missing:
        print("build-root-contract: these declared paths are absent from the manifest:",
              file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        die(f"refusing to generate a contract for a tree that does not carry {len(missing)} "
            "declared paths (fail-closed at build time; fix the image, not the contract)")


def check_rootfs(entries: tuple[tuple[str, ...], ...], root: Path) -> None:
    """Execute the boot admission topology predicate against the real tree."""
    if not root.is_dir():
        die(f"--rootfs is not a directory: {root}")
    errors = []
    for entry in entries:
        error = entry_error(root, entry)
        if error is not None:
            errors.append(f"{entry[0]} {' '.join(entry[1:])}: {error}")
    if errors:
        for error in errors:
            print(f"build-root-contract: topology: {error}", file=sys.stderr)
        die(f"the assembled rootfs fails its own admission contract ({len(errors)} "
            "topology error(s)); boot would enter rescue")


def build_contract_text(header: str, desktop: str = "kde") -> str:
    comments = COMMENT_LINES if desktop == "kde" else (
        "# Fedora/GNOME stage-1 admission contract v2: device/partition",
        "# identity lives in initramfs/init; this file is the Fedora GNOME topology.",
    )
    lines = [header, *comments]
    lines.extend(" ".join(entry) for entry in desktop_entries(desktop))
    data = "\n".join(lines) + "\n"
    return data


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a Fedora KDE or GNOME stage-1 admission contract (v2).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--profile", choices=PROFILES, default="fedora")
    parser.add_argument("--desktop", choices=("kde", "gnome"), default="kde",
                        help="reviewed Fedora topology; default preserves KDE v2 bytes")
    parser.add_argument("--output", required=True, type=Path, help="contract file to write")
    parser.add_argument(
        "--manifest",
        type=Path,
        help="assembled root filesystem hash manifest (<sha256>  <absolute path> per "
             "line); cross-checks the declared files and the marker content hash",
    )
    parser.add_argument(
        "--rootfs",
        type=Path,
        help="assembled root filesystem tree; runs the same topology predicate "
             "initramfs/init uses at boot, fail-closed at build time",
    )
    parser.add_argument(
        "--print-entries",
        action="store_true",
        help="print the effective contract and exit without writing",
    )
    parser.add_argument(
        "--allow-missing-pins",
        action="store_true",
        help="deprecated v1 flag (contract v2 has no content pins); accepted as a no-op",
    )
    parser.add_argument(
        "--extra-pins-file",
        type=Path,
        help="deprecated v1 flag; contract v2 does not support extra content pins",
    )
    args = parser.parse_args()

    if args.extra_pins_file is not None:
        die("--extra-pins-file is a v1 concept: contract v2 has no content pins "
            "(topology contract); remove the flag instead of weakening boot admission")
    if args.allow_missing_pins:
        print("build-root-contract: note: --allow-missing-pins is a deprecated v1 no-op "
              "(contract v2 has no content pins)", file=sys.stderr)

    header = CONTRACT_HEADERS[args.profile]
    entries = desktop_entries(args.desktop)
    text = build_contract_text(header, args.desktop)
    lines = text.splitlines()
    errors = validate_contract_text(lines)
    if errors:
        for error in errors:
            print(f"build-root-contract: {error}", file=sys.stderr)
        die("generated contract is malformed (this is a bug in this generator)")

    if args.print_entries:
        print(text, end="")
        return
    if args.manifest is not None:
        check_manifest(entries, args.manifest)
    if args.rootfs is not None:
        check_rootfs(entries, args.rootfs)
    if args.rootfs is None and args.manifest is None:
        print("build-root-contract: WARNING: no --rootfs/--manifest given; the contract "
              "was not validated against a real tree", file=sys.stderr)

    data = text.encode("ascii")
    if not MIN_BYTES <= len(data) <= MAX_BYTES:
        die(f"contract is outside the stage-1 parser bounds: {len(data)} bytes "
            f"({MIN_BYTES}..{MAX_BYTES})")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    args.output.chmod(0o644)
    digest = sha256_bytes(data)
    print(
        f"{args.profile}/{args.desktop} contract v2: {len(entries)} topology entries, "
        f"{len(data)} bytes, sha256={digest}, output={args.output}"
    )


if __name__ == "__main__":
    main()
