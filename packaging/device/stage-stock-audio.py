#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Stage only the five pinned stock speaker files into a PRIVATE image tree."""
import hashlib
import json
from pathlib import Path
import shutil
import sys


def stage(root, source):
    manifest = json.loads((Path(__file__).resolve().parents[1] /
                           'release/stock-audio.json').read_text())
    for name, expected in manifest['files'].items():
        path = source / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('stock speaker tuning checksum mismatch: ' + name)
    target = root / 'usr/lib/firmware/cirrus'
    target.mkdir(parents=True, exist_ok=True)
    for channel in ('TL', 'TR', 'BL', 'BR'):
        for suffix, name in (
            ('bin', channel + '-cs35l41-dsp1-spk-prot.bin'),
            ('wmfw', 'cs35l41-dsp1-spk-prot.wmfw'),
        ):
            path = target / ('cs35l41-dsp1-spk-prot-10251826-' + channel.lower() + '.' + suffix)
            if path.is_symlink():
                raise ValueError('unexpected symlink at stock audio destination: ' + str(path))
            shutil.copyfile(source / name, path)
            path.chmod(0o644)
    print('Staged four-channel stock speaker tuning: PRIVATE image only')


if __name__ == '__main__':
    stage(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
