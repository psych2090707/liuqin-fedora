#!/bin/sh
# SPDX-License-Identifier: MIT
# Turn an assembled liuqin bundle (images/<name>/) into a flat set of release
# assets, splitting large payloads for the GitHub Release per-asset limit.
#
#   scripts/make-release-assets.sh --bundle images/liuqin-fedora-44-dev \
#       --out out/bundle-acceptance/release-assets/liuqin-fedora-44-dev \
#       --dev-release --private-local
#
#   --dry-run     print the plan and the policy verdict, write nothing
#   --verify DIR  verify an existing asset directory against its SHA256SUMS
#
# Policy (fail-closed):
#   * a bundle whose redistribution field marks private/restricted firmware is
#     refused without --private-local, and the assets are labelled PRIVATE;
#   * a bundle with device_ready != true is refused without --dev-release, and
#     the assets are labelled DEVONLY plus a NOT-FOR-HARDWARE statement;
#   * GitHub caps one release asset at 2 GiB, so payloads larger than
#     --part-size (default 1900M) are split into NAME.part-NN files; the
#     generated README explains the join command.
#
# The bundle is only read. Everything is written below --out. No device is
# touched and no network access is performed.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=
out=
part_size=1900M
dry_run=0
private_local=0
dev_release=0
force=0
include_root_img=1
verify_dir=

usage() {
	printf '%s\n' \
		'usage: scripts/make-release-assets.sh --bundle DIR --out DIR [options]' \
		'       scripts/make-release-assets.sh --verify DIR' \
		'' \
		'  --bundle DIR       assembled bundle directory (bundle.json + payloads)' \
		'  --out DIR          new directory for the flat release assets' \
		'  --part-size SIZE   split payloads larger than SIZE (default 1900M; <2 GiB)' \
		'  --private-local    acknowledge private firmware and label the assets PRIVATE' \
		'  --dev-release      acknowledge device_ready=false and label the assets DEVONLY' \
		'  --no-root-img      do not ship root.img (boot.img/installer.img path only)' \
		'  --dry-run          print the plan; write nothing' \
		'  --force            replace an existing --out directory' \
		'  --verify DIR       verify an existing release-assets directory and exit'
}
die() { printf 'make-release-assets: %s\n' "$*" >&2; exit 2; }
say() { printf 'make-release-assets: %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
	case $1 in
	--bundle) [ "$#" -ge 2 ] || die '--bundle needs a value'; bundle=$2; shift 2 ;;
	--out) [ "$#" -ge 2 ] || die '--out needs a value'; out=$2; shift 2 ;;
	--part-size) [ "$#" -ge 2 ] || die '--part-size needs a value'; part_size=$2; shift 2 ;;
	--private-local) private_local=1; shift ;;
	--dev-release) dev_release=1; shift ;;
	--no-root-img) include_root_img=0; shift ;;
	--dry-run) dry_run=1; shift ;;
	--force) force=1; shift ;;
	--verify) [ "$#" -ge 2 ] || die '--verify needs a value'; verify_dir=$2; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

command -v python3 >/dev/null 2>&1 || die 'python3 is required'

# ---------------------------------------------------------------------------
# --verify: re-hash an existing asset directory against SHA256SUMS.
# ---------------------------------------------------------------------------
if [ -n "$verify_dir" ]; then
	[ -d "$verify_dir" ] || die "not a directory: $verify_dir"
	[ -f "$verify_dir/SHA256SUMS" ] || die "no SHA256SUMS in $verify_dir"
	python3 - "$verify_dir" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
failures = []
listed = set()
for line in (directory / 'SHA256SUMS').read_text().splitlines():
    if not line.strip():
        continue
    digest, _, name = line.partition('  ')
    name = name.strip()
    listed.add(name)
    path = directory / name
    if not path.is_file():
        failures.append('missing: ' + name)
        continue
    with path.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
            failures.append('sha256 mismatch: ' + name)
manifest_path = directory / 'release-manifest.json'
if not manifest_path.is_file():
    failures.append('release-manifest.json is missing')
else:
    manifest = json.loads(manifest_path.read_text())
    for entry in manifest.get('assets', []):
        if entry['name'] not in listed:
            failures.append('asset not in SHA256SUMS: ' + entry['name'])
    for name in ('boot.img', 'installer.img', 'bundle.json', 'LICENSE', 'NOTICE',
                 'README.md', 'INSTALL.md', 'install.py', 'liuqin-install.py',
                 'install-liuqin.ps1', 'liuqin_layout.py',
                 'liuqin-rom-images.json'):
        if not (directory / name).is_file():
            failures.append('missing release asset: ' + name)
    for logical in ('rootfs.tar.gz', 'root.img'):
        if (directory / logical).is_file() and list(directory.glob(logical + '.part-*')):
            failures.append('both a payload and its split parts are present: ' + logical)
