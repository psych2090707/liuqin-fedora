#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Create a reviewable public source tree from explicitly allowed roots.

Does not copy Git history, connect to GitHub or publish anything. Original
source and development records are left untouched. The output must be new.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote

PROJECT = Path(__file__).resolve().parents[2]
ROOTS = ('kernel', 'initramfs', 'installer', 'mkosi', 'overlays', 'packaging',
         'rust', 'scripts', 'tools', 'tests')
EXTRA = ('docs/research/liuqin-assets.json',)
OMIT = ('tools/afk/keys/id_', 'tests/docs/',
        'tools/resume-install-root.py', 'packaging/device/SPEC-DELTA.md',
        'packaging/mobile/fingerprint/README-libfprint-tod-BLOCKED.md')
GITIGNORE = '''upstream/
out/
images/
cache/
mkosi.rootfs/
.mkosi*/
rust/target/
prepared*/
backup*/
tools/local/
tools/afk/afk.env
tools/afk/keys/id_*
*.img
*.rpm
*.tar
*.tar.gz
*.tar.xz
*.tar.zst
*.zip
*.part-*
*.env
__pycache__/
*.pyc
.directory
.vscode/
'''


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def clean_doc_links(out):
    removed = []
    for path in out.rglob('*.md'):
        text = path.read_text()

        def replace(match):
            label, link = match.group(1), match.group(2)
            if link.startswith(('http:', 'https:', 'mailto:', '#')):
                return match.group(0)
            target = unquote(link.split('#', 1)[0].split(' "', 1)[0])
            if not target:
                return match.group(0)
            if (path.parent / target).exists():
                return match.group(0)
            # Archived local evidence is not part of the public release.
            # Keep explanatory labels rather than dead or private links.
            removed.append({'document': str(path.relative_to(out)), 'reference': link})
            return label

        text = re.sub(r'\[([^\]\n]+)\]\(([^)\n]+)\)', replace, text)
        path.write_text(text)
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        parser.error('output exists; use a new directory')
    raw = subprocess.check_output(['git', '-C', str(PROJECT), 'ls-files', '-z',
                                   '--cached', '--others', '--exclude-standard', '--', *ROOTS, *EXTRA])
    names = sorted(set(p.decode() for p in raw.split(b'\0') if p))
    copied = []
    out.mkdir(parents=True)
    for name in names:
        if name.startswith(OMIT) or '/__pycache__/' in name or name.endswith('.pyc'):
            continue
        source = PROJECT / name
        if not source.is_file() and not source.is_symlink():
            continue
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target.symlink_to(source.readlink())
        else:
            shutil.copy2(source, target)
        copied.append(name)
    shutil.copy2(PROJECT / 'LICENSE', out / 'LICENSE')
    shutil.copy2(PROJECT / 'NOTICE', out / 'NOTICE')
    (out / '.gitignore').write_text(GITIGNORE)
    # Patch context lines intentionally carry their original leading/trailing
    # whitespace; checking them as newly written code gives false errors.
    (out / '.gitattributes').write_text('*.patch -whitespace\n*.diff -whitespace\n*.tsv -whitespace\n')
    (out / 'AGENTS.md').write_text(
        '# Working on liuqin Fedora Remix\n\n'
        'This repository builds an experimental Fedora 45 / GNOME 51 image for the\n'
        'Xiaomi Pad 6 Pro (liuqin, SM8475). Read README.md, HARDWARE.md and INSTALL.md\n'
        'first.\n\n'
        '## For installation agents\n\n'
        '- Use only the release artifacts and the exact commands in INSTALL.md. Check\n'
        '  the artifact SHA256 before unpacking.\n'
        '- Prefer the single entry: `liuqin-install.py` on Linux, `install-liuqin.ps1`\n'
        '  on Windows. Run doctor, fetch, firmware, prepare and `--dry-run` before any\n'
        '  write; read `liuqin-install-report.json` instead of guessing from prose.\n'
        '- Verify the model is liuqin, the bootloader is unlocked and the layout is the\n'
        '  supported stock single-system layout before any write.\n'
        '- Never invent a device path, slot switch or partition change. Stop and ask\n'
        '  the user when the layout, capacity, model or checksum differs.\n'
        '- Require a fresh backup and a rehearsal (`--dry-run`) before\n'
        '  `--yes-write-device`. Stop if the tablet cannot reach the host bundle\n'
        '  server; that check runs before any partition change.\n'
        '- Do not operate graphical menus or change host networking or firewall\n'
        '  settings without the user\'s explicit permission.\n'
        '- Windows USB networking, real flashing, first boot and recovery are not yet\n'
        '  hardware-verified; say so instead of claiming success.\n'
        '- Report the exact command, artifact SHA256 and observed output; never claim a\n'
        '  device test that was not performed.\n\n'
        '## For contributors\n\n'
        '- Consult upstream sources before changing device support.\n'
        '- Keep hardware evidence specific to the exact artifact and kernel Build ID.\n'
        '- Do not flash, repartition, switch slots or erase data without explicit\n'
        '  authorization, backups and readback checks.\n'
        '- Preserve the SLPI disable safeguard.\n'
        '- Never publish device calibration, serials, persist data, fingerprint\n'
        '  templates or credentials; keep vendor firmware and prepared bundles private.\n'
        '- Do not modify read-only upstream clones.\n'
        '- Use scoped offline tests; document unverified behaviour as unverified.\n')
    for source in (PROJECT / 'packaging/release/public').glob('*.md.in'):
        shutil.copy2(source, out / source.name.removesuffix('.in'))
    licenses = out / 'LICENSES'
    licenses.mkdir()
    for repository, filename in (
        ('xiaomipad-6pro-mainline', 'MIT-liuqin-upstream.txt'),
        ('pipa-fedora-builder-43', 'MIT-pipa-builder.txt'),
    ):
        shutil.copy2(PROJECT / 'upstream' / repository / 'LICENSE', licenses / filename)
    shutil.copy2(PROJECT / 'upstream/xiaomipad-6pro-mainline/NOTICE', licenses / 'NOTICE-liuqin-upstream.txt')
    kernel_licenses = PROJECT / 'upstream/linux-sm8450-liuqin/LICENSES'
    for license_name in ('GPL-2.0', 'GPL-3.0', 'LGPL-2.1', 'MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause'):
        candidates = list(kernel_licenses.rglob(license_name))
        if candidates:
            shutil.copy2(candidates[0], licenses / (license_name + '.txt'))
    shutil.copy2('/opt/rust-1.99.1/share/doc/rust/licenses/GPL-3.0-or-later.txt',
                 licenses / 'GPL-3.0.txt')
    removed = clean_doc_links(out)
    notices = (out / 'NOTICE').read_text()
    notices += ('\nAdditional source notices\n-------------------------\n'
                'The original liuqin device-project and Asahi Linux builder copyright notices are retained in LICENSES/.\n'
                'GNOME-derived layouts/resources retain GPL licensing; the optional extension helpers do not relicense those resources.\n'
                'The 7.3.1 device adaptation also uses Seeker0472/liuqin-nixos at eadaad6e032dbc0c3fc96347d5cf5bc78715827c; original file notices apply.\n'
                'The release source archives provide corresponding upstream source, patches and build materials. See SOURCES.md.\n')
    (out / 'NOTICE').write_text(notices)
    # A source manifest describes this exact new tree, independently of the
    # private worktree's commit history and author identities.
    files = sorted(p for p in out.rglob('*') if p.is_file() and not p.is_symlink())
    (out / 'source-files.sha256').write_text(''.join(f'{sha(p)}  {p.relative_to(out)}\n' for p in files))
    report = {'format': 'liuqin-public-source-stage/1', 'source_roots': ROOTS,
              'copied_source_paths': copied, 'files': len(files) + 1,
              'removed_local_document_links': removed, 'git_history_copied': False,
              'private_roots_copied': False, 'output': str(out)}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(f'Prepared {len(files) + 1} public source files; original history and private roots excluded')


if __name__ == '__main__':
    main()
