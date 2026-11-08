#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline tests for the agent-facing installation path.

Covers the single entry point (installer/liuqin-install.py), the portable
password/zstd preparation helpers, the Windows bootstrap and the Windows USB
network descriptor.  No network, no device, no real Fastboot: the release API
and the asset server are local HTTP servers in a temporary directory.
"""
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
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *arguments):
        pass


with tempfile.TemporaryDirectory(prefix='liuqin-agent-test-') as directory:
    work = Path(directory)
    assets = work / 'assets'
    assets.mkdir()
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode='w') as archive:
        data = b'{"device": "liuqin", "files": {}}\n'
        member = tarfile.TarInfo('image.json')
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    blob = payload.getvalue()
    cut = len(blob) // 2
    for index, chunk in enumerate((blob[:cut], blob[cut:])):
        (assets / ('demo.tar.part-%02d' % index)).write_bytes(chunk)
    archive_sha = hashlib.sha256(blob).hexdigest()
    (assets / 'BASE.SHA256').write_text(archive_sha + '  demo.tar\n')

    handler = functools.partial(Quiet, directory=str(assets))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    base = 'http://127.0.0.1:%d' % server.server_port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    release = {'assets': [
        {'name': path.name, 'size': path.stat().st_size, 'digest': None,
         'browser_download_url': base + '/' + path.name}
        for path in sorted(assets.iterdir())]}
    release_json = json.dumps(release).encode()

    class ReleaseApi(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(release_json)))
            self.end_headers()
            self.wfile.write(release_json)

        def log_message(self, *arguments):
            pass

    api_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ReleaseApi)
    api_base = 'http://127.0.0.1:%d' % api_server.server_port
    threading.Thread(target=api_server.serve_forever, daemon=True).start()
    out = work / 'out'
    result = agent.command_fetch(type('Args', (), {
        'repo': 'owner/demo', 'tag': None, 'out': out, 'api': api_base + '/'})())
    check('fetch joins and verifies the release parts and extracts the base',
          result == 0 and (out / 'image/image.json').is_file() and
          (out / 'demo.tar').is_file() and
          hashlib.sha256((out / 'demo.tar').read_bytes()).hexdigest() == archive_sha)
    (out / 'demo.tar').write_bytes(b'corrupted')
    (out / 'image').rename(out / 'image-old')
    result = agent.command_fetch(type('Args', (), {
        'repo': 'owner/demo', 'tag': None, 'out': out, 'api': api_base + '/'})())
    check('fetch repairs a corrupted joined archive from the verified parts',
          result == 0 and (out / 'image/image.json').is_file())
    server.shutdown()
    api_server.shutdown()
    server.server_close()
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
check('the Windows bootstrap prepares Python and platform-tools without WSL',
      'embed-amd64.zip' in bootstrap and
      'platform-tools-latest-windows.zip' in bootstrap and
      'wsl.exe' not in bootstrap.lower() and 'exit $LASTEXITCODE' in bootstrap)
check('the Windows bootstrap forwards every argument to the single entry point',
      'installer\\liuqin-install.py' in bootstrap and '@Arguments' in bootstrap)

if failures:
    sys.exit('agent install test failures:\n' + '\n'.join('  ' + item for item in failures))
print('PASS: agent-facing installation path (offline; no device, network or Fastboot write)')
