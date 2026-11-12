#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Retry a fixed, reviewed GitHub draft release without replacing verified assets.

Uses the official gh CLI and its existing login. No tokens are stored here.
Network failures retry indefinitely with bounded backoff. Integrity/identity
mismatches stop with exit 2. Publish is opt-in and requires every remote digest.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import quote


class Retryable(Exception):
    pass


class IntegrityError(Exception):
    pass


def gh(arguments, timeout=120, runner=subprocess.run):
    try:
        result = runner(['gh', *arguments], capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as error:
        raise Retryable(str(error)) from error
    if result.returncode:
        raise Retryable(result.stderr.strip()[-1500:])
    return result.stdout


def validate_release(release, tag, commit, manifest):
    if release.get('tag_name') != tag or release.get('target_commitish') != commit:
        raise IntegrityError('Release tag or source commit changed; refusing to upload/publish')
    if not release.get('prerelease'):
        raise IntegrityError('Expected an experimental prerelease')
    seen = set()
    verified, pending = [], []
    for asset in release.get('assets', []):
        name = asset['name']
        if name in seen or name not in manifest:
            raise IntegrityError('Duplicate or unexpected remote asset: ' + name)
        seen.add(name)
        expected = manifest[name]
        if asset.get('state') == 'uploaded':
            if asset.get('size') != expected['bytes'] or asset.get('digest') != 'sha256:' + expected['sha256']:
                raise IntegrityError('Uploaded asset has unexpected size/digest: ' + name)
            verified.append(name)
        else:
            pending.append(asset)
    return verified, pending


def local_integrity(directory, manifest):
    for name, expected in manifest.items():
        if Path(name).name != name or name in ('', '.', '..'):
            raise IntegrityError('Unsafe manifest asset name')
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != expected['bytes']:
            raise IntegrityError('Local asset missing, unsafe or changed: ' + name)
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected['sha256']:
                raise IntegrityError('Local asset checksum changed: ' + name)


def predecessor_running(pid):
    if not pid:
        return False
    try:
        args = Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0')
        return bool(args and Path(os.fsdecode(args[0])).name == 'gh' and
                    args[1:3] == [b'release', b'upload'])
    except (FileNotFoundError, PermissionError):
        return False


class Uploader:
    def __init__(self, args, call=gh, sleep=time.sleep):
        self.args, self.call, self.sleep = args, call, sleep
        self.manifest = json.loads(args.manifest.read_text())
        self.endpoint = 'repos/' + args.repo + '/releases/' + str(args.release_id)
        self.failures = 0
        self.attempts = {}

    def save(self, status, **fields):
        record = {'status': status, 'updated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  'repo': self.args.repo, 'tag': self.args.tag,
                  'source_commit': self.args.commit, 'attempts': self.attempts, **fields}
        temporary = self.args.status.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(record, indent=2) + '\n')
        temporary.replace(self.args.status)
        print(json.dumps(record), flush=True)

    def release(self):
        return json.loads(self.call(['api', self.endpoint]))

    def ensure_tag(self):
        endpoint = 'repos/' + self.args.repo + '/git/ref/tags/' + quote(self.args.tag, safe='')
        try:
            ref = json.loads(self.call(['api', endpoint]))
        except Retryable as error:
            if 'HTTP 404' not in str(error):
                raise
            self.call(['api', '--method', 'POST', 'repos/' + self.args.repo + '/git/refs',
                       '-f', 'ref=refs/tags/' + self.args.tag, '-f', 'sha=' + self.args.commit])
            ref = json.loads(self.call(['api', endpoint]))
        if ref.get('object', {}).get('sha') != self.args.commit:
            raise IntegrityError('Tag does not point to the reviewed release commit')

    def run(self):
        local_integrity(self.args.assets, self.manifest)
        while True:
            try:
                release = self.release()
                verified, incomplete = validate_release(release, self.args.tag, self.args.commit, self.manifest)
                missing = [name for name in self.manifest if name not in verified]
                fields = {'verified': verified, 'verified_count': len(verified),
                          'total_count': len(self.manifest),
                          'verified_bytes': sum(self.manifest[n]['bytes'] for n in verified),
                          'total_bytes': sum(v['bytes'] for v in self.manifest.values())}
                if not release['draft']:
                    if missing:
                        raise IntegrityError('Release was published before all expected assets were verified')
                    self.ensure_tag()
                    self.save('published', url=release['html_url'], **fields)
                    return 0
                if predecessor_running(self.args.wait_pid):
                    self.save('watching_existing_upload', **fields)
                    self.sleep(self.args.interval)
                    continue
                if missing:
                    # An incomplete asset left by a failed HTTP request can
                    # block the same name. Only remove it after the old uploader
                    # has exited, and never remove a verified complete asset.
                    for asset in incomplete:
                        self.call(['api', '--method', 'DELETE', 'repos/' + self.args.repo +
                                   '/releases/assets/' + str(asset['id'])])
                    # Prefer completing the actual new image before unchanged
                    # corresponding-source files. Work one file at a time.
                    missing.sort(key=lambda n: (0 if '-base.tar.part-' in n else 1,
                                                self.manifest[n]['bytes'], n))
                    name = missing[0]
                    self.attempts[name] = self.attempts.get(name, 0) + 1
                    self.save('uploading', current_asset=name, **fields)
                    self.call(['release', 'upload', self.args.tag,
                               str(self.args.assets / name), '--repo', self.args.repo], timeout=None)
                    self.failures = 0
                    continue
                self.save('verified_all_assets', **fields)
                if not self.args.publish:
                    return 0
                self.ensure_tag()
                # Recheck immediately before making the draft public.
                fresh = self.release()
                complete, pending = validate_release(fresh, self.args.tag, self.args.commit, self.manifest)
                if pending or len(complete) != len(self.manifest):
                    raise IntegrityError('Remote assets changed before publication')
                self.call(['release', 'edit', self.args.tag, '--repo', self.args.repo,
                           '--draft=false', '--prerelease', '--target', self.args.commit])
            except Retryable as error:
                self.failures += 1
                delay = min(300, self.args.interval * (2 ** min(self.failures - 1, 4)))
                self.save('retry_wait', error=str(error), retry_in_seconds=delay)
                self.sleep(delay)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--release-id', required=True, type=int)
    parser.add_argument('--assets', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--status', required=True, type=Path)
    parser.add_argument('--wait-pid', type=int)
    parser.add_argument('--interval', type=int, default=30)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    args.assets = args.assets.resolve()
    args.status.parent.mkdir(parents=True, exist_ok=True)
    with args.status.with_suffix('.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Another supervisor already holds this status lock', file=sys.stderr)
            return 2
        worker = Uploader(args)
        try:
            return worker.run()
        except IntegrityError as error:
            worker.save('blocked_integrity', error=str(error))
            return 2


if __name__ == '__main__':
    raise SystemExit(main())
