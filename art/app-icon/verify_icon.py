#!/usr/bin/env python3
"""Verify the native vector source and every opaque RGB app-icon export."""
import hashlib,json,struct
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    meta=json.loads((ROOT/'art/app-icon/provenance.json').read_text())
    assert meta['schemaVersion']==2 and meta['method']=='native-vector' and meta['license']=='MIT'
    for name, checksum in meta['sourceFiles'].items():
        assert digest(ROOT/name)==checksum, 'Vector source changed; regenerate the icon catalog.'
    catalog=ROOT/'Sources/Spriglet/Assets.xcassets/AppIcon.appiconset'
    slots=json.loads((catalog/'Contents.json').read_text())['images']
    expected={(f'{size}x{size}',f'{scale}x') for size in (16,32,128,256,512) for scale in (1,2)}
    assert {(v['size'],v['scale']) for v in slots}==expected and len(slots)==10
    assert set(meta['catalogImages'])=={p.name for p in catalog.glob('*.png')}
    for slot in slots:
        path=catalog/slot['filename']; header=path.read_bytes()[:26]
        pixels=int(slot['size'].split('x')[0])*int(slot['scale'][:-1])
        assert slot['idiom']=='mac' and path.parent==catalog
        assert header[:8]==b'\x89PNG\r\n\x1a\n' and header[12:16]==b'IHDR'
        assert struct.unpack('>IIBB',header[16:26])==(pixels,pixels,8,2), 'Expected opaque 8-bit RGB icon.'
        assert digest(path)==meta['catalogImages'][path.name], 'Icon bytes differ from their vector export.'
    assert digest(ROOT/'art/app-icon/spriglet-app-icon-1024.png')==meta['catalogImages']['icon_512x512@2x.png']
    print('Icon source and all ten opaque RGB exports verified. Xcode validates the catalog during app builds.')
if __name__=='__main__':main()