if failures:
    sys.exit('release assets verification failed:\n  ' + '\n  '.join(failures))
print(f'PASS: release assets verified ({len(listed)} files)')
PY
	exit 0
fi

# ---------------------------------------------------------------------------
# Input validation and policy.
# ---------------------------------------------------------------------------
[ -n "$bundle" ] || die '--bundle is required (or --verify DIR)'
[ -d "$bundle" ] || die "bundle directory is missing: $bundle"
bundle=$(CDPATH= cd -- "$bundle" && pwd)
bundle_json=$bundle/bundle.json
[ -f "$bundle_json" ] || die "bundle has no bundle.json: $bundle"
for name in boot.img installer.img rootfs.tar.gz; do
	[ -f "$bundle/$name" ] || die "bundle payload is missing: $name"
done

field() { # NAME
	python3 - "$bundle_json" "$1" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1]))
name = sys.argv[2]
if name == 'release':
    print((manifest.get('fedora') or {}).get('release', ''))
else:
    value = manifest.get(name, '')
    print('True' if value is True else 'False' if value is False else value)
PY
}
bundle_name=$(field name)
[ -n "$bundle_name" ] || bundle_name=$(basename "$bundle")
fedora_release=$(field release)
kernel_release=$(field kernel_release)
device_ready=$(field device_ready)
offline_only=$(field offline_only)
status=$(field status)
redistribution=$(field redistribution)

labels=
if [ "$device_ready" != "True" ]; then
	[ "$dev_release" = 1 ] ||
		die "bundle device_ready=$device_ready: pass --dev-release to package a workflow-rehearsal bundle (it is not a hardware install candidate)"
	labels="${labels}DEVONLY-"
fi
case $redistribution in
*private*|*restricted*|*local-only*)
	[ "$private_local" = 1 ] ||
		die "bundle redistribution='$redistribution' contains private firmware: pass --private-local and keep the assets private (never upload them publicly)"
	labels="${labels}PRIVATE-LOCAL-"
	;;
esac
[ -n "$labels" ] || labels="PUBLIC-"
labels=${labels%-}
say "bundle: $bundle_name (kernel $kernel_release, device_ready=$device_ready, offline_only=$offline_only)"
say "redistribution: ${redistribution:-unset}; policy label: $labels"

payload_files="boot.img installer.img rootfs.tar.gz"
if [ "$include_root_img" = 1 ] && [ -f "$bundle/root.img" ]; then
	payload_files="$payload_files root.img"
elif [ "$include_root_img" = 1 ]; then
	say 'root.img is absent from the bundle; shipping the installer payload set only'
fi

# ---------------------------------------------------------------------------
# Plan: tab-separated "logical-name action bytes parts" on stdout.
# ---------------------------------------------------------------------------
part_bytes=$(python3 - "$part_size" <<'PY'
import re
import sys
text = sys.argv[1].strip().upper()
match = re.fullmatch(r'(\d+(?:\.\d+)?)\s*([KMGT]?)I?B?', text)
if not match:
    sys.exit('a part size must look like 1900M')
number = float(match.group(1))
scale = {'': 1, 'K': 1024, 'M': 1024 ** 2, 'G': 1024 ** 3, 'T': 1024 ** 4}[match.group(2)]
size = int(number * scale)
if size <= 0 or size > 2 * 1024 ** 3:
    sys.exit('a part size must be > 0 and <= 2 GiB')
print(size)
PY
) || die "invalid --part-size: $part_size"

plan=$(python3 - "$bundle" "$part_bytes" $payload_files <<'PY'
import sys
from pathlib import Path
bundle = Path(sys.argv[1])
part = int(sys.argv[2])
for name in sys.argv[3:]:
    size = (bundle / name).stat().st_size
    if size > part:
        print(f'{name}\tsplit\t{size}\t{(size + part - 1) // part}')
    else:
        print(f'{name}\tcopy\t{size}\t1')
PY
)

printf '%s\n' 'release asset plan:'
printf '%s\n' "$plan" | while IFS="$(printf '\t')" read -r pname paction psize pparts; do
	[ -n "$pname" ] || continue
	if [ "$paction" = split ]; then
		printf '  %-16s %12s bytes -> %s parts of up to %s bytes\n' \
			"$pname" "$psize" "$pparts" "$part_bytes"
	else
		printf '  %-16s %12s bytes -> 1 asset\n' "$pname" "$psize"
	fi
