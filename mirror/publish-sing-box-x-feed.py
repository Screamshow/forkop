#!/usr/bin/env python3
"""Publish stable sing-box X in the existing signed Forkop APK feed."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/srv/mirror/public/forkop'))
    parser.add_argument('--apk', default='/root/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin/apk')
    parser.add_argument('--key', default='/srv/mirror/keys/forkop-apk.pem')
    args = parser.parse_args()
    root = args.root
    with (root / 'mirror/.sing-box-x-feed.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stable = (root / 'MIRROR_LATEST').read_text().strip()
        if not re.fullmatch(r'\d+\.\d+\.\d+', stable):
            raise ValueError('Invalid stable Forkop version')
        catalog_bytes = (root / 'sing-box-x/latest.json').read_bytes()
        catalog = json.loads(catalog_bytes)
        if catalog['name'] != 'sing-box-x' or catalog.get('prerelease') or catalog['status'] != 'stable':
            raise ValueError('Expected stable sing-box X catalog')
        tag = catalog['release_tag']
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-r[1-9]\d*)?', tag):
            raise ValueError('Invalid X release tag')
        sources = list((root / 'mirror/releases' / stable).glob('*.apk'))
        if len(sources) != 3:
            raise ValueError('Expected three stable Forkop APKs')
        packages = [a for a in catalog['assets'] if a.get('format') == 'apk']
        if len(packages) != 2 or {a['architecture'] for a in packages} != {'x86_64', 'aarch64_cortex-a53'}:
            raise ValueError('Expected both supported APK architectures')
        for asset in packages:
            name = asset['name']
            if Path(name).name != name or asset['package'] != 'sing-box-x':
                raise ValueError('Invalid package identity')
            source = root / 'sing-box-x/releases' / tag / name
            data = source.read_bytes()
            if len(data) != asset['size'] or hashlib.sha256(data).hexdigest() != asset['sha256']:
                raise ValueError('X archive does not match catalog')
            subprocess.run([args.apk, '--keys-dir', str(root), 'verify', str(source)], check=True)
            sources.append(source)
        identity = hashlib.sha256(catalog_bytes + b''.join(p.read_bytes() for p in sources)).hexdigest()[:16]
        feeds = root / 'mirror/feeds'
        feeds.mkdir(exist_ok=True)
        destination = feeds / f'{stable}-x-{tag}-{identity}-arch'
        if not destination.exists():
            staging = Path(tempfile.mkdtemp(prefix='.feed-', dir=feeds))
            try:
                for arch in ('x86_64', 'aarch64_cortex-a53'):
                    (staging / arch).mkdir()
                for source in sources:
                    dump = subprocess.check_output([args.apk, 'adbdump', '--allow-untrusted', str(source)], text=True)
                    values = {}
                    for field in ('name', 'version', 'arch'):
                        match = re.search(r'^\s*' + field + r': ([\w.+-]+)$', dump, re.M)
                        if not match:
                            raise ValueError(f'Missing {field}: {source.name}')
                        values[field] = match.group(1)
                    directories = [staging] if values['arch'] == 'noarch' else []
                    directories += [staging / arch for arch in ('x86_64', 'aarch64_cortex-a53')
                                    if values['arch'] in ('noarch', arch)]
                    for directory in directories:
                        target = directory / '{name}-{version}.apk'.format(**values)
                        if target.exists():
                            raise ValueError('Duplicate package')
                        shutil.copyfile(source, target)
                for directory in [staging, staging / 'x86_64', staging / 'aarch64_cortex-a53']:
                    subprocess.run([args.apk, 'mkndx', '--allow-untrusted', '--sign-key', args.key,
                                '--pkgname-spec', '${name}-${version}.apk',
                                '--description', 'Forkop and sing-box X stable packages',
                                '--output', str(directory / 'packages.adb'),
                                *map(str, sorted(directory.glob('*.apk')))], check=True)
                    subprocess.run([args.apk, '--keys-dir', str(root), 'verify', str(directory / 'packages.adb')], check=True)
                (staging / 'SHA256SUMS').write_text(''.join(
                    hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p.relative_to(staging)) + '\n'
                    for p in sorted(staging.rglob('*')) if p.is_file()))
                staging.chmod(0o755)
                staging.rename(destination)
            except BaseException:
                shutil.rmtree(staging)
                raise
        current = root / 'mirror/current'
        if current.resolve() != destination.resolve():
            temporary = root / 'mirror/.current-x'
            temporary.unlink(missing_ok=True)
            temporary.symlink_to('feeds/' + destination.name)
            os.replace(temporary, current)
        print(f'Published Forkop {stable} and sing-box X {tag}: {current}')


if __name__ == '__main__':
    main()
