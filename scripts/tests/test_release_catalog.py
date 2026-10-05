import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('catalog', Path(__file__).parents[1] / 'write-release-catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CatalogTests(unittest.TestCase):
    def release(self, root, version):
        folder = root / ('canary/releases' if '-canary.' in version else 'releases') / version
        folder.mkdir(parents=True)
        assets = []
        for ext in ('apk', 'ipk'):
            for package in catalog.PACKAGES:
                name = f'{package}_{version}.{ext}'
                (folder / name).write_bytes(name.encode())
                assets.append({'name': name, 'sha256': hashlib.sha256(name.encode()).hexdigest()})
        (folder / 'release.json').write_text(json.dumps({'tag_name': version, 'assets': assets}))
        return folder

    def test_integrity_order_and_older_releases(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.release(root, '1.14.7-canary.2')
            self.release(root, '1.14.7-canary.10')
            self.release(root, '1.14.7')
            self.release(root, '1.3.19')
            broken = self.release(root, '1.14.6')
            (broken / 'forkop_1.14.6.apk').write_bytes(b'corrupted')
            releases = catalog.build_catalog(root)['releases']
            self.assertEqual([r['tag_name'] for r in releases], ['1.14.7', '1.14.7-canary.10', '1.14.7-canary.2', '1.3.19'])
            self.assertEqual(len(releases[0]['assets']), 6)
            self.assertEqual(releases[1]['assets'][0]['browser_download_url'], '/forkop/updates/canary/releases/1.14.7-canary.10/forkop_1.14.7-canary.10.apk')

    def test_missing_translation_excludes_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            folder = self.release(root, '1.14.6')
            (folder / 'luci-i18n-forkop-ru_1.14.6.ipk').unlink()
            self.assertEqual(catalog.build_catalog(root)['releases'], [])

    def test_original_apk_only_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            folder = self.release(root, '1.1.2')
            manifest = json.loads((folder / 'release.json').read_text())
            manifest['assets'] = [a for a in manifest['assets'] if a['name'].endswith('.apk')]
            (folder / 'release.json').write_text(json.dumps(manifest))
            releases = catalog.build_catalog(root)['releases']
            self.assertEqual(len(releases), 1)
            self.assertEqual(len(releases[0]['assets']), 3)


if __name__ == '__main__':
    unittest.main()
