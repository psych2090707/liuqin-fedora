#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-docs.sh — offline consistency checker for the project's Markdown docs.
#
# Checks (no network, no build artifacts required):
#   1. relative Markdown links exist (http(s) links are format-checked only)
#   2. project paths/scripts referenced in backticks exist
#      (upstream-repo shorthand like `tools/install-liuqin.py` -> WARN, not FAIL)
#   3. status vocabulary is canonical + consistent with docs/GLOSSARY.md
#      (hardware-support.md must carry the core status terms)
#   4. the explicit allowlist (tests/docs/known_lags.txt) is honoured, listed,
#      and every known-lag file is mentioned in docs/INDEX.md §8
#
# Usage:
#   scripts/check-docs.sh                 # full offline check (exit != 0 on FAIL)
#   scripts/check-docs.sh --strict        # WARN also fails (CI gate)
#   scripts/check-docs.sh --json          # machine-readable result
#   scripts/check-docs.sh --list-known    # emit the allowlist as a Markdown table
#   scripts/check-docs.sh --fix-links     # only fix `../` depth errors with a unique solution
#   scripts/check-docs.sh --root DIR      # check a fixture tree instead of the repo
#   scripts/check-docs.sh --online        # optional: curl HEAD the http(s) links (slow)
#
# Exit codes: 0 PASS/WARN only, 1 FAIL, 2 usage/environment error.
# The checker is read-only unless --fix-links is given (and then only touched files).
set -uo pipefail

export CHECK_DOCS_ROOT
CHECK_DOCS_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$@" <<'PYEOF'
import argparse
import fnmatch
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

CANON_CORE = ["verified-upstream", "verified-offline", "pending-device", "blocked",
              "unsupported-upstream", "not-ported", "device_ready"]
CANON_ALIASES = ["verified-device", "verified-source", "DEVICE_TESTED", "device_ready_reasons"]
PATH_ROOTS = ("scripts", "tools", "installer", "initramfs", "kernel", "packaging",
              "overlays", "mkosi", "tests", "docs", "tasks")
STATUS_RE = re.compile(r"\b(?:verified-(?:upstream|offline|source|device)|pending-device|"
                       r"unsupported-upstream|not-ported|blocked(?:-upstream)?|"
                       r"device[_-](?:ready(?:_reasons)?|tested))\b|\bDEVICE_TESTED\b")
BAD_VARIANTS = {
    "device-ready": "device_ready", "device ready": "device_ready",
    "verified offline": "verified-offline", "pending device": "pending-device",
    "unsupported upstream": "unsupported-upstream", "not ported": "not-ported",
    "device-tested": "DEVICE_TESTED (bundle status)", "blocked-upstream": "blocked",
}

class Result:
    def __init__(self, level, check, message, file="", fix=""):
        self.level, self.check, self.message, self.file, self.fix = level, check, message, file, fix
    def as_dict(self):
        return {"level": self.level, "check": self.check, "file": self.file,
                "message": self.message, "fix": self.fix}

