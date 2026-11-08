#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""One entry point for preparing and installing liuqin Fedora from any host.

The device-side work stays in ``install.py``; this program only coordinates
what a user or an agent must do around it:

    doctor     inspect the host, Fastboot, the bundle and (optionally) the tablet
    fetch      download a GitHub Release base image, verify and extract it
    firmware   fetch the pinned upstream firmware files the public base omits
    prepare    build the private install bundle (password + firmware)
    install    forward to install.py (--check, --dry-run or an authorised write)

Every command prints ``STAGE ...`` lines and can emit JSON with ``--json`` so
an agent can coordinate the run without scraping prose.  Nothing here writes
to the tablet except the forwarded ``install.py --yes-write-device`` call,
which keeps its own attended-write gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_ENVIRONMENT = 3
EXIT_VERIFY = 4


def say(message):
    print(message, flush=True)


def stage(name, detail=''):
    print('STAGE ' + name + ((': ' + detail) if detail else ''), flush=True)


def fail(message, code=EXIT_FAIL):
    print('ERROR: ' + message, file=sys.stderr, flush=True)
    raise SystemExit(code)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(arguments, **kwargs):
    return subprocess.run([str(item) for item in arguments], capture_output=True,
                          text=True, **kwargs)


def installer_script():
    for candidate in (HERE / 'install.py', HERE.parent / 'installer/install.py'):
        if candidate.is_file():
            return candidate
    fail('install.py is missing next to this program; use a complete release image',
         EXIT_ENVIRONMENT)


def prepare_script():
    for candidate in (HERE / 'prepare-image.py', HERE.parent / 'tools/release/prepare-image.py'):
        if candidate.is_file():
            return candidate
    fail('prepare-image.py is missing next to this program; use a complete release image',
         EXIT_ENVIRONMENT)


def find_fastboot(explicit=None):
    candidate = explicit or os.environ.get('FASTBOOT')
    if candidate:
        path = Path(candidate).expanduser()
        if path.is_file():
            return str(path)
        found = shutil.which(candidate)
        if found:
            return found
        return None
    return shutil.which('fastboot') or shutil.which('fastboot.exe')


def fastboot_facts(executable, serial=None):
    """Read-only Fastboot facts; never a mutating verb."""
    prefix = [executable] + (['-s', serial] if serial else [])
    version = run(prefix + ['--version'])
    facts = {'version': (version.stdout or version.stderr).splitlines()[:1],
             'ok': version.returncode == 0}
    if not serial:
        devices = run(prefix + ['devices'])
        facts['devices'] = [line.split()[0] for line in devices.stdout.splitlines()
                            if line.split()]
        return facts
    for name in ('product', 'unlocked', 'partition-size:userdata',
                 'partition-size:boot_a', 'partition-size:boot_b'):
        result = run(prefix + ['getvar', name])
        text = (result.stdout or '') + (result.stderr or '')
        match = re.search(re.escape(name) + r':\s*(\S+)', text)
        facts[name] = match[1] if match else None
    facts['ok'] = (version.returncode == 0 and facts.get('product') == 'liuqin'
                   and facts.get('unlocked') == 'yes')
    return facts


