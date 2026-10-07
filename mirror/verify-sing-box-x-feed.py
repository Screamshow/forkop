#!/usr/bin/env python3
"""Check public APK feed architecture selection, signatures and downloads."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request

APK = '/root/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin/apk'
BASE = 'https://mirror.51343.ru/forkop'
catalog = json.load(urllib.request.urlopen(BASE + '/sing-box-x/latest.json'))
for arch in ('x86_64', 'aarch64_cortex-a53'):
    with tempfile.TemporaryDirectory(prefix='verify-x-feed-') as temporary:
        root = Path(temporary)
        (root / 'lib/apk/db').mkdir(parents=True)
        (root / 'lib/apk/db/installed').touch()
        (root / 'etc/apk').mkdir(parents=True)
        (root / 'etc/apk/world').touch()
        command = [APK, '--root', str(root), '--arch', arch,
                   '--keys-dir', '/srv/mirror/public/forkop',
                   '--repositories-file', '/dev/null', '--repository', BASE + '/mirror/current/' + arch + '/packages.adb']
        subprocess.run(command + ['update'], check=True)
        result = subprocess.check_output(command + ['query', '--from', 'repositories',
                  '--available', '--format', 'json', '--fields', 'name,version,arch', 'sing-box-x'], text=True)
        print(arch, result.strip())
        assert 'sing-box-x' in result and arch in result
        subprocess.run(command + ['fetch', '--output', str(root), 'sing-box-x'], check=True)
        package, = root.glob('*.apk')
        asset, = [a for a in catalog['assets'] if a.get('format') == 'apk' and a['architecture'] == arch]
        assert hashlib.sha256(package.read_bytes()).hexdigest() == asset['sha256']
        subprocess.run([APK, '--keys-dir', '/srv/mirror/public/forkop', 'verify', str(package)], check=True)
        print(arch, 'public search, fetch, SHA-256 and signature passed')
