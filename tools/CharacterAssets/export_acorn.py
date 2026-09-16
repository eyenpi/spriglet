#!/usr/bin/env python3
"""Package the approved Acorn Hopper renders at their native 96-point size.

The review source remains untouched. Only point coordinates change; all PNG
bytes, frame timing, pixel anchors and Blender action boundaries are preserved.
Use --check for read-only CI/release verification.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import package_acorn

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'art/candidates/transitions-v03/acorn-hopper/runtime'
DESTINATION = ROOT / 'Sources/Spriglet/Resources/AcornHopper'
STANDARD_POINTS = 96


def packaged_manifest(source):
    result = json.loads(json.dumps(source))
    assert source['schemaVersion'] == 2
    assert source['displaySizePoints'] == {'width': 224, 'height': 224}
    factor = STANDARD_POINTS / source['displaySizePoints']['width']
    result['displaySizePoints'] = {'width': STANDARD_POINTS, 'height': STANDARD_POINTS}
    for clip in result['clips'].values():
        for frame in clip['frames']:
            frame['rootOffsetPoints'] = {key: value * factor for key, value in frame['rootOffsetPoints'].items()}
    return result


def verify(destination=DESTINATION):
    source = json.loads((SOURCE / 'manifest.json').read_text())
    expected = packaged_manifest(source)
    actual = json.loads((destination / 'manifest.json').read_text())
    assert actual == expected, 'Packaged Acorn metadata differs from the approved export'
    files = {source['restFrame'], source['sleepFrame']}
    files.update(frame['file'] for clip in source['clips'].values() for frame in clip['frames'])
    additions = package_acorn.verify(destination)
    assert {str(path.relative_to(destination)) for path in destination.rglob('*') if path.is_file()} == files | {'manifest.json'} | additions
    for name in files:
        assert hashlib.sha256((SOURCE / name).read_bytes()).digest() == hashlib.sha256((destination / name).read_bytes()).digest(), name
    return len(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        manifest = packaged_manifest(json.loads((SOURCE / 'manifest.json').read_text()))
        files = {manifest['restFrame'], manifest['sleepFrame']}
        files.update(frame['file'] for clip in manifest['clips'].values() for frame in clip['frames'])
        for name in sorted(files):
            target = DESTINATION / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, target)
        (DESTINATION / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        package, additions = package_acorn.expected(manifest)
        for name, source in additions.items():
            target = DESTINATION / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        (DESTINATION / package_acorn.PACKAGE_NAME).write_text(json.dumps(package, indent=2) + '\n')
    print(f'Acorn Hopper: {verify()} exact Blender PNGs; {STANDARD_POINTS}-point standard canvas verified.')


if __name__ == '__main__':
    main()
