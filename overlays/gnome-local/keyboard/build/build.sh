#!/usr/bin/env bash
# Rebuild only the small OSK extension resources, not a system image.
set -euo pipefail
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
python3 "$here/gen_layouts.py"
glib-compile-resources --sourcedir="$here/layouts" \
    --target="$here/osk-layouts.gresource" "$here/osk-layouts.gresource.xml"
cp "$here/osk-layouts.gresource" "$here/../extension/osk-layouts.gresource"
python3 - "$here" <<'PY'
import hashlib
from pathlib import Path
import sys
base = Path(sys.argv[1])
digest = hashlib.sha256((base / 'layouts/us.json').read_bytes()).hexdigest()
(base / '../extension/expected.sha256').write_text(digest + '  layouts/us.json\n')
print('expected us.json sha256:', digest)
PY
