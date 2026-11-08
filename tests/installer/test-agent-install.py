#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for the agent-facing installation path.

Covers the single entry point (installer/liuqin-install.py), the portable
password/zstd preparation helpers, the Windows bootstrap and the Windows USB
network descriptor.  No network, no device, no real Fastboot: the release API
and the asset server are local HTTP servers in a temporary directory.
"""
import contextlib
import functools
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
from unittest.mock import patch
import urllib.request

PROJECT = Path(__file__).resolve().parents[2]
INSTALLER = PROJECT / 'installer'
failures = []


def check(name, condition, detail=''):
    if condition:
        print('PASS: ' + name)
    else:
        failures.append(name + (': ' + detail if detail else ''))
        print('FAIL: ' + name + (': ' + detail if detail else ''))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agent = load('liuqin_agent_install', INSTALLER / 'liuqin-install.py')
prepare = load('liuqin_prepare', PROJECT / 'tools/release/prepare-image.py')
install = load('liuqin_install', INSTALLER / 'install.py')


# --- portable password hashing -------------------------------------------
known = ('$6$saltstring$adDbXsJjcDlq2662QPgd.tkSOVmnG9Tt3oXl4HR60SusC3AGjirnDenVZp3'
         'DGwLwqy6iYKCzannhaX9DR72nN1')
check('portable SHA-512 crypt matches the openssl reference vector',
      prepare.sha512_crypt('password', 'saltstring') == known)
check('portable SHA-512 crypt handles a long password',
      prepare.sha512_crypt('x' * 200, 'saltsalt').startswith('$6$saltsalt$'))
check('password_hash always produces a SHA-512 crypt string',
      prepare.password_hash('correct horse battery staple').startswith('$6$'))
try:
    prepare.sha512_crypt('x', 'bad salt')
except ValueError:
    check('invalid password salt is refused', True)
else:
    check('invalid password salt is refused', False)

if os.name != 'nt':
    with tempfile.TemporaryDirectory() as directory:
        private = Path(directory) / 'pass'
        private.write_text('secret\n')
        private.chmod(0o600)
        check('a private password file is read without the trailing newline',
              prepare.read_password_file(private) == 'secret')
        private.chmod(0o644)
        try:
            prepare.read_password_file(private)
        except ValueError:
            check('a world-readable password file is refused', True)
        else:
            check('a world-readable password file is refused', False)
else:
    print('SKIP: POSIX password-file permission check (running on Windows)')


# --- zstd without a zstd binary ------------------------------------------
try:
    from compression import zstd  # Python 3.14+
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / 'firmware.zst'
        source.write_bytes(zstd.compress(b'firmware payload'))
        check('zstd decoding uses Python support when available',
              prepare.zstd_decode(source) == b'firmware payload')
except ImportError:
    print('SKIP: Python zstd module is not available')


# --- repository and path helpers -----------------------------------------
for value, expected in (
        ('https://github.com/psych2090707/liuqin-fedora', ('psych2090707', 'liuqin-fedora')),
        ('git@github.com:owner/name.git', ('owner', 'name')),
        ('owner/name/', ('owner', 'name'))):
    check('GitHub repository form: ' + value, agent.github_repo(value) == expected)
for name in ('../escape', '/absolute', 'ok/../../escape'):
    try:
        agent.safe_join('/tmp', name)
    except SystemExit:
        pass
    else:
        check('unsafe repository path is refused: ' + name, False)
        break
else:
    check('unsafe repository paths are refused', True)


# --- synthetic GitHub Release --------------------------------------------
class Quiet(http.server.BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass


def make_assets(directory, label):
    directory.mkdir()
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode='w') as archive:
        data = ('{"device": "liuqin", "label": "%s"}\n' % label).encode()
        member = tarfile.TarInfo('image.json')
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    blob = payload.getvalue()
    cut = len(blob) // 2
    for index, chunk in enumerate((blob[:cut], blob[cut:])):
        (directory / ('demo.tar.part-%02d' % index)).write_bytes(chunk)
    archive_sha = hashlib.sha256(blob).hexdigest()
    (directory / 'BASE.SHA256').write_text(archive_sha + '  demo.tar\n')
    return archive_sha


with tempfile.TemporaryDirectory(prefix='liuqin-agent-test-') as directory:
    work = Path(directory)
    assets = work / 'assets'
    archive_sha = make_assets(assets, 'alpha')
    # A second split set in the same release must not be treated as part of
    # the base image that BASE.SHA256 names.
    (assets / 'sources.tar.part-00').write_bytes(b'decoy source part')
    release_v1 = {'id': 1, 'tag_name': 'v0.1.0-alpha.1', 'prerelease': True,
                  'draft': False, 'published_at': '2026-11-07T00:00:00Z',
                  'assets': [
                      {'name': path.name, 'size': path.stat().st_size, 'digest': None,
                       'browser_download_url': 'http://127.0.0.1:PORT/assets/' + path.name}
                      for path in sorted(assets.iterdir())]}
    release_v2 = dict(release_v1, id=2, tag_name='v0.2.0', prerelease=False,
                      published_at='2026-11-08T00:00:00Z')
    releases = [release_v1]

    class ReleaseApi(Quiet):
        def do_GET(self):
            path = self.path.split('?', 1)[0]
            if path in ('/repos/owner/demo/releases', '/repos/owner/demo/releases/'):
                body = json.dumps(releases).encode()
            elif path.startswith('/repos/owner/demo/releases/tags/'):
                tag = path.rsplit('/', 1)[-1]
                found = next((item for item in releases if item['tag_name'] == tag), None)
                if found is None:
                    self.send_error(404)
                    return
                body = json.dumps(found).encode()
            elif path == '/repos/owner/demo/releases/latest':
                self.send_error(404)
                return
            elif path.startswith('/assets/'):
                target = assets / path.split('/', 2)[-1]
                data = target.read_bytes() if target.is_file() else None
                if data is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    api_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ReleaseApi)
    api_base = 'http://127.0.0.1:%d' % api_server.server_port
    for item in releases:
        for asset in item['assets']:
            asset['browser_download_url'] = asset['browser_download_url'].replace(
                '127.0.0.1:PORT', '127.0.0.1:%d' % api_server.server_port)
    threading.Thread(target=api_server.serve_forever, daemon=True).start()

    def fetch(out, tag=None, stable=False, api=api_base):
        return agent.command_fetch(type('Args', (), {
            'repo': 'owner/demo', 'tag': tag, 'stable': stable,
            'out': out, 'api': api})())

    out = work / 'out'
    result = fetch(out)
    check('fetch discovers a prerelease through /releases when /releases/latest is 404',
          result == 0 and (out / 'image/image.json').is_file() and
          (out / 'demo.tar').is_file() and
          hashlib.sha256((out / 'demo.tar').read_bytes()).hexdigest() == archive_sha)
    record = json.loads((out / 'release.json').read_text())
    check('fetch records the exact release identity',
          record['tag'] == 'v0.1.0-alpha.1' and record['id'] == 1 and record['complete'])
    check('fetch ignores split assets that BASE.SHA256 does not name',
          not (out / 'downloads/v0.1.0-alpha.1/sources.tar.part-00').exists())

    explicit = work / 'explicit'
    check('fetch accepts an explicit prerelease tag',
          fetch(explicit, tag='v0.1.0-alpha.1') == 0 and
          json.loads((explicit / 'release.json').read_text())['tag'] == 'v0.1.0-alpha.1')
    try:
        fetch(work / 'stable', stable=True)
    except SystemExit as error:
        check('fetch --stable refuses when only prereleases exist',
              error.code == agent.EXIT_ENVIRONMENT)
    else:
        check('fetch --stable refuses when only prereleases exist', False)

    (out / 'demo.tar').write_bytes(b'corrupted')
    (out / 'image').rename(out / 'image-old')
    check('fetch repairs a corrupted joined archive from the verified parts',
          fetch(out) == 0 and (out / 'image/image.json').is_file())

    # A same-size corrupted cached part must trigger a clean re-download, not
    # silently merge stale bytes.  The release identity stays the same.
    part = out / 'downloads/v0.1.0-alpha.1/demo.tar.part-00'
    original = part.read_bytes()
    part.write_bytes(bytes(len(original)))
    (out / 'demo.tar').unlink()
    (out / 'image').rename(out / 'image-old2')
    check('fetch re-downloads cached parts after a merged-archive mismatch',
          fetch(out) == 0 and
          hashlib.sha256((out / 'demo.tar').read_bytes()).hexdigest() == archive_sha)

    # --stable picks the newest non-prerelease when both are published.
    releases[:] = [release_v1, release_v2]
    stable_out = work / 'stable-ok'
    check('fetch --stable picks the newest stable release',
          fetch(stable_out, stable=True) == 0 and
          json.loads((stable_out / 'release.json').read_text())['tag'] == 'v0.2.0')

    # Another release in the same --out is refused before any download.
    releases[:] = [release_v2]
    try:
        fetch(out)
    except SystemExit as error:
        check('fetch refuses to mix two release versions in one --out',
              error.code == agent.EXIT_USAGE)
    else:
        check('fetch refuses to mix two release versions in one --out', False)

    # A checksum mismatch is a hard failure, not a successful cache reuse.
    bad = work / 'bad-checksum'
    (assets / 'BASE.SHA256').write_text('0' * 64 + '  demo.tar\n')
    try:
        fetch(bad, tag='v0.2.0')
    except SystemExit as error:
        check('fetch refuses a merged archive that does not match BASE.SHA256',
              error.code == agent.EXIT_VERIFY)
    else:
        check('fetch refuses a merged archive that does not match BASE.SHA256', False)
    api_server.shutdown()
    api_server.server_close()


# --- firmware restoration -------------------------------------------------
with tempfile.TemporaryDirectory(prefix='liuqin-firmware-test-') as directory:
    work = Path(directory)
    base = work / 'base'
    base.mkdir()
    firmware_bytes = b'vendor firmware payload'
    firmware_sha = hashlib.sha256(firmware_bytes).hexdigest()
    manifest = {
        'format': 'liuqin-public-base/1', 'device': 'liuqin',
        'firmware_source': {'repository': 'https://github.com/owner/name',
                            'commit': '0' * 40,
                            'subdirectory': 'device/firmware/usr/lib/firmware'},
        'rootfs_restore': [
            {'source': 'qca/board.bin', 'source_sha256': firmware_sha, 'decode': None}],
        'ramdisk_restore': {'boot.img': [
            {'source': 'qca/board.bin', 'source_sha256': firmware_sha, 'decode': None},
            {'source': 'qca/other.bin', 'source_sha256': firmware_sha, 'decode': None}]}}
    (base / 'image.json').write_text(json.dumps(manifest))
    upstream = work / 'upstream'
    for name in ('qca/board.bin', 'qca/other.bin'):
        target = upstream / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(firmware_bytes)
    out = work / 'firmware'
    result = agent.command_firmware(type('Args', (), {
        'base': base, 'out': out, 'upstream': upstream,
        'accept_firmware_terms': False})())
    check('firmware copies every unique pinned file from a local upstream copy',
          result == 0 and (out / 'qca/board.bin').read_bytes() == firmware_bytes and
          (out / 'qca/other.bin').is_file())
    (upstream / 'qca/other.bin').write_bytes(b'tampered')
    try:
        agent.command_firmware(type('Args', (), {
            'base': base, 'out': work / 'firmware-bad', 'upstream': upstream,
            'accept_firmware_terms': False})())
    except SystemExit as error:
        check('firmware refuses a local file that does not match the pinned hash',
              error.code == agent.EXIT_VERIFY)
    else:
        check('firmware refuses a local file that does not match the pinned hash', False)
    try:
        agent.command_firmware(type('Args', (), {
            'base': base, 'out': work / 'firmware-no-terms', 'upstream': None,
            'accept_firmware_terms': False})())
    except SystemExit as error:
        check('firmware requires an explicit licensing acknowledgement',
              error.code == agent.EXIT_USAGE)
    else:
        check('firmware requires an explicit licensing acknowledgement', False)


# --- install.py machine report and failure hint ---------------------------
with tempfile.TemporaryDirectory(prefix='liuqin-report-test-') as directory:
    work = Path(directory)
    bundle = work / 'bundle'
    bundle.mkdir()
    files = {}
    for name in ('boot.img', 'installer.img', 'rootfs.tar.gz'):
        (bundle / name).write_bytes(name.encode())
        files[name] = hashlib.sha256(name.encode()).hexdigest()
    (bundle / 'bundle.json').write_text(json.dumps({
        'device': 'liuqin', 'status': 'OFFLINE_ASSEMBLED',
        'kernel_release': '6.17.0-liuqin-test', 'files': files}))
    report = work / 'report.json'
    result = subprocess.run([sys.executable, str(INSTALLER / 'install.py'),
                             '--bundle', str(bundle), '--check',
                             '--report', str(report)], capture_output=True, text=True)
    data = json.loads(report.read_text()) if report.is_file() else {}
    check('--check writes a machine report with ok=true and a final stage',
          result.returncode == 0 and data.get('ok') is True and data.get('stage') == 'complete',
          result.stdout + result.stderr)
    check('--check prints stage lines for an agent',
          'STAGE check' in result.stdout and 'STAGE complete' in result.stdout, result.stdout)
    (bundle / 'boot.img').write_bytes(b'corrupted')
    result = subprocess.run([sys.executable, str(INSTALLER / 'install.py'),
                             '--bundle', str(bundle), '--check',
                             '--report', str(report)], capture_output=True, text=True)
    data = json.loads(report.read_text()) if report.is_file() else {}
    check('a failed check writes ok=false and an actionable hint',
          result.returncode != 0 and data.get('ok') is False and
          data.get('hint') and 'HINT:' in result.stderr,
          result.stderr + report.read_text() if report.is_file() else result.stderr)
    # restore for the bundle-server test
    (bundle / 'boot.img').write_bytes(b'boot.img')

    probe = work / 'probe.txt'
    probe.write_text('probe-token\n')
    server = http.server.ThreadingHTTPServer(
        ('127.0.0.1', 0), install.bundle_handler(bundle, {'/__liuqin_probe': probe}))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with urllib.request.urlopen('http://127.0.0.1:%d/__liuqin_probe' % server.server_port) as reply:
        answer = reply.read().decode()
    with urllib.request.urlopen('http://127.0.0.1:%d/boot.img' % server.server_port) as reply:
        boot = reply.read()
    server.shutdown()
    server.server_close()
    check('the installer serves the probe file and the bundle, nothing else',
          answer == 'probe-token\n' and boot == b'boot.img')


# --- doctor --json is pure JSON ------------------------------------------
with patch.object(agent, 'find_fastboot', return_value='fastboot'), \
        patch.object(agent, 'fastboot_facts', return_value={'ok': True, 'version': ['fake']}):
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            code = agent.command_doctor(type('Args', (), {
                'json': True, 'bundle': None, 'serial': None,
                'probe_device': False, 'fastboot': None})())
    finally:
        agent.JSON_OUTPUT = False
try:
    document = json.loads(buffer.getvalue())
except ValueError as error:
    check('doctor --json emits only a parseable JSON document', False, str(error))
else:
    check('doctor --json emits only a parseable JSON document',
          code == agent.EXIT_OK and document['format'] == 'liuqin-agent-doctor/1' and
          'STAGE' not in buffer.getvalue() and document['ok'] is True,
          buffer.getvalue())


# --- device-side Windows NCM descriptor ----------------------------------
init = (PROJECT / 'initramfs/init').read_text()
check('USB gadget advertises a composite IAD to Windows',
      'echo 0xEF >"$gadget/bDeviceClass"' in init and
      'echo 0x02 >"$gadget/bDeviceSubClass"' in init and
      'echo 0x01 >"$gadget/bDeviceProtocol"' in init)
check('USB NCM gadget publishes the Microsoft WINNCM compatible ID',
      'echo WINNCM >"$gadget/functions/$function_name/os_desc/interface.ncm/compatible_id"'
      in init and 'echo MSFT100 >"$gadget/os_desc/qw_sign"' in init)
check('the OS descriptor is linked to the active configuration',
      'ln -s "$gadget/configs/c.1" "$gadget/os_desc"' in init)

# --- Windows bootstrap ----------------------------------------------------
bootstrap = (INSTALLER / 'windows/install-liuqin.ps1').read_text()
check('the Windows bootstrap prepares Python, fastboot and zstd without WSL or admin rights',
      'embed-amd64.zip' in bootstrap and 'zstd-v$ZstdVersion-win64.zip' in bootstrap and
      'repository2-3.xml' in bootstrap and 'Get-FileHash' in bootstrap and
      '--scope user' in bootstrap and 'RunAsAdministrator' not in bootstrap and
      'wsl.exe' not in bootstrap.lower() and 'exit $LASTEXITCODE' in bootstrap)
check('the Windows bootstrap verifies archives by pinned hash, not ZIP Authenticode',
      'Get-AuthenticodeSignature' not in bootstrap and
      '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3' in bootstrap and
      'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9' in bootstrap)
check('the Windows bootstrap forwards every argument to the single entry point',
      'installer\\liuqin-install.py' in bootstrap and '@Arguments' in bootstrap)

if failures:
    sys.exit('agent install test failures:\n' + '\n'.join('  ' + item for item in failures))
print('PASS: agent-facing installation path (offline; no device, network or Fastboot write)')