def bundle_check(bundle):
    script = installer_script()
    result = run([sys.executable, script, '--bundle', bundle, '--check'])
    return {'ok': result.returncode == 0,
            'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()}


def command_doctor(args):
    stage('doctor', 'host, Fastboot, bundle and device readiness')
    report = {'format': 'liuqin-agent-doctor/1',
              'platform': {'system': os.name, 'release': sys.platform,
                           'machine': os.environ.get('PROCESSOR_ARCHITECTURE', ''),
                           'python': sys.version.split()[0]},
              'ok': True, 'problems': []}
    fastboot = find_fastboot(args.fastboot)
    report['fastboot'] = {'path': fastboot}
    if not fastboot:
        report['fastboot']['error'] = 'fastboot was not found'
        report['problems'].append('fastboot missing: install Android platform-tools or pass --fastboot')
        report['ok'] = False
    elif args.serial or args.probe_device:
        report['fastboot'].update(fastboot_facts(fastboot, args.serial))
        if args.serial and not report['fastboot'].get('ok'):
            report['problems'].append(
                'device check failed: expected product=liuqin and unlocked=yes; '
                'check the cable, Fastboot mode and bootloader unlock state')
            report['ok'] = False
    else:
        report['fastboot'].update(fastboot_facts(fastboot))
    if args.bundle:
        report['bundle'] = {'path': str(Path(args.bundle).resolve())}
        report['bundle'].update(bundle_check(Path(args.bundle)))
        if not report['bundle']['ok']:
            report['problems'].append('bundle check failed: ' +
                                      (report['bundle']['stderr'] or report['bundle']['stdout']))
            report['ok'] = False
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        say('Host: ' + report['platform']['system'] + ' / ' + report['platform']['release'] +
            ' / Python ' + report['platform']['python'])
        say('Fastboot: ' + (fastboot or 'NOT FOUND'))
        if args.serial:
            for key in ('product', 'unlocked', 'partition-size:userdata'):
                say('  ' + key + ': ' + str(report['fastboot'].get(key)))
        if args.bundle:
            say('Bundle: ' + ('OK' if report['bundle']['ok'] else 'FAILED') +
                ' (' + report['bundle']['path'] + ')')
        say('Result: ' + ('ready for the dry-run' if report['ok'] else 'NOT READY'))
        for problem in report['problems']:
            say('  - ' + problem)
    return EXIT_OK if report['ok'] else EXIT_ENVIRONMENT


def github_repo(value):
    """Accept https://github.com/o/r, git@github.com:o/r.git or o/r."""
    text = value.strip()
    match = re.fullmatch(r'(?:https?://github\.com/|git@github\.com:)?([^/\s]+)/([^/\s]+?)(?:\.git)?/?',
                        text)
    if not match:
        fail('--repo must be a GitHub repository such as owner/name or '
             'https://github.com/owner/name', EXIT_USAGE)
    return match[1], match[2]


def github_json(url, token=None):
    request = urllib.request.Request(url, headers={
        'User-Agent': 'liuqin-install', 'Accept': 'application/vnd.github+json'})
    if token:
        request.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url, target, expected_sha256=None, size=None):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file():
        if (size is None or target.stat().st_size == size) and \
                (expected_sha256 is None or digest(target) == expected_sha256):
            say('Using verified cached file: ' + target.name)
            return
        target.unlink()
    temporary = target.with_name(target.name + '.part')
    say('Downloading ' + target.name + (' (%d bytes)' % size if size else '') + '...')
    request = urllib.request.Request(url, headers={'User-Agent': 'liuqin-install'})
    seen = 0
    with urllib.request.urlopen(request, timeout=120) as response, temporary.open('wb') as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)
            seen += len(chunk)
            if seen % (256 << 20) < (1 << 20):
                print('  ' + target.name + ': ' + str(seen >> 20) + ' MiB', file=sys.stderr,
                      flush=True)
    if expected_sha256 and digest(temporary) != expected_sha256:
        temporary.unlink(missing_ok=True)
        fail('downloaded file checksum mismatch: ' + target.name, EXIT_VERIFY)
    if size is not None and temporary.stat().st_size != size:
        temporary.unlink(missing_ok=True)
        fail('downloaded file has the wrong size: ' + target.name, EXIT_VERIFY)
    os.replace(temporary, target)


def safe_join(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ('..', '') for part in path.parts):
        fail('unsafe archive path: ' + name, EXIT_VERIFY)
    return Path(root).joinpath(*path.parts)


def extract_base(archive, destination):
    destination = Path(destination)
    if destination.is_dir() and any(destination.iterdir()):
        say('Base image already extracted: ' + str(destination))
        return
    destination.mkdir(parents=True, exist_ok=True)
    say('Extracting ' + archive.name + '...')
    with tarfile.open(archive, 'r:*') as source:
        for member in source.getmembers():
            safe_join(destination, member.name)
        if hasattr(tarfile, 'data_filter'):
            source.extractall(destination, filter='data')
        else:
            source.extractall(destination)