done
printf '  %-16s %12s %s\n' 'metadata' '-' 'bundle.json LICENSE NOTICE README INSTALL install.py release-manifest.json'
printf 'asset policy label: %s\n' "$labels"

if [ "$dry_run" = 1 ]; then
	say 'dry run: no files written'
	exit 0
fi

[ -n "$out" ] || die '--out is required (unless --dry-run)'
out=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$out")
if [ -e "$out" ]; then
	[ "$force" = 1 ] || die "output directory already exists: $out (use --force)"
	rm -rf "$out"
fi
mkdir -p "$out"
say "writing release assets to $out"

# ---------------------------------------------------------------------------
# Payloads: copy small ones, split large ones (GitHub 2 GiB per-asset limit).
# ---------------------------------------------------------------------------
printf '%s\n' "$plan" | while IFS="$(printf '\t')" read -r pname paction psize pparts; do
	[ -n "$pname" ] || continue
	if [ "$paction" = copy ]; then
		cp -f "$bundle/$pname" "$out/$pname"
		say "  $pname ($psize bytes)"
	else
		split -b "$part_bytes" -d -a 2 "$bundle/$pname" "$out/$pname.part-"
		parts=$(ls "$out/$pname".part-* | wc -l)
		[ "$parts" = "$pparts" ] || die "split produced $parts parts for $pname, expected $pparts"
		say "  $pname ($psize bytes -> $parts parts)"
	fi
done

# ---------------------------------------------------------------------------
# Metadata, licence, host installer. README/INSTALL/manifest/SHA256SUMS are
# generated by one Python step so their content stays consistent.
# ---------------------------------------------------------------------------
cp -f "$bundle/bundle.json" "$out/bundle.json"
for name in LICENSE NOTICE; do
	if [ -f "$bundle/$name" ]; then
		cp -f "$bundle/$name" "$out/$name"
	elif [ -f "$project_root/$name" ]; then
		cp -f "$project_root/$name" "$out/$name"
	else
		die "neither the bundle nor the project root has $name"
	fi
done
for host_file in installer/install.py installer/liuqin-install.py \
	installer/windows/install-liuqin.ps1 \
	installer/lib/liuqin_layout.py installer/lib/liuqin-rom-images.json; do
	cp -f "$project_root/$host_file" "$out/$(basename "$host_file")"
done

python3 - "$out" "$bundle_json" "$labels" "$part_bytes" \
	"$kernel_release" "$fedora_release" "$device_ready" "$offline_only" \
	"$redistribution" "$status" "$bundle_name" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

(directory, bundle_json, labels, part_bytes, kernel_release, fedora_release,
 device_ready, offline_only, redistribution, status, bundle_name) = sys.argv[1:12]
directory = Path(directory)
device_ready = device_ready == 'True'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


payloads = {}
for name in ('boot.img', 'installer.img', 'rootfs.tar.gz', 'root.img'):
    direct = directory / name
    parts = sorted(directory.glob(name + '.part-*'))
    if direct.is_file():
        payloads[name] = {'kind': 'whole', 'name': name,
                          'bytes': direct.stat().st_size, 'sha256': sha(direct)}
    elif parts:
        payloads[name] = {'kind': 'split',
                          'bytes': sum(part.stat().st_size for part in parts),
                          'parts': [{'name': part.name, 'bytes': part.stat().st_size,
                                     'sha256': sha(part)} for part in parts]}

not_for_hardware = (not device_ready)
private = any(marker in redistribution for marker in ('private', 'restricted', 'local-only'))
readme = [
    f'# liuqin Fedora {fedora_release} bundle: {bundle_name}',
    '',
    f'Asset policy label: **{labels}**',
    '',
    f'- kernel release: `{kernel_release}`',
    f'- bundle status: `{status or "unknown"}`',
    f'- device_ready: `{device_ready}`',
    f'- offline_only: `{offline_only}`',
    f'- redistribution: `{redistribution or "unset"}`',
    '',
]
if not_for_hardware:
    readme += [
        '> **NOT A HARDWARE INSTALL CANDIDATE.** `device_ready=false` means this',
        '> bundle was assembled offline: no tablet was used, the boot DTB is an',
        '> offline substitute and the full firmware pool was not supplied. It exists',
        '> to rehearse the install pipeline; installing it on a tablet is unsupported.',
        '',
    ]
if private:
    readme += [
        '> **PRIVATE LOCAL ASSETS.** This bundle contains firmware that is not',
        '> redistributable. Do not upload these assets to a public release; use them',
        '> only on the machine that built them, or strip the firmware and rebuild.',
        '',
    ]
