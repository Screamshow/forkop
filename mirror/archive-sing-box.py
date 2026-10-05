#!/usr/bin/env python3
"""Retain sing-box IPK/APK archives independently of rolling feed indexes."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.request import Request, urlopen

NAMES = ('sing-box', 'sing-box-tiny')
VERSION = r'[0-9][A-Za-z0-9.+~-]*'


def fetch(url):
    with urlopen(Request(url, headers={'User-Agent': 'Forkop-sing-box-archive'}), timeout=60) as response:
        return response.read()


def refresh_feeds(source, upstream, arches):
    """Fetch only sing-box; retain every downloaded version in this input tree."""
    listing = fetch(upstream + '/releases/').decode()
    releases = re.findall(r'href="(24\.10\.\d+)/"', listing)
    series = sorted(set(re.findall(r'href="(2[5-9]\.\d+)\.\d+/"', listing)))
    if not releases or not series:
        raise ValueError('OpenWrt release discovery returned incomplete results')
    latest_ipk = max(releases, key=lambda v: tuple(map(int, v.split('.'))))
    for arch in arches:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', arch):
            raise ValueError(f'Invalid architecture: {arch}')
        feeds = [(latest_ipk + '/packages', 'ipk')] + [('packages-' + s, 'apk') for s in series]
        for root, fmt in feeds:
            relative = f'releases/{root}/{arch}/packages'
            base = upstream + '/' + relative + '/'
            hashes = {}
            if fmt == 'ipk':
                index = gzip.decompress(fetch(base + 'Packages.gz')).decode()
                for block in index.split('\n\n'):
                    fields = dict(line.split(': ', 1) for line in block.splitlines() if ': ' in line)
                    if fields.get('Package') in NAMES:
                        hashes[fields['Filename']] = fields['SHA256sum']
            else:
                html = fetch(base).decode()
                for name in re.findall(r'href="([^"/]+\.apk)"', html):
                    if any(re.fullmatch(rf'{p}-{VERSION}\.apk', name) for p in NAMES):
                        hashes[name] = None
            if len(hashes) < 2:
                raise ValueError(f'Missing sing-box variants in {base}')
            for name, expected in hashes.items():
                if Path(name).name != name:
                    raise ValueError(f'Invalid package filename: {name}')
                path = source / relative / name
                identify(path, source)
                if path.exists():
                    if expected and hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                        raise ValueError(f'Changed upstream package: {path}')
                    continue
                data = fetch(base + name)
                if expected and hashlib.sha256(data).hexdigest() != expected:
                    raise ValueError(f'Upstream hash mismatch: {name}')
                path.parent.mkdir(parents=True, exist_ok=True)
                temporary = path.with_suffix(path.suffix + '.new')
                temporary.write_bytes(data)
                temporary.replace(path)
                print('Fetched', relative + '/' + name, flush=True)


def identify(path, root):
    arch = path.parent.parent.name
    for name in NAMES:
        pattern = (rf'{name}_({VERSION})_{re.escape(arch)}\.ipk' if path.suffix == '.ipk'
                   else rf'{name}-({VERSION})\.apk')
        match = re.fullmatch(pattern, path.name)
        if match:
            return dict(package=name, version=match[1], arch=arch,
                        format=path.suffix[1:])
    raise ValueError(f'Unrecognized package path: {path.relative_to(root)}')


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
        json.dump(data, out, indent=2)
        out.write('\n')
        temporary = Path(out.name)
    os.chmod(temporary, 0o644)
    temporary.replace(path)


def archive(source, destination, extra_source=None):
    destination.mkdir(parents=True, exist_ok=True)
    # Lock covers catalog read, blob publication and catalog replacement.
    with (destination / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        catalog_path = destination / 'packages.json'
        catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {'schema': 1, 'packages': []}
        entries = {}
        for row in catalog['packages']:
            key = tuple(row[k] for k in ('package', 'version', 'arch', 'format', 'sha256'))
            entries[key] = row
            blob = destination / 'blobs' / row['sha256'] / row['filename']
            if hashlib.sha256(blob.read_bytes()).hexdigest() != row['sha256']:
                raise ValueError(f'Corrupt existing archive: {blob}')
        sources = [source] + ([extra_source] if extra_source else [])
        for source_root, path in sorted((s, p) for s in sources for p in s.glob('releases/**/sing-box*')):
            if path.suffix not in ('.ipk', '.apk') or not path.is_file():
                continue
            row = identify(path, source_root)
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            row['sha256'] = digest
            key = tuple(row[k] for k in ('package', 'version', 'arch', 'format', 'sha256'))
            if key in entries:
                continue
            blob = destination / 'blobs' / digest / path.name
            blob.parent.mkdir(parents=True, exist_ok=True)
            temporary = blob.with_suffix(blob.suffix + '.new')
            shutil.copyfile(path, temporary)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                raise ValueError(f'Package changed during copy: {path}')
            temporary.replace(blob)
            row.update(filename=path.name, sha256=digest,
                       url=f'/forkop/sing-box-archive/blobs/{digest}/{path.name}',
                       source='/openwrt/' + path.relative_to(source_root).as_posix())
            entries[key] = row
        catalog['packages'] = [entries[key] for key in sorted(entries)]
        atomic_json(catalog_path, catalog)
        print(f"Retained {len(entries)} immutable sing-box package archives")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('/srv/mirror/public/openwrt'))
    parser.add_argument('--destination', type=Path, default=Path('/srv/mirror/public/forkop/sing-box-archive'))
    parser.add_argument('--refresh', action='store_true', help='Fetch current official feeds before archiving')
    parser.add_argument('--upstream', default='https://downloads.openwrt.org')
    parser.add_argument('--arches', nargs='+', default=['aarch64_cortex-a53', 'x86_64'])
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    with (args.destination / '.sync.lock').open('a') as sync_lock:
        fcntl.flock(sync_lock, fcntl.LOCK_EX)
        feed_source = args.destination / '.feeds'
        if args.refresh:
            refresh_feeds(feed_source, args.upstream.rstrip('/'), args.arches)
        archive(args.source, args.destination, feed_source)