def command_fetch(args):
    owner, repo = github_repo(args.repo)
    token = os.environ.get('GITHUB_TOKEN')
    api = args.api.rstrip('/') + '/repos/' + owner + '/' + repo + '/releases/'
    stage('fetch-release', 'resolve ' + owner + '/' + repo + (('@' + args.tag) if args.tag else ''))
    try:
        release = github_json(api + ('tags/' + args.tag if args.tag else 'latest'), token)
    except urllib.error.HTTPError as error:
        fail('GitHub release lookup failed (' + str(error.code) + '); check --repo/--tag or '
             'set GITHUB_TOKEN for a private repository', EXIT_ENVIRONMENT)
    assets = release.get('assets', [])
    parts = {}
    checksums = None
    for asset in assets:
        name = asset['name']
        match = re.fullmatch(r'(.+\.tar)\.part-[0-9]+', name)
        if match:
            parts.setdefault(match[1], []).append(asset)
        elif name == 'BASE.SHA256':
            checksums = asset
    if not parts or checksums is None:
        fail('this release has no split base image (NAME.tar.part-* plus BASE.SHA256); '
             'download the release assets manually', EXIT_USAGE)
    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    downloads = out / 'downloads'
    total = sum(asset['size'] for group in parts.values() for asset in group)
    checksums_path = downloads / 'BASE.SHA256'
    download(checksums['browser_download_url'], checksums_path,
             (checksums.get('digest') or '').removeprefix('sha256:') or None,
             checksums['size'])
    wanted = {}
    for line in checksums_path.read_text().splitlines():
        fields = line.split()
        if len(fields) == 2:
            wanted[fields[1].lstrip('*')] = fields[0]
    for archive_name, group in parts.items():
        if archive_name not in wanted:
            continue
        stage('fetch-parts', archive_name)
        group.sort(key=lambda item: item['name'])
        ordered = []
        for asset in group:
            target = downloads / asset['name']
            expected = (asset.get('digest') or '').removeprefix('sha256:') or None
            download(asset['browser_download_url'], target, expected, asset['size'])
            ordered.append(target)
        archive = out / archive_name
        if not archive.is_file() or digest(archive) != wanted[archive_name]:
            say('Joining ' + str(len(ordered)) + ' parts into ' + archive.name + '...')
            with archive.open('wb') as sink:
                for part in ordered:
                    with part.open('rb') as source:
                        shutil.copyfileobj(source, sink, length=1 << 20)
        if digest(archive) != wanted[archive_name]:
            fail('joined archive does not match BASE.SHA256: ' + archive_name, EXIT_VERIFY)
        extract_base(archive, out / 'image')
        say('Verified base image: ' + str(out / 'image'))
        say('Downloaded size: ' + str(total) + ' bytes')
        return EXIT_OK
    fail('BASE.SHA256 names no archive matching the release parts', EXIT_VERIFY)


def firmware_sources(manifest):
    recipes = list(manifest.get('rootfs_restore', []))
    for records in manifest.get('ramdisk_restore', {}).values():
        recipes.extend(records)
    unique = {}
    for recipe in recipes:
        key = recipe['source']
        if key in unique and unique[key]['source_sha256'] != recipe['source_sha256']:
            fail('firmware source is pinned to two different hashes: ' + key, EXIT_VERIFY)
        unique[key] = recipe
    return unique


def command_firmware(args):
    base = Path(args.base).expanduser().resolve()
    manifest_path = base / 'image.json'
    if not manifest_path.is_file():
        fail('--base must be an extracted public base with image.json: ' + str(base), EXIT_USAGE)
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('device') != 'liuqin':
        fail('this is not a liuqin public base image', EXIT_VERIFY)
    source = manifest.get('firmware_source', {})
    owner, repo = github_repo(source.get('repository', ''))
    commit = source.get('commit')
    subdirectory = source.get('subdirectory')
    if not commit or not subdirectory:
        fail('image.json has no pinned firmware source; use a complete public base', EXIT_VERIFY)
    recipes = firmware_sources(manifest)
    stage('firmware', str(len(recipes)) + ' pinned files')
    if args.upstream:
        upstream = Path(args.upstream).expanduser().resolve()
        if (upstream / 'usr/lib/firmware').is_dir():
            upstream = upstream / 'usr/lib/firmware'
    elif args.accept_firmware_terms:
        upstream = None
    else:
        fail('firmware has vendor licensing terms. Read them and rerun with '
             '--accept-firmware-terms, or pass --upstream DIR with a copy you already have. '
             'This tool never uploads or redistributes the files.', EXIT_USAGE)
    out = Path(args.out).expanduser().resolve()
    raw = 'https://raw.githubusercontent.com/' + owner + '/' + repo + '/' + commit + '/' + \
        subdirectory.strip('/') + '/'
    failures = []
    for index, (name, recipe) in enumerate(sorted(recipes.items()), 1):
        target = safe_join(out, name)
        if target.is_file() and digest(target) == recipe['source_sha256']:
            continue
        stage('firmware-file', '%d/%d %s' % (index, len(recipes), name))
        if upstream is None:
            target.parent.mkdir(parents=True, exist_ok=True)
            download(raw + name, target, recipe['source_sha256'])
        else:
            candidate = safe_join(upstream, name)
            if not candidate.is_file() or digest(candidate) != recipe['source_sha256']:
                failures.append(name)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(candidate, target)
    if failures:
        fail('local firmware does not match the pinned hashes: ' + ', '.join(failures), EXIT_VERIFY)
    stage('firmware-complete', 'all required files verified')
    say('Firmware directory ready: ' + str(out))
    return EXIT_OK


