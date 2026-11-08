#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline test for scripts/make-release-assets.sh.
#
# Builds a synthetic bundle in a temporary directory (with a payload larger than
# the split threshold), exercises the policy gates, the dry-run, the real
# packaging, the generated manifest/checksums and the --verify mode.  No device,
# no network, nothing outside the temporary directory.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
script=$project_root/scripts/make-release-assets.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/liuqin-release-assets-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
fail() { printf 'test-release-assets: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[ -x "$script" ] || fail "not executable: $script"

# Synthetic bundle: device_ready=false and private firmware, so both policy
# acknowledgements are required.  rootfs.tar.gz is 3 MiB and root.img 2.5 MiB,
# both above the 1 MiB split threshold used below.
bundle=$work/bundle
mkdir -p "$bundle"
printf 'boot-image-fixture' >"$bundle/boot.img"
printf 'installer-image-fixture' >"$bundle/installer.img"
head -c 3145728 /dev/urandom >"$bundle/rootfs.tar.gz"
head -c 2500000 /dev/urandom >"$bundle/root.img"
printf 'MIT License\nfixture\n' >"$bundle/LICENSE"
printf 'liuqin firmware is not redistributable.\n' >"$bundle/NOTICE"
printf '# fixture verification\n' >"$bundle/VERIFICATION.md"
python3 - "$bundle" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

bundle = Path(sys.argv[1])


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


manifest = {
    'format': 'liuqin-bundle/1',
    'device': 'liuqin',
    'name': bundle.name,
    'status': 'OFFLINE_BUILT',
    'device_ready': False,
    'offline_only': True,
    'device_ready_reasons': ['fixture bundle'],
    'kernel_release': '6.17.0-rc1-gfe81794b5e1b',
    'fedora': {'release': '44', 'contract': '/etc/liuqin-fedora-root.contract'},
    'redistribution': 'private-local-only',
    'files': {name: sha(bundle / name) for name in
              ('boot.img', 'installer.img', 'rootfs.tar.gz', 'root.img')},
}
(bundle / 'bundle.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY

assets=$work/assets
# Policy gates: both acknowledgements are required and the failure is explicit.
if sh "$script" --bundle "$bundle" --out "$assets" --part-size 1M >"$work/policy.log" 2>&1; then
	fail 'a device_ready=false + private bundle was packaged without acknowledgements'
fi
grep -q 'device_ready' "$work/policy.log" || fail 'the device_ready policy refusal is not explained'
if sh "$script" --bundle "$bundle" --out "$assets" --part-size 1M --dev-release \
	>"$work/policy2.log" 2>&1; then
	fail 'a private-firmware bundle was packaged without --private-local'
fi
grep -q 'private' "$work/policy2.log" || fail 'the private-firmware refusal is not explained'
pass 'release packaging refuses unacknowledged dev/private bundles'

# Dry run writes nothing but prints the plan and the policy label.
sh "$script" --bundle "$bundle" --out "$assets" --part-size 1M --dev-release \
	--private-local --dry-run >"$work/dry.log" 2>&1 ||
	fail 'dry-run failed: ' "$(cat "$work/dry.log")"
[ ! -e "$assets" ] || fail 'dry-run created the output directory'
grep -q 'DEVONLY-PRIVATE-LOCAL' "$work/dry.log" || fail 'dry-run does not print the policy label'
grep -q 'rootfs.tar.gz' "$work/dry.log" || fail 'dry-run does not plan rootfs.tar.gz'
grep -q '3 parts' "$work/dry.log" || fail 'dry-run does not plan the split parts'
pass 'dry-run plans the assets and writes nothing'

# Real packaging.
sh "$script" --bundle "$bundle" --out "$assets" --part-size 1M --dev-release \
	--private-local >"$work/pack.log" 2>&1 ||
	fail 'packaging failed: ' "$(cat "$work/pack.log")"
for expected in boot.img installer.img bundle.json LICENSE NOTICE README.md INSTALL.md \
	install.py liuqin-install.py prepare-image.py install-liuqin.ps1 install-liuqin.cmd \
	liuqin_layout.py liuqin-rom-images.json release-manifest.json SHA256SUMS; do
	[ -f "$assets/$expected" ] || fail "missing release asset: $expected"
done
[ ! -f "$assets/rootfs.tar.gz" ] || fail 'the unsplit rootfs.tar.gz was shipped next to its parts'
[ ! -f "$assets/root.img" ] || fail 'the unsplit root.img was shipped next to its parts'
[ "$(ls "$assets/rootfs.tar.gz".part-* | wc -l)" = 3 ] || fail 'rootfs.tar.gz was not split into 3 parts'
[ "$(ls "$assets/root.img".part-* | wc -l)" = 3 ] || fail 'root.img was not split into 3 parts'
pass 'payloads above the split threshold are shipped as .part-NN assets'

# Join instructions really reproduce the payload hashes.
cat "$assets/rootfs.tar.gz".part-* >"$work/rootfs.joined"
cmp -s "$work/rootfs.joined" "$bundle/rootfs.tar.gz" || fail 'joining the parts does not reproduce rootfs.tar.gz'
cat "$assets/root.img".part-* >"$work/rootimg.joined"
cmp -s "$work/rootimg.joined" "$bundle/root.img" || fail 'joining the parts does not reproduce root.img'
pass 'joining the split parts reproduces the original payloads byte for byte'

# Generated manifest and checksums are consistent.
python3 - "$assets" <<'PY' || exit 1
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
manifest = json.loads((directory / 'release-manifest.json').read_text())
assert manifest['format'] == 'liuqin-release-assets/1', manifest['format']
assert manifest['device_ready'] is False
assert manifest['policy_label'] == 'DEVONLY-PRIVATE-LOCAL', manifest['policy_label']
rootfs = manifest['payloads']['rootfs.tar.gz']
assert rootfs['kind'] == 'split' and len(rootfs['parts']) == 3, rootfs
names = {entry['name'] for entry in manifest['assets']}
for required in ('liuqin-install.py', 'prepare-image.py', 'install-liuqin.ps1',
                 'install-liuqin.cmd'):
    assert required in names, required
rootimg = manifest['payloads']['root.img']
assert rootimg['kind'] == 'split' and len(rootimg['parts']) == 3, rootimg
names = {asset['name'] for asset in manifest['assets']}
for name in ('rootfs.tar.gz.part-00', 'rootfs.tar.gz.part-02', 'boot.img', 'README.md'):
    assert name in names, name
readme = (directory / 'README.md').read_text()
assert 'NOT A HARDWARE INSTALL CANDIDATE' in readme
assert 'PRIVATE LOCAL ASSETS' in readme
install = (directory / 'INSTALL.md').read_text()
assert '--dry-run' in install and '--yes-write-device' in install
assert 'Do not run step 5' in install
PY
pass 'release-manifest.json, README and INSTALL describe the dev/private policy truthfully'

# SHA256SUMS verifies with the system tool, and --verify re-checks everything.
(cd "$assets" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail 'sha256sum -c rejects the assets'
sh "$script" --verify "$assets" >"$work/verify.log" 2>&1 ||
	fail 'asset verification failed: ' "$(cat "$work/verify.log")"
grep -q 'PASS: release assets verified' "$work/verify.log" || fail 'verification did not report PASS'
pass 'SHA256SUMS and --verify accept the packaged assets'

# A corrupted asset is caught.
printf 'tampered' >>"$assets/boot.img"
if sh "$script" --verify "$assets" >"$work/corrupt.log" 2>&1; then
	fail 'verification accepted a corrupted asset'
fi
grep -q 'sha256 mismatch' "$work/corrupt.log" || fail 'corruption was not reported as a hash mismatch'
pass 'a corrupted asset fails verification'

# Overwrite protection and --force.
if sh "$script" --bundle "$bundle" --out "$assets" --part-size 1M --dev-release \
	--private-local >"$work/exists.log" 2>&1; then
	fail 'packaging overwrote an existing output directory without --force'
fi
grep -q 'already exists' "$work/exists.log" || fail 'overwrite refusal is not explained'
sh "$script" --bundle "$bundle" --out "$assets" --part-size 1M --dev-release \
	--private-local --force >"$work/force.log" 2>&1 || fail '--force repackaging failed'
sh "$script" --verify "$assets" >/dev/null 2>&1 || fail 'repackaged assets do not verify'
pass 'existing output requires --force and the repackaged assets verify'

# --no-root-img ships the installer payload set only.
other=$work/assets-no-root
sh "$script" --bundle "$bundle" --out "$other" --part-size 1M --dev-release \
	--private-local --no-root-img >"$work/norootimg.log" 2>&1 ||
	fail 'packaging with --no-root-img failed'
[ ! -e "$other/root.img.part-00" ] || fail '--no-root-img still shipped root.img'
python3 - "$other" <<'PY' || exit 1
import json
import sys
from pathlib import Path
manifest = json.loads((Path(sys.argv[1]) / 'release-manifest.json').read_text())
assert 'root.img' not in manifest['payloads'], manifest['payloads'].keys()
PY
pass '--no-root-img ships the installer payload set only'

printf '%s\n' 'liuqin release-assets tests: PASS'
