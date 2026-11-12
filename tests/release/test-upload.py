#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise failed upload recovery and publication gates without network access."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('upload', PROJECT / 'tools/release/upload.py')
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class RecoveryTests(unittest.TestCase):
    def fixture(self, work):
        assets = work / 'assets'
        assets.mkdir()
        manifest = {}
        for name, payload in [('already-complete', b'keep this file'), ('new-base.tar.part-00', b'new image')]:
            (assets / name).write_bytes(payload)
            manifest[name] = {'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
        path = work / 'manifest.json'
        path.write_text(json.dumps(manifest))
        args = SimpleNamespace(repo='owner/repo', tag='v2', commit='a' * 40, release_id=12,
                               assets=assets, manifest=path, status=work / 'status.json',
                               interval=0, wait_pid=None, publish=True)
        done = {'id': 100, 'name': 'already-complete', 'state': 'uploaded',
                'size': manifest['already-complete']['bytes'],
                'digest': 'sha256:' + manifest['already-complete']['sha256']}
        release = {'tag_name': args.tag, 'target_commitish': args.commit, 'prerelease': True,
                   'draft': True, 'assets': [done], 'html_url': 'https://example.invalid/release'}
        return args, manifest, release

    def test_network_error_and_partial_asset_preserve_completed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            args, manifest, release = self.fixture(Path(directory))
            calls = []
            attempts = 0
            reads = 0

            def fake(command, timeout=120):
                nonlocal attempts, reads
                calls.append(command)
                if command == ['api', 'repos/owner/repo/releases/12']:
                    reads += 1
                    if reads == 1:
                        raise upload.Retryable('temporary network outage')
                    return json.dumps(release)
                if command[:3] == ['release', 'upload', 'v2']:
                    attempts += 1
                    self.assertEqual(Path(command[3]).name, 'new-base.tar.part-00')
                    if attempts == 1:
                        release['assets'].append({'id': 101, 'name': 'new-base.tar.part-00',
                                                  'state': 'starter', 'size': 0})
                        raise upload.Retryable('connection reset halfway through the file')
                    value = manifest['new-base.tar.part-00']
                    release['assets'].append({'id': 102, 'name': 'new-base.tar.part-00',
                                              'state': 'uploaded', 'size': value['bytes'],
                                              'digest': 'sha256:' + value['sha256']})
                    return ''
                if command[:3] == ['api', '--method', 'DELETE']:
                    self.assertEqual(command[3], 'repos/owner/repo/releases/assets/101')
                    release['assets'] = [a for a in release['assets'] if a['id'] != 101]
                    return ''
                if command == ['api', 'repos/owner/repo/git/ref/tags/v2']:
                    return json.dumps({'object': {'sha': args.commit}})
                if command[:3] == ['release', 'edit', 'v2']:
                    self.assertEqual(len(release['assets']), 2)
                    release['draft'] = False
                    return ''
                self.fail('unexpected command: ' + repr(command))

            result = upload.Uploader(args, call=fake, sleep=lambda _: None).run()
            self.assertEqual(result, 0)
            self.assertEqual(attempts, 2)
            state = json.loads(args.status.read_text())
            self.assertEqual(state['status'], 'published')
            self.assertEqual(state['verified_count'], 2)
            self.assertEqual(release['assets'][0]['id'], 100)

    def test_remote_identity_or_digest_changes_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            args, manifest, release = self.fixture(Path(directory))
            for field, value in [('target_commitish', 'b' * 40), ('tag_name', 'different'),
                                 ('prerelease', False)]:
                broken = copy.deepcopy(release)
                broken[field] = value
                with self.assertRaises(upload.IntegrityError):
                    upload.validate_release(broken, args.tag, args.commit, manifest)
            release['assets'][0]['digest'] = 'sha256:' + '0' * 64
            with self.assertRaises(upload.IntegrityError):
                upload.validate_release(release, args.tag, args.commit, manifest)

    def test_local_corruption_stops_before_any_network_write(self):
        with tempfile.TemporaryDirectory() as directory:
            args, _, _ = self.fixture(Path(directory))
            (args.assets / 'new-base.tar.part-00').write_bytes(b'corrupt image')
            def forbidden(*_args, **_kwargs):
                self.fail('network must not be contacted for a corrupted local input')
            with self.assertRaises(upload.IntegrityError):
                upload.Uploader(args, call=forbidden).run()

    def test_wrong_tag_prevents_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            args, _, _ = self.fixture(Path(directory))
            worker = upload.Uploader(args, call=lambda *_args, **_kw: json.dumps({'object': {'sha': 'wrong'}}))
            with self.assertRaises(upload.IntegrityError):
                worker.ensure_tag()


if __name__ == '__main__':
    unittest.main()
