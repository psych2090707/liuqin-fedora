#!/bin/bash
# Build only the clock-support candidate; no network, image build or activation.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/out/tn0094-store-update-audit/clock-candidate-v4"}
mkdir -p "$out"
out=$(realpath "$out")
stage=$out/SOURCES/liuqin-clock-support-1.0
[ ! -e "$stage" ] || { echo "stage exists: $stage; choose a new output" >&2; exit 1; }
mkdir -p "$stage" "$out/SPECS"
cp "$root/packaging/clock/"*.py "$root/packaging/clock/"*.service \
   "$root/packaging/clock/"*.timer "$root/packaging/clock/README.md" "$stage/"
cp "$root/LICENSE" "$stage/LICENSE"
cp "$root/packaging/clock/liuqin-clock-support.spec" "$out/SPECS/"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@1793318400 \
    -czf "$out/SOURCES/liuqin-clock-support-1.0.tar.gz" \
    -C "$out/SOURCES" liuqin-clock-support-1.0
builder=$(sudo -n podman image inspect --format '{{.Id}}' localhost/liuqin-rpmbuild:fc45)
platform=$(sudo -n podman image inspect --format '{{.Os}}/{{.Architecture}}' "$builder")
sudo -n podman run --rm --network=none --pull=never --platform "$platform" \
    --security-opt label=disable -v "$out:/build" "$builder" \
    rpmbuild -bb --define '_topdir /build' --define 'dist .fc45' \
    /build/SPECS/liuqin-clock-support.spec
sha256sum "$out"/RPMS/noarch/*.rpm "$out"/SOURCES/*.tar.gz > "$out/SHA256SUMS"
python3 - "$out" "$builder" "$platform" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

out = Path(sys.argv[1])
paths = sorted(p for p in (out / 'SOURCES/liuqin-clock-support-1.0').iterdir() if p.is_file())
paths += sorted((out / 'SPECS').glob('*.spec'))
record = {'builder_image_id': sys.argv[2], 'platform': sys.argv[3],
          'network': 'none', 'source_date_epoch': 1793318400,
          'inputs': {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in paths}}
(out / 'build-info.json').write_text(json.dumps(record, indent=2) + '\n')
PY