def command_prepare(args):
    stage('prepare', 'build the private bundle; no device access')
    arguments = [sys.executable, prepare_script(), 'prepare',
                 '--base', str(Path(args.base).expanduser()),
                 '--firmware', str(Path(args.firmware).expanduser())]
    if args.check:
        arguments.append('--check')
    else:
        arguments += ['--out', str(Path(args.out).expanduser())]
        if args.password_file:
            arguments += ['--password-file', str(Path(args.password_file).expanduser())]
    result = subprocess.run(arguments)
    if result.returncode != 0:
        return result.returncode
    if not args.check:
        stage('prepare-complete', 'private bundle written; keep it local')
    return EXIT_OK


def command_install(args):
    """Forward every unknown flag to install.py unchanged.

    The write gate remains install.py's own ``--yes-write-device``; this
    wrapper never adds it.  ``--fastboot`` is resolved once here so both the
    doctor and the install use the same executable.
    """
    script = installer_script()
    if args.report is None:
        reports = Path.cwd() / 'liuqin-install-report.json'
        report = str(reports)
    else:
        report = args.report
    forwarded = list(args.forwarded)
    if args.fastboot:
        forwarded += ['--fastboot', args.fastboot]
    stage('install', 'forwarding to install.py')
    sys.stdout.flush()
    result = subprocess.run([sys.executable, str(script), *forwarded, '--report', report])
    if result.returncode == 0:
        say('Installer finished; machine-readable report: ' + report)
    return result.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)

    doctor = commands.add_parser('doctor', help='check host tools, bundle and device')
    doctor.add_argument('--bundle', type=Path)
    doctor.add_argument('--serial')
    doctor.add_argument('--fastboot')
    doctor.add_argument('--probe-device', action='store_true',
                        help='read device facts even without --serial')
    doctor.add_argument('--json', action='store_true')
    doctor.set_defaults(function=command_doctor)

    fetch = commands.add_parser('fetch', help='download and verify a GitHub release base')
    fetch.add_argument('--repo', required=True)
    fetch.add_argument('--tag')
    fetch.add_argument('--out', type=Path, required=True)
    fetch.add_argument('--api', default='https://api.github.com',
                       help=argparse.SUPPRESS)
    fetch.set_defaults(function=command_fetch)

    firmware = commands.add_parser('firmware', help='restore the pinned vendor firmware files')
    firmware.add_argument('--base', type=Path, required=True)
    firmware.add_argument('--out', type=Path, required=True)
    firmware.add_argument('--upstream', type=Path,
                          help='existing device/firmware/usr/lib/firmware copy')
    firmware.add_argument('--accept-firmware-terms', action='store_true',
                          help='confirm you may use the vendor firmware on your own tablet')
    firmware.set_defaults(function=command_firmware)

    prepare = commands.add_parser('prepare', help='build the private install bundle')
    prepare.add_argument('--base', type=Path, required=True)
    prepare.add_argument('--firmware', type=Path, required=True)
    prepare.add_argument('--out', type=Path)
    prepare.add_argument('--password-file', type=Path)
    prepare.add_argument('--check', action='store_true')
    prepare.set_defaults(function=command_prepare)

    install = commands.add_parser(
        'install', help='run install.py (check, dry-run or authorised write)',
        description='Every other option is passed to install.py unchanged: --bundle, --layout, '
                    '--serial, --backup, --erase-userdata, --allow-unverified, --check, '
                    '--dry-run, --yes-write-device, --host-address, --http-port, --extra-root. '
                    'This wrapper never adds --yes-write-device.')
    install.add_argument('--fastboot')
    install.add_argument('--report')
    install.set_defaults(function=command_install)

    args, forwarded = parser.parse_known_args(argv)
    if args.command == 'install':
        args.forwarded = forwarded
    elif forwarded:
        parser.error('unexpected arguments for ' + args.command + ': ' + ' '.join(forwarded))
    if getattr(args, 'out', None) is None and args.command == 'prepare' and not args.check:
        parser.error('prepare needs --out unless --check is used')
    return args.function(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(EXIT_FAIL)
