#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-docs.sh — lightweight offline check for relative Markdown links.
#
# Scans the public documentation set (root documents, the release templates and
# the READMEs under the source directories) and verifies that every relative
# Markdown link resolves.  External http(s)/mailto links and pure anchors are
# ignored; no network access and no build artifacts are needed.
#
# Historical archives, the private task tree, upstream clones, build outputs
# and generated tools trees are intentionally excluded.
#
# Usage:
#   scripts/check-docs.sh            # report broken links
#   scripts/check-docs.sh --quiet    # only print failures and the summary
#
# Exit codes: 0 = no broken links, 1 = broken links found, 2 = usage error.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
QUIET=0

while [ $# -gt 0 ]; do
	case "$1" in
		--quiet|-q) QUIET=1; shift ;;
		-h|--help) awk 'NR > 1 && /^set / { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'check-docs: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

python3 - "$ROOT" "$QUIET" <<'PY'
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

root = Path(sys.argv[1]).resolve()
quiet = sys.argv[2] == "1"

SKIP_DIRS = {"upstream", "out", "cache", "images", "mkosi.tools",
             ".git", ".archify", "tasks", "node_modules"}
SKIP_PREFIXES = (Path("docs/archive"), Path("tests/docs"))
MARKDOWN_SUFFIXES = (".md", ".md.in")
LINK_RE = re.compile(r"\]\(([^)\n]+)\)")


def wanted(path: Path) -> bool:
    rel = path.relative_to(root)
    if any(part in SKIP_DIRS for part in rel.parts):
        return False
    if any(rel == p or rel.is_relative_to(p) for p in SKIP_PREFIXES):
        return False
    return path.name.endswith(MARKDOWN_SUFFIXES)


files = sorted(p for p in root.rglob("*") if p.is_file() and wanted(p))
if not files:
    print("check-docs: no Markdown files found", file=sys.stderr)
    sys.exit(2)

broken = []
checked = 0
for path in files:
    if path.relative_to(root).as_posix() == "docs/maintenance/docs-checks.md":
        continue  # intentionally contains broken examples
    text = path.read_text(errors="replace")
    for line_no, line in enumerate(text.splitlines(), 1):
        for match in LINK_RE.finditer(line):
            target = match.group(1).split()[0]
            if target.startswith(("http://", "https://", "mailto:", "data:", "#")):
                continue
            target = unquote(target.split("#", 1)[0])
            if not target or any(c in target for c in "<>{}$"):
                continue
            checked += 1
            # Release templates are rendered at the repository root; sibling
            # templates are also accepted while checking the template itself.
            template = path.parent == root / "packaging/release/public"
            base = root if template else path.parent
            exists = (base / target).resolve().exists()
            if not exists and template:
                exists = (path.parent / (target + ".in")).exists()
            if not exists:
                broken.append((path.relative_to(root).as_posix(), line_no, match.group(1)))

if broken:
    for rel, line_no, target in broken:
        print(f"[FAIL] {rel}:{line_no}: broken relative link: {target}")
else:
    if not quiet:
        print("[PASS] all relative Markdown links resolve")

print(f"check-docs: {len(files)} Markdown files, {checked} relative links, "
      f"{len(broken)} broken -> {'FAIL' if broken else 'PASS'}")
sys.exit(1 if broken else 0)
PY