readme += ['## Assets', '', '| asset | content |', '|---|---|']
for name, entry in payloads.items():
    if entry['kind'] == 'whole':
        readme.append(f'| `{name}` | {entry["bytes"]} bytes |')
    else:
        readme.append(f'| `{name}.part-NN` | {entry["bytes"]} bytes, {len(entry["parts"])} parts |')
readme += [
    '| `bundle.json` | bundle manifest (upstream-compatible + Fedora extension) |',
    '| `liuqin-install.py`, `install.py`, `install-liuqin.ps1`, `liuqin_layout.py`, `liuqin-rom-images.json` | host-side installer (Windows and Linux) |',
    '| `LICENSE`, `NOTICE` | licence and firmware/redistribution notice |',
    '| `INSTALL.md` | install and verification steps |',
    '| `release-manifest.json` | machine-readable asset list with sha256 |',
    '| `SHA256SUMS` | sha256 of every other asset |',
    '',
    '## Verify and join split payloads',
    '',
    '```sh',
    'sha256sum -c SHA256SUMS',
    'cat rootfs.tar.gz.part-* > rootfs.tar.gz',
    '```',
    '',
]
(directory / 'README.md').write_text('\n'.join(readme) + '\n')

install = [
    f'# Installing {bundle_name}',
    '',
    'Read `INSTALL.md` in the project repository first; this file only',
    'summarises the release-asset steps.',
    '',
    '1. Verify the assets: `sha256sum -c SHA256SUMS`.',
    '2. Join split payloads: `cat rootfs.tar.gz.part-* > rootfs.tar.gz`',
    '   (and `cat root.img.part-* > root.img` when shipped).',
    '3. Local check, no device: `python3 install.py --bundle . --check`.',
    '4. Rehearsal, no device writes:',
    '   `python3 install.py --bundle . --serial SERIAL --backup ~/liuqin-backup \\',
    '     --erase-userdata --layout linux-only --allow-unverified --dry-run`.',
    '5. A real installation needs the attended-write gate described in `INSTALL.md`',
    '   (`--yes-write-device`), a matching stock Fastboot ROM, a private backup and',
    '   the tablet physically present.',
    '',
]
if not_for_hardware:
    install += ['**Do not run step 5 with this bundle**: `device_ready=false`.']
else:
    install += ['`device_ready=true` only removes the build-time blockers; hardware',
                'verification is still required before step 5.']
install += ['',
            'Keep `bundle.json`, `boot.img`, `installer.img` and the joined',
            '`rootfs.tar.gz` next to the installer scripts; the installer refuses a',
            'bundle whose hashes do not match `bundle.json`.', '']
(directory / 'INSTALL.md').write_text('\n'.join(install) + '\n')

assets = []
for name, entry in payloads.items():
    if entry['kind'] == 'whole':
        assets.append({'name': name, 'role': 'payload', 'bytes': entry['bytes'],
                       'sha256': entry['sha256'], 'split': False})
    else:
        for part in entry['parts']:
            assets.append({'name': part['name'], 'role': 'payload-part',
                           'bytes': part['bytes'], 'sha256': part['sha256'], 'split': True})
for name in ('bundle.json', 'LICENSE', 'NOTICE', 'install.py', 'liuqin-install.py',
             'install-liuqin.ps1', 'liuqin_layout.py',
             'liuqin-rom-images.json', 'README.md', 'INSTALL.md'):
    path = directory / name
    assets.append({'name': name, 'role': 'metadata', 'bytes': path.stat().st_size,
                   'sha256': sha(path), 'split': False})
manifest = {
    'format': 'liuqin-release-assets/1',
    'bundle_name': bundle_name,
    'kernel_release': kernel_release,
    'fedora_release': fedora_release,
    'device_ready': device_ready,
    'offline_only': offline_only == 'True',
    'redistribution': redistribution,
    'policy_label': labels,
    'part_size_bytes': int(part_bytes),
    'payloads': payloads,
    'assets': assets,
}
(directory / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
lines = []
for path in sorted(directory.iterdir()):
    if path.name in ('SHA256SUMS', 'release-manifest.json') or not path.is_file():
        continue
    lines.append(f'{sha(path)}  {path.name}')
lines.append(f'{sha(directory / "release-manifest.json")}  release-manifest.json')
(directory / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
print(f'release-manifest.json: {len(assets)} assets, {len(payloads)} payloads')
PY

say "assets written: $(ls -1 "$out" | wc -l) files"
say "verify with: scripts/make-release-assets.sh --verify $out"
