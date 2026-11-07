#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Prepare a private FPC cache from the owner's matching stock modem image.

Alternative to upstream's on-device read-only modem_a extraction when that
partition contains a different firmware version. Never changes a partition,
accepts different TA hashes, or includes credentials/calibration. Do not publish
the output archive. Requires mtools and the already obtained stock ROM input.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
MANIFEST = PROJECT / 'upstream/xiaomipad-6pro-mainline/device/fingerprint/oem/firmware/SHA256.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modem-image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('refuse to replace existing output')
    hashes = json.loads(MANIFEST.read_text())
    names = {'fpcliu.mdt', *(f'fpcliu.b{i:02d}' for i in range(9))}
    if set(hashes) != names:
        raise ValueError('unexpected upstream firmware manifest')
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, digest in hashes.items():
            target = root / name
            subprocess.run(['mcopy', '-i', str(args.modem_image),
                            '::/image/' + name, str(target)], check=True)
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError('stock FPC firmware hash mismatch: ' + name)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(args.output, 'x:gz') as archive:
            for name in sorted(names):
                info = archive.gettarinfo(str(root / name), arcname=name)
                info.mode, info.uid, info.gid, info.uname, info.gname, info.mtime = 0o600, 0, 0, '', '', 0
                with (root / name).open('rb') as stream:
                    archive.addfile(info, stream)
    args.output.chmod(0o600)
    print('fpc_firmware=VERIFIED files=10 source_image_sha256=' +
          hashlib.sha256(args.modem_image.read_bytes()).hexdigest())
    print('private_archive_sha256=' + hashlib.sha256(args.output.read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
