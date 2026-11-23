#!/usr/bin/env python3
"""Apply the validated liuqin standby device-tree changes to an assembled DTB.

The final ABL DTB is built from the stock-ROM base DTBs, 44 vendor overlays and
the kernel board DTB.  Three of the five standby fixes touch nodes that only
exist in the vendor part (the ABL overlay sink and the two bandwidth monitors),
so they cannot live in the kernel DTS; they are applied here, after assembly.

The exact operation order reproduces the DTB that ran on the tablet for the
measured standby samples (sha256 e1812d8c...):

  1. fdtput  /liuqin-abl-overlay-sink  #clock-cells = 1
  2. fdtput  /soc@0/crypto@1dfa000     status = disabled
  3. fdtput  /soc@0/pmu@19091000       status = disabled
  4. fdtput  /soc@0/pmu@190b6400       status = disabled
  5. fdtput  /soc@0/clock-controller@ade0000  delete interconnects
  6. dtc round trip: remove regulator-always-on from the four panel rails

Usage:
  tools/liuqin-standby-dt.py DTB [--expect-sha SHA256] [--quiet]

Requires dtc, fdtput and fdtget on PATH.  Never touches the input file.
"""
import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SINK = '/liuqin-abl-overlay-sink'
CAMCC = '/soc@0/clock-controller@ade0000'
CRYPTO = '/soc@0/crypto@1dfa000'
PMUS = ('/soc@0/pmu@19091000', '/soc@0/pmu@190b6400')
RAILS = ('backlight-gpio-reg-vsn', 'backlight-gpio-reg-vsp',
         'display-panel-dvdd-buck', 'display-panel-dvdd-ldo')
VALIDATED_SHA = 'e1812d8c07e70bc0c9123e4a5ae94352fdd8201eb3315823418623dbc7027e0b'


def run(args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def node_block(text, name):
    match = re.search(re.escape(name) + r'\s*\{', text)
    if not match:
        raise SystemExit(f'liuqin-standby-dt: node not found: {name}')
    start = match.start()
    depth = 0
    for i in range(text.index('{', start), len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return start, i + 1
    raise SystemExit(f'liuqin-standby-dt: unbalanced node: {name}')


def apply(dtb):
    run(['fdtput', '-t', 'i', dtb, SINK, '#clock-cells', '1'])
    for node in (CRYPTO,) + PMUS:
        run(['fdtput', '-t', 's', dtb, node, 'status', 'disabled'])
    run(['fdtput', '-d', dtb, CAMCC, 'interconnects'])

    # The RAM-tested blob was produced through a dtc decompile/recompile round
    # trip; fdtput alone yields the same properties but different bytes.
    dts = Path(dtb).with_suffix('.standby.dts')
    run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', '-o', str(dts), dtb])
    text = dts.read_text()
    for name in RAILS:
        start, end = node_block(text, name)
        block = text[start:end]
        if 'regulator-always-on;' not in block:
            raise SystemExit(f'liuqin-standby-dt: {name} has no regulator-always-on')
        text = text[:start] + block.replace('\t\tregulator-always-on;\n', '') + text[end:]
    dts.write_text(text)
    run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', dtb, dts])
    dts.unlink()


def verify(dtb):
    problems = []
    if run(['fdtget', '-t', 'i', dtb, SINK, '#clock-cells']).strip() != b'1':
        problems.append('sink #clock-cells is not 1')
    if b'interconnects' in run(['fdtget', '-p', dtb, CAMCC]).splitlines():
        problems.append('camcc still has interconnects')
    for node in (CRYPTO,) + PMUS:
        if run(['fdtget', '-t', 's', dtb, node, 'status']).strip() != b'disabled':
            problems.append(f'{node} is not disabled')
    for name in RAILS:
        props = run(['fdtget', '-p', dtb, f'/{name}']).splitlines()
        if b'regulator-always-on' in props:
            problems.append(f'{name} still has regulator-always-on')
        if b'regulator-boot-on' not in props:
            problems.append(f'{name} lost regulator-boot-on')
    if problems:
        raise SystemExit('liuqin-standby-dt: ' + '; '.join(problems))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dtb')
    parser.add_argument('--expect-sha', default=None,
                        help='fail unless the result has this sha256')
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args()

    source = Path(args.dtb)
    if not source.is_file():
        raise SystemExit(f'liuqin-standby-dt: no such DTB: {source}')
    with tempfile.TemporaryDirectory(prefix='liuqin-standby-dt.') as tmp:
        work = Path(tmp) / 'final.dtb'
        shutil.copyfile(source, work)
        apply(str(work))
        verify(str(work))
        digest = sha(work)
        if args.expect_sha and digest != args.expect_sha:
            raise SystemExit(
                f'liuqin-standby-dt: result sha256 {digest} != expected {args.expect_sha}')
        shutil.copyfile(work, source)
    if not args.quiet:
        print(f'liuqin-standby-dt: {source} sha256 {digest}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