def parse_args(argv):
    p = argparse.ArgumentParser(prog="check-docs.sh", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", default=None, help="project root (default: parent of scripts/)")
    p.add_argument("--allowlist", default=None, help="allowlist file (default: <root>/tests/docs/known_lags.txt)")
    p.add_argument("--strict", action="store_true", help="treat WARN as failure")
    p.add_argument("--json", action="store_true", help="emit JSON result")
    p.add_argument("--list-known", action="store_true", help="emit the allowlist as Markdown and exit")
    p.add_argument("--fix-links", action="store_true", help="fix uniquely-solvable `../` link depth errors")
    p.add_argument("--online", action="store_true", help="curl-HEAD external http(s) links (slow, optional)")
    p.add_argument("--skip-status", action="store_true", help="skip status vocabulary checks")
    p.add_argument("--no-index-sync", action="store_true", help="skip docs/INDEX.md §8 allowlist sync")
    p.add_argument("--quiet", action="store_true", help="only print failures/warnings")
    return p.parse_args(argv)

def md_files(root):
    out = []
    for name in ("README.md", "AGENTS.md"):
        p = root / name
        if p.is_file():
            out.append(p)
    for sub in ("docs", "tasks"):
        d = root / sub
        if d.is_dir():
            out.extend(sorted(d.rglob("*.md")))
    for d in sorted(root.iterdir()):
        if not d.is_dir():
            continue
        if d.name in ("upstream", "out", "cache", "images", ".git", "node_modules") or d.name.startswith("."):
            continue
        p = d / "README.md"
        if p.is_file():
            out.append(p)
    blocked_parts = ("/upstream/", "/out/", "/cache/", "/images/", "/.git/", "/mkosi.tools/")
    kept = []
    for p in out:
        rel = p.relative_to(root).as_posix()
        if rel.startswith("tests/docs/fixtures/"):
            continue  # self-test fixtures contain intentional violations
        if any(b in p.as_posix() for b in blocked_parts):
            continue
        kept.append(p)
    return kept

def load_allowlist(path):
    entries = []
    if not path.is_file():
        return entries
    for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [x.strip() for x in line.split("|")]
        if len(parts) < 4:
            raise SystemExit(f"--allowlist: {path}:{lineno}: expected kind|file|ref|reason[|owner]")
        kind, file_pat, ref, reason = parts[:4]
        owner = parts[4] if len(parts) > 4 else ""
        entries.append({"kind": kind, "file": file_pat, "ref": ref, "reason": reason,
                        "owner": owner, "line": lineno, "matched": False})
    return entries

def match_entry(entries, kind, file, ref):
    for e in entries:
        if e["kind"] != kind:
            continue
        if not fnmatch.fnmatch(file, e["file"]):
            continue
        if e["ref"] and not (fnmatch.fnmatch(ref, e["ref"]) or ref == e["ref"]):
            continue
        e["matched"] = True
        return e
    return None

def iter_markdown_links(text):
    """Yield (line, target) for `](target)` outside fenced code blocks."""
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in re.finditer(r"\]\(([^)]+)\)", line):
            yield lineno, m.group(1)

def code_spans(text):
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in re.finditer(r"`([^`]+)`", line):
            yield lineno, m.group(1)

def is_upstream_shorthand(root, ref):
    up = root / "upstream"
    if not up.is_dir():
        return False
    candidates = [up / ref]
    for child in up.iterdir():
        if child.is_dir():
            candidates.append(child / ref)
    return any(c.exists() for c in candidates)

# Files that intentionally contain broken examples/rules: never check their
# link/path/status content. docs/INDEX.md §8 (allowlist mirror) is cut too.
SELF_EXEMPT = {"docs/maintenance/docs-checks.md"}
# Frozen historical snapshots: links must resolve, but their path/status
# wording is preserved verbatim and not re-validated.
ARCHIVE_PREFIXES = ("docs/archive/", "tasks/archive/")

def checkable_text(relf, text, content=True):
    """INDEX §8 intentionally quotes known-lag tokens; exclude it from
    link/path/status checks so the allowlist mirror does not fail itself."""
    if relf in SELF_EXEMPT:
        return ""
    if content and relf.startswith(ARCHIVE_PREFIXES):
        return ""
    if relf == "docs/INDEX.md" and "## 8." in text:
        return text.split("## 8.", 1)[0]
    return text

def check_links(root, files, entries, results, fix_links):
    for f in files:
        relf = f.relative_to(root).as_posix()
        text = checkable_text(relf, f.read_text(errors="replace"), content=False)
        for lineno, raw in iter_markdown_links(text):
            target = raw.split("#")[0].strip()
            if not target:
                continue
            if target.startswith(("http://", "https://")):
                if " " in target:
                    results.append(Result("FAIL", "link-format", f"malformed URL: {target}", relf))
                continue
            if target.startswith(("mailto:", "data:")) or target.startswith("#"):
                continue
            if any(c in target for c in "<>{}$"):
                continue  # placeholder/template
            base = (root / f.parent.relative_to(root)).resolve()
            p = (base / target).resolve()
            if p.exists():
                continue
            allow = match_entry(entries, "link", relf, raw)
            if allow:
                results.append(Result("KNOWN", "link", f"{raw} -> {allow['reason']}", relf))
                continue
            # unique `../` depth fix (opt-in only)
            fixed = None
            if fix_links:
                cands = []
                cur = target
                if cur.startswith("../"):
                    cands.append(cur[3:])
                cands.append("../" + cur)
                existing = [c for c in cands if (base / c).exists()]
                if len(existing) == 1:
                    fixed = existing[0]
            if fixed:
                # rewrite the full file, not the (possibly truncated) checkable text
                full = f.read_text(errors="replace")
                f.write_text(full.replace(f"]({raw})", f"]({fixed})"))
                results.append(Result("FIXED", "link", f"{raw} -> {fixed}", relf))
            else:
                results.append(Result("FAIL", "link", f"broken relative link: {raw}",
                                      relf, "fix path or add to tests/docs/known_lags.txt"))
    return results

def check_paths(root, files, entries, results):
    for f in files:
        relf = f.relative_to(root).as_posix()
        text = checkable_text(relf, f.read_text(errors="replace"))
        for lineno, span in code_spans(text):
            token = span.strip().strip(".,;:()[]").strip()
            # strip :line / :1-2 / :3/4/5 references ("file:19-25")
            token = re.sub(r":[0-9][0-9,/\u2013-]*$", "", token)
            if not token or " " in token or "|" in token or any(c in token for c in "<>{}$*?`\\"):
                continue
            if any(ph in token for ph in ("xxxx", "...", "…", "XXX")):
                continue
            if not any(token.startswith(r + "/") for r in PATH_ROOTS):
                continue
            if token.startswith(("http://", "https://")):
                continue
            candidates = [(root / token).resolve(), (f.parent / token).resolve()]
            if any(c.exists() for c in candidates):
                continue
            if token.rstrip('/') == "mkosi/mkosi.tools" or token.startswith("mkosi/mkosi.tools/"):
                results.append(Result("KNOWN", "path",
                    f"{token} -> optional generated mkosi tools tree (may be cleaned)", relf))
                continue
            allow = match_entry(entries, "path", relf, token)
            if allow:
                results.append(Result("KNOWN", "path", f"{token} -> {allow['reason']}", relf))
                continue
            if is_upstream_shorthand(root, token):
                results.append(Result("WARN", "path",
                    f"{token} is upstream-repo relative (add upstream/ prefix when clarifying)", relf))
                continue
            results.append(Result("FAIL", "path", f"missing referenced path: {token}",
                                  relf, "fix/remove reference or allowlist with reason"))
    return results

def check_status(root, files, entries, results):
    gl = root / "docs" / "GLOSSARY.md"
    if not gl.is_file():
        results.append(Result("FAIL", "status", "docs/GLOSSARY.md missing (status vocabulary source)", "docs/GLOSSARY.md"))
        return results
    gtext = gl.read_text(errors="replace")
    glossary = set(re.findall(r"^\|\s*`([A-Za-z0-9_-]+)`\s*\|", gtext, re.M))
    canonical = set(CANON_CORE) | {a for a in CANON_ALIASES if a in glossary}
    for term in CANON_CORE:
        if term not in glossary:
            results.append(Result("FAIL", "status", f"GLOSSARY.md does not define `{term}`", "docs/GLOSSARY.md"))
    # hardware-support must carry the core status vocabulary
    hs = root / "docs" / "hardware-support.md"
    if hs.is_file():
        htext = hs.read_text(errors="replace")
        for term in CANON_CORE:
            if term not in htext:
                results.append(Result("FAIL", "status", f"hardware-support.md lacks core term `{term}`", "docs/hardware-support.md"))
    else:
        results.append(Result("FAIL", "status", "docs/hardware-support.md missing", "docs/hardware-support.md"))
    for f in files:
        relf = f.relative_to(root).as_posix()
        if relf in ("docs/GLOSSARY.md", "docs/maintenance/docs-checks.md"):
            continue
        text = checkable_text(relf, f.read_text(errors="replace"))
        low = text.lower()
        for bad, good in BAD_VARIANTS.items():
            if bad in low:
                allow = match_entry(entries, "status", relf, bad)
                msg = f"non-canonical status spelling: '{bad}' (use `{good}`)"
                if allow:
                    results.append(Result("KNOWN", "status", msg + f" -> {allow['reason']}", relf))
                else:
                    results.append(Result("FAIL", "status", msg, relf, "rename to canonical token"))
        for m in STATUS_RE.finditer(text):
            tok = m.group(0)
            if tok in canonical or tok in glossary:
                continue
            allow = match_entry(entries, "status", relf, tok)
            if allow:
                results.append(Result("KNOWN", "status", f"non-canonical status token '{tok}' -> {allow['reason']}", relf))
            else:
                results.append(Result("FAIL", "status", f"undefined status token '{tok}'",
                                      relf, "add to GLOSSARY.md or fix the token"))
    return results

def check_index_sync(root, entries, results):
    idx = root / "docs" / "INDEX.md"
    if not idx.is_file():
        results.append(Result("FAIL", "index", "docs/INDEX.md missing", "docs/INDEX.md"))
        return results
    text = idx.read_text(errors="replace")
    if "## 8." in text:
        sec = text.split("## 8.", 1)[1]
    else:
        results.append(Result("FAIL", "index",
            "docs/INDEX.md has no §8 known-lags section", "docs/INDEX.md",
            "add `## 8. 已知文档滞后项（脚本可发现）` with rows from --list-known"))
        return results
    seen = set()
    for e in entries:
        if e["kind"] not in ("link", "path", "content"):
            continue
        ref_file = e["file"]
        if any(c in ref_file for c in "*?"):
            continue
        if ref_file in seen:
            continue
        seen.add(ref_file)
        if ref_file not in sec:
            results.append(Result("FAIL", "index",
                f"known-lag file {ref_file} is not listed in docs/INDEX.md §8", "docs/INDEX.md",
                "add a row to §8 (scripts/check-docs.sh --list-known)"))
    return results

def check_allowlist_staleness(entries, results):
    for e in entries:
        if e["kind"] in ("content",):
            continue
        if not e["matched"]:
            results.append(Result("WARN", "allowlist",
                f"stale allowlist entry (no longer triggers): {e['kind']} {e['file']} {e['ref']}",
                "tests/docs/known_lags.txt", "remove or update the entry"))
    return results

def online_links(root, files, results):
    checked = set()
    for f in files:
        for _, raw in iter_markdown_links(f.read_text(errors="replace")):
            if not raw.startswith(("http://", "https://")) or raw in checked:
                continue
            checked.add(raw)
            try:
                req = urllib.request.Request(raw, method="HEAD",
                                             headers={"User-Agent": "liuqin-check-docs/1.0"})
                urllib.request.urlopen(req, timeout=8)
            except Exception as exc:
                results.append(Result("WARN", "online", f"{raw}: {exc.__class__.__name__}",
                                      f.relative_to(root).as_posix()))
    return results

def print_known(entries):
    print("| 位置 | 问题 | 建议/原因 | owner |")
    print("|---|---|---|---|")
    for e in entries:
        ref = e["ref"].replace("|", "\\|")
        print(f"| `{e['file']}` | `{ref}` | {e['reason']} | {e['owner'] or '—'} |")

def main(argv):
    args = parse_args(argv)
    root = Path(args.root).resolve() if args.root else Path(os.environ.get("CHECK_DOCS_ROOT", ".")).resolve()
    if not root.is_dir():
        print(f"check-docs: root not found: {root}", file=sys.stderr)
        return 2
    allow_path = Path(args.allowlist).resolve() if args.allowlist else root / "tests" / "docs" / "known_lags.txt"
    try:
        entries = load_allowlist(allow_path)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if args.list_known:
        print_known(entries)
        return 0
    files = md_files(root)
    if not files:
        print(f"check-docs: no Markdown files under {root}", file=sys.stderr)
        return 2
    results = []
    check_links(root, files, entries, results, args.fix_links)
    check_paths(root, files, entries, results)
    if not args.skip_status:
        check_status(root, files, entries, results)
    if not args.no_index_sync:
        check_index_sync(root, entries, results)
    check_allowlist_staleness(entries, results)
    if args.online:
        online_links(root, files, results)
    fails = [r for r in results if r.level == "FAIL"]
    warns = [r for r in results if r.level == "WARN"]
    known = [r for r in results if r.level == "KNOWN"]
    fixed = [r for r in results if r.level == "FIXED"]
    if args.json:
        print(json.dumps({"root": str(root), "files": len(files), "allowlist": str(allow_path),
                          "counts": {"WARN": len(warns), "FAIL": len(fails),
                                     "KNOWN": len(known), "FIXED": len(fixed)},
                          "fail": [r.as_dict() for r in fails],
                          "warn": [r.as_dict() for r in warns],
                          "known": [r.as_dict() for r in known],
                          "fixed": [r.as_dict() for r in fixed]}, indent=2, ensure_ascii=False))
    else:
        for r in results:
            if args.quiet and r.level in ("KNOWN",):
                continue
            fix = f"  [fix: {r.fix}]" if r.fix else ""
            loc = f"{r.file} " if r.file else ""
            print(f"[{r.level}] {r.check}: {loc}{r.message}{fix}")
    if fails:
        code = 1
    elif args.strict and (warns or fixed):
        code = 1
    else:
        code = 0
    if not args.json:
        print(f"\ncheck-docs: {len(files)} markdown files, FAIL={len(fails)} WARN={len(warns)} "
              f"KNOWN={len(known)} FIXED={len(fixed)} -> {'PASS' if code == 0 else 'FAIL'}")
    return code

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
