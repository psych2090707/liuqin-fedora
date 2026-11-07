#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Download exact official source RPMs for the image's GPL/LGPL packages.

Input is rpm -qa --qf '%{NAME}\\t%{SOURCERPM}\\t%{LICENSE}\\n'.
Locally modified components need separate corresponding source archives.
No packages are installed and no downloaded code is executed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import urllib.request
from urllib.parse import quote

LOCAL = {'fprintd-oem', 'hexagonrpc', 'iio-sensor-proxy', 'libssc',
         'libfprint-tod', 'libfprint-tod-devel', 'qsee-supplicant', 'kernel-liuqin'}


def source_url(filename):
    if '/' in filename or not filename.endswith('.src.rpm'):
        raise ValueError('unexpected source RPM name')
    name, version, release = filename[:-8].rsplit('-', 2)
    return 'https://kojipkgs.fedoraproject.org/packages/' + '/'.join(
        quote(p, safe='') for p in (name, version, release, 'src', filename))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(filename, out):
    url = source_url(filename)
    mirror = 'https://mirrors.ustc.edu.cn/fedora/'
    suffix = '/Everything/source/tree/Packages/' + filename[0].lower() + '/' + filename
    candidates = [mirror + 'releases/45' + suffix, mirror + 'updates/45' + suffix, url]
    path = out / filename
    downloaded_from = url
    if not path.exists():
        partial = path.with_suffix('.rpm.partial')
        errors = []
        for candidate in candidates:
            try:
                opener = (urllib.request.build_opener(urllib.request.ProxyHandler({}))
                          if candidate.startswith(mirror) else urllib.request.build_opener())
                with opener.open(candidate, timeout=60) as response, partial.open('wb') as target:
                    head = response.read(4)
                    if head != b'\xed\xab\xee\xdb':
                        raise ValueError('server did not return an RPM: ' + filename)
                    target.write(head)
                    while chunk := response.read(1024 * 1024):
                        target.write(chunk)
                partial.replace(path)
                downloaded_from = candidate
                break
            except Exception as error:
                partial.unlink(missing_ok=True)
                errors.append(str(error))
        else:
            raise ValueError('all source locations failed: ' + '; '.join(errors))
    with path.open('rb') as stream:
        if stream.read(4) != b'\xed\xab\xee\xdb':
            raise ValueError('cached source is not an RPM: ' + filename)
    return {'name': filename, 'url': url, 'download_url': downloaded_from,
            'sha256': sha(path), 'bytes': path.stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--jobs', type=int, default=6, choices=range(1, 9))
    args = parser.parse_args()
    sources = set()
    local = set()
    for line in args.packages.read_text().splitlines():
        name, source, license_ = line.split('\t')
        if name.startswith('liuqin-') or name in LOCAL:
            local.add(source)
        elif 'GPL' in license_:
            sources.add(source)
    args.out.mkdir(parents=True, exist_ok=True)
    results = []
    failures = []
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {executor.submit(fetch, filename, args.out): filename for filename in sorted(sources)}
        for future in as_completed(futures):
            try:
                results.append(future.result())
                if len(results) % 20 == 0:
                    print(f'Sources: {len(results)}/{len(sources)} downloaded', flush=True)
            except Exception as error:
                failures.append({'name': futures[future], 'error': str(error)})
                print('FAILED:', futures[future], str(error), flush=True)
    report = {'format': 'liuqin-fedora-sources/1', 'sources': sorted(results, key=lambda r: r['name']),
              'locally_modified_sources_required': sorted(local), 'failures': failures}
    (args.out / 'sources.json').write_text(json.dumps(report, indent=2) + '\n')
    (args.out / 'SHA256SUMS').write_text(''.join(f"{r['sha256']}  {r['name']}\n" for r in report['sources']))
    print(f"Source download complete: {len(results)} files, {sum(r['bytes'] for r in results)} bytes, {len(failures)} failures")
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
