#!/usr/bin/env python3
"""Record the installed private liuqin-firmware payload; never copy blob data."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pinned_source(source_root, source, expected):
    path = source_root / source.lstrip("/")
    if not path.exists():
        raise ValueError(f"firmware source is not mapped by the pinned upstream tree: {source}")
    resolved = path.resolve(strict=True)
    resolved_name = "/" + str(resolved.relative_to(source_root.resolve()))
    digest = sha256(resolved)
    if expected.get(resolved_name) != digest:
        raise ValueError(f"source does not match pinned upstream manifest: {source}")
    return path, resolved, resolved_name, digest


def records_for(root, paths, expected, source_root):
    records = []
    # Prefer exact manifest/tree paths: updates/ath11k .bin are separately
    # pinned inputs, NOT decompressed aliases of the main-tree .zst files.
    for name in sorted(paths):
        if not name.startswith("/usr/lib/firmware/"):
            continue
        path = root / name.lstrip("/")
        source = name
        original = source_root / source.lstrip("/")
        if source not in expected and not original.exists() and not original.is_symlink():
            # Packaging also relocates main-tree ath11k to updates/. Never
            # override an exact pin with that fallback mapping.
            source = name.replace("/firmware/updates/ath11k/", "/firmware/ath11k/", 1)
            original = source_root / source.lstrip("/")
        if path.is_dir() and not path.is_symlink():
            if original.is_dir() and not original.is_symlink():
                continue
            raise ValueError(f"firmware file was replaced by a directory: {name}")
        original, resolved, resolved_name, source_digest = pinned_source(source_root, source, expected)
        record = {"path": name, "source_path": source,
                  "source_resolved_path": resolved_name,
                  "source_sha256": source_digest}
        if path.is_symlink():
            if not original.is_symlink() or path.readlink() != original.readlink():
                raise ValueError(f"firmware symlink does not match pinned source: {name}")
            # A matching link string alone is not enough: reject dangling links,
            # escapes and changed targets in the installed tree.
            path.resolve(strict=True).relative_to(root.resolve())
            record["symlink_target"] = str(path.readlink())
        elif original.is_symlink():
            raise ValueError(f"firmware source symlink was replaced by a regular file: {name}")
        digest = sha256(path)
        if digest != source_digest:
            raise ValueError(f"firmware does not match pinned upstream manifest: {name}")
        record["sha256"] = digest
        records.append(record)
    return records


def main(root, upstream):
    output = root / "usr/share/liuqin/firmware-provenance.json"
    packages = subprocess.check_output(["chroot", str(root), "rpm", "-qa", "--qf",
                                        "%{NAME}\\t%{NEVRA}\\n"], text=True)
    installed = dict(line.split("\t", 1) for line in packages.splitlines())
    if "liuqin-firmware" not in installed:
        # A generic mkosi base has no private device package. Never leave an old
        # generated assertion attached to a tree from which it has been removed.
        if output.exists():
            output.unlink()
        print("firmware provenance: no liuqin-firmware RPM installed")
        return
    paths = subprocess.check_output(["chroot", str(root), "rpm", "-ql", "liuqin-firmware"], text=True).splitlines()
    manifest = upstream / "device/firmware/firmware.manifest"
    expected = dict((name, digest) for digest, name in
                    (line.split(None, 1) for line in manifest.read_text().splitlines() if line.strip()))
    records = records_for(root, paths, expected, upstream / "device/firmware")
    if not records:
        raise ValueError("installed liuqin-firmware has no firmware payload")
    commit = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
    data = {
        "schema_version": 1,
        "scope": "liuqin-firmware RPM only; Fedora firmware retains its package licensing",
        "package": installed["liuqin-firmware"],
        "source": {"repository": "https://github.com/yzddmr6/xiaomipad-6pro-mainline",
                   "commit": commit, "manifest": "device/firmware/firmware.manifest",
                   "manifest_sha256": sha256(manifest)},
        "license": "Proprietary; no redistribution permission granted",
        "redistributable": False,
        "distribution": "private-local-only; do not publish this rootfs/bundle",
        "device_specific_data": "No persist calibration, serials or fingerprint templates are collected by this tool",
        "files": records,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    output.chmod(0o644)
    print(f"firmware provenance: {len(records)} entries, private-local-only")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
