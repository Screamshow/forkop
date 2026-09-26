#!/usr/bin/env python3
"""Build the GUI release catalog from verified immutable mirror archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import sys

VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-canary\.(\d+))?$")
PACKAGES = ("forkop", "luci-app-forkop", "luci-i18n-forkop-ru")


def build_catalog(root):
    releases = []
    for manifest in sorted(root.glob("**/release.json")):
        relative = manifest.relative_to(root).as_posix()
        if not (relative.startswith("releases/") or relative.startswith("canary/releases/")):
            continue
        try:
            release = json.loads(manifest.read_text())
            version = release["tag_name"]
            match = VERSION.fullmatch(version)
            if not match or manifest.parent.name != version:
                continue
            # Initial rollback support boundary; older versions need separate validation.
            if tuple(map(int, match.groups()[:3])) < (1, 14, 3):
                continue
            assets = []
            for ext in ("apk", "ipk"):
                group = []
                for package in PACKAGES:
                    name = f"{package}_{version}.{ext}"
                    metadata = next(a for a in release["assets"] if a["name"] == name)
                    path = manifest.parent / name
                    expected = metadata.get("sha256", "")
                    actual = hashlib.sha256(path.read_bytes()).hexdigest()
                    if actual != expected:
                        raise ValueError(f"Checksum mismatch: {path}")
                    group.append({"name": name, "sha256": actual,
                        "browser_download_url": "/forkop/updates/" + path.relative_to(root).as_posix()})
                assets.extend(group)
            releases.append({"tag_name": version, "channel": "canary" if match[4] else "stable",
                "html_url": "/forkop/updates/" + manifest.parent.relative_to(root).as_posix() + "/",
                "assets": assets})
        except (OSError, ValueError, KeyError, StopIteration, TypeError) as error:
            print(f"Skipping {manifest}: {error}", file=sys.stderr)
    def version_key(release):
        match = VERSION.fullmatch(release["tag_name"])
        return (*map(int, match.groups()[:3]), match[4] is None, int(match[4] or 0))
    releases.sort(key=version_key, reverse=True)
    return {"format": 1, "releases": releases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    catalog = build_catalog(args.root)
    if not catalog["releases"]:
        parser.error("No complete, verified releases; existing catalog was preserved")
    fd, temporary = tempfile.mkstemp(prefix=".releases-", suffix=".json", dir=args.root)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(catalog, output, indent=2)
            output.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, args.root / "releases.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Published {len(catalog['releases'])} verified releases")


if __name__ == "__main__":
    main()
