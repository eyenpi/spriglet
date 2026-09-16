#!/usr/bin/env python3
"""Export a physically separated Acorn rest-rig prototype from its editable rig.

This does not alter the shipping package. Blender renders real geometry with
camera-ray isolation; other objects still participate in lighting. No source
beauty pixels are erased, painted over, or retained as a correction overlay.
Proof boards require Pillow; rendering and validation use only Python/Blender.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'art/candidates/transitions-v03/acorn-hopper'
DESTINATION = ROOT / 'art/candidates/rest-rig-v04/acorn-hopper'
sys.path.insert(0, str(ROOT / 'tools/CharacterSampleValidation'))
from png_validation import RGBAImage, read_rgba_png, endpoint_difference

SIZE = 448
GROUPS = {
    'shadow': ['Contact shadow'],
    'feet': ['Foot.L', 'Foot.R'],
    'body': ['Body · rounded acorn', 'Paw.L', 'Paw.R', 'Brow.L', 'Brow.R',
             'Nose', 'Nose philtrum', 'Smile.-1', 'Smile.1'],
    'cap': ['Cap · scalloped single shell', 'Cap · rolled lip', 'Stem'],
    'leaf': ['Off-center leaf', 'Off-center leaf · midrib'],
    'eye.left': ['Eye.L'],
    'eye.right': ['Eye.R'],
}
ORDER = ['shadow', 'feet', 'body', 'eye.left', 'eye.right', 'cap', 'leaf']


def write_png(path, width, height, pixels):
    """Write lossless, unassociated sRGB RGBA without a Python image dependency."""
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
    rows = b''.join(b'\0' + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    data += chunk(b'sRGB', b'\0') + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def crop_image(image):
    occupied = [(i % image.width, i // image.width) for i in range(image.width * image.height) if image.pixels[i * 4 + 3]]
    if not occupied:
        raise ValueError('Cannot export an empty layer')
    x0, x1 = max(0, min(x for x, _ in occupied) - 2), min(image.width, max(x for x, _ in occupied) + 3)
    y0, y1 = max(0, min(y for _, y in occupied) - 2), min(image.height, max(y for _, y in occupied) + 3)
    pixels = b''.join(image.pixels[(y * image.width + x0) * 4:(y * image.width + x1) * 4] for y in range(y0, y1))
    return {'x': x0, 'y': y0, 'width': x1 - x0, 'height': y1 - y0}, pixels


def composite(layers, canvas_size=SIZE):
    """Deterministic source-over encoded sRGB reference, with no correction plate.

    Core Animation color management must be checked independently by its native
    integration harness before treating this offline reference as presentation.
    """
    result = bytearray(canvas_size * canvas_size * 4)
    for image, frame in layers:
        for y in range(image.height):
            for x in range(image.width):
                si = (y * image.width + x) * 4
                di = ((y + frame['y']) * canvas_size + x + frame['x']) * 4
                sa, da = image.pixels[si + 3] / 255, result[di + 3] / 255
                a = sa + da * (1 - sa)
                if not a:
                    continue
                for c in range(3):
                    result[di + c] = round((image.pixels[si + c] * sa + result[di + c] * da * (1 - sa)) / a)
                result[di + 3] = round(a * 255)
    return bytes(result)


def worker(output):
    import bpy
    from bpy_extras.object_utils import world_to_camera_view
    from mathutils import Matrix
    scene = bpy.context.scene
    rig = bpy.data.objects['Acorn Hopper Rig']
    action = bpy.data.actions['Acorn Hopper · idle']
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    rig.pose.bones['Stage'].matrix_basis = Matrix.Identity(4)
    scene.frame_set(1)
    bpy.context.view_layer.update()
    meshes = [obj for obj in scene.objects if obj.type == 'MESH']
    # Preserve source camera, lights, seed, color transform and 40 samples.
    scene.render.resolution_x = scene.render.resolution_y = SIZE
    output.mkdir(parents=True, exist_ok=True)
    def render(name, selected):
        for obj in meshes:
            # A moving eye cannot leave an open-eye contact shadow tattoo on
            # the face underneath it. Render actual clean skin with all eye
            # transport absent; keep cap/body/feet transport intact.
            obj.hide_render = name == 'body' and obj.name.startswith('Eye.')
            obj.visible_camera = obj.name in selected
        scene.render.filepath = str(output / (name + '.png'))
        bpy.context.view_layer.update()
        bpy.ops.render.render(write_still=True)
    render('whole', [obj.name for obj in meshes])
    for name, selected in GROUPS.items():
        render(name, selected)
    # Fractional shapes come from the original authored Blink driver. The
    # eye and matte crease are rendered together at each bounded blink state.
    rig.animation_data_clear()
    for amount in (.35, .7, 1.):
        rig['Blink'] = amount
        rig['Happy'] = 0.
        rig.update_tag()
        bpy.context.view_layer.update()
        for side, label in (('L', 'left'), ('R', 'right')):
            render(f'blink.{label}.{amount:g}', ['Eye.' + side, 'Eye.Lid.' + side])
    pivots = {}
    for layer, bone in [('body', 'Body'), ('cap', 'Cap'), ('leaf', 'Leaf')]:
        p = world_to_camera_view(scene, scene.camera, rig.matrix_world @ rig.data.bones[bone].head_local)
        pivots[layer] = {'x': p.x * SIZE, 'y': (1 - p.y) * SIZE}
    (output / 'render.json').write_text(json.dumps({
        'blenderVersion': bpy.app.version_string, 'samples': scene.cycles.samples,
        'device': scene.cycles.device, 'pivots': pivots,
        'sourceSHA256': hashlib.sha256((SOURCE / 'acorn-hopper.blend').read_bytes()).hexdigest(),
    }, indent=2) + '\n')


def package(raw, destination):
    source_manifest = json.loads((SOURCE / 'runtime/manifest.json').read_text())
    render = json.loads((raw / 'render.json').read_text())
    names = ORDER + [f'blink.{side}.{amount:g}' for amount in (.35, .7, 1.) for side in ('left', 'right')]
    layers, poses = [], {}
    for name in names:
        image = read_rgba_png(raw / (name + '.png'))
        frame, pixels = crop_image(image)
        file = 'layers/' + name + '.png'
        write_png(destination / file, frame['width'], frame['height'], pixels)
        parent = 'body' if name in ('cap', 'eye.left', 'eye.right') or name.startswith('blink.') else 'cap' if name == 'leaf' else None
        pivot = render['pivots'].get(name, {'x': frame['x'] + frame['width'] / 2, 'y': frame['y'] + frame['height'] / 2})
        record = {'id': name, 'file': file, 'parent': parent, 'framePixels': frame,
                  'pivotPixels': pivot, 'zIndex': ORDER.index(name) if name in ORDER else 3,
                  'defaultOpacity': 1 if name in ORDER else 0,
                  'decodedSHA256': hashlib.sha256(pixels).hexdigest()}
        if name.startswith('eye.'):
            # Match the actual projected dark-eye silhouette. The neutral eye
            # does not apply this mask, avoiding alpha-squared AA at rest. The
            # mask participates only in the experimental gaze channel.
            mask = bytes(c if i % 4 == 3 else 255 for i, c in enumerate(pixels))
            mask_file = 'layers/' + name + '.mask.png'
            write_png(destination / mask_file, frame['width'], frame['height'], mask)
            record['maskFile'] = mask_file
            record['maskActivation'] = 'gazeOnly'
        layers.append(record)
        poses[name] = (read_rgba_png(destination / file), frame)
    canonical = composite([poses[name] for name in ORDER])
    write_png(destination / 'neutral.png', SIZE, SIZE, canonical)
    neutral = read_rgba_png(destination / 'neutral.png')
    baseline = read_rgba_png(SOURCE / 'runtime/rest.png')
    diff = endpoint_difference(neutral, baseline)
    rig = {
        'schemaVersion': 1, 'kind': 'layeredRestRigPrototype', 'status': 'artProofOnly',
        'sourceCanvasPixels': {'width': SIZE, 'height': SIZE},
        'displaySizePoints': {'width': 96, 'height': 96},
        'coordinateSystem': 'topLeftPixels',
        'groundAnchorPixels': {'x': source_manifest['groundAnchorPixels']['x'], 'y': SIZE - source_manifest['groundAnchorPixels']['y']},
        'layers': layers,
        'channels': {
            'bodyBreath': {'layer': 'body', 'maximumScaleY': 1.004, 'durationSeconds': 3.2, 'repeats': False},
            'capLean': {'layer': 'cap', 'maximumDegrees': .65},
            'leafSway': {'layer': 'leaf', 'maximumDegrees': 1.1, 'delaySeconds': .08},
            'eyeGaze': {'layers': ['eye.left', 'eye.right'], 'maximumOffsetPixels': 1., 'status': 'requiresNativeArtReview'},
            'blink': {'durationSeconds': .16, 'amounts': [0, .35, .7, 1., .7, .35, 0],
                      'replaces': ['eye.left', 'eye.right'], 'blend': 'discrete', 'repeats': False},
        },
        'canonical': {'pose': 'ready', 'file': 'neutral.png', 'decodedSHA256': hashlib.sha256(canonical).hexdigest()},
        'boundaryVerification': {'legacyExact': diff['identicalDecodedPixels'], 'legacyDifference': diff,
                                 'rerenderDifference': endpoint_difference(read_rgba_png(raw / 'whole.png'), baseline),
                                 'productionHandoffApproved': False},
        'provenance': {**render, 'exporterSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},
    }
    rig['decodedLayerBytes'] = sum(read_rgba_png(destination / item['file']).width * read_rgba_png(destination / item['file']).height * 4 for item in layers)
    rig['decodedMaskBytes'] = sum(read_rgba_png(destination / item['maskFile']).width * read_rgba_png(destination / item['maskFile']).height * 4 for item in layers if 'maskFile' in item)
    (destination / 'rest-rig.json').write_text(json.dumps(rig, indent=2) + '\n')
    endpoint_proposal(destination, rig, source_manifest)
    return rig


def endpoint_proposal(destination, rig, source_manifest):
    """Explicitly identify new-package ready junctions; never rewrite v03."""
    motion = json.loads((SOURCE / 'motion.json').read_text())
    canonical = read_rgba_png(destination / 'neutral.png')
    expected = motion['clips']['idle'][0]
    entries = []
    for clip, boundaries in motion['boundaries'].items():
        if clip == 'sleep':
            continue
        frames = source_manifest['clips'][clip]['frames']
        for index, pose in ((0, boundaries[0]), (len(frames) - 1, boundaries[1])):
            if pose != 'ready':
                continue
            authored = motion['clips'][clip][index]
            pose_error = max(abs(a - b) for name, values in expected['inPlacePose'].items()
                             for a, b in zip(values, authored['inPlacePose'][name]))
            face_error = max(abs(value - authored['expression'][key]) for key, value in expected['expression'].items())
            if pose_error > 2e-5 or face_error > 1e-6 or not all(foot['planted'] for foot in authored['feet'].values()):
                raise ValueError(f'{clip}/{index}: ready endpoint is not a grounded shared pose')
            original = read_rgba_png(SOURCE / 'runtime' / frames[index]['file'])
            adjacent_index = 1 if index == 0 else index - 1
            adjacent = read_rgba_png(SOURCE / 'runtime' / frames[adjacent_index]['file'])
            entries.append({
                'clipID': clip, 'frameIndex': index, 'pose': 'ready',
                'originalFile': frames[index]['file'], 'replacementFile': 'neutral.png',
                'rootOffsetPoints': {key: value * 96 / 224 for key, value in frames[index]['rootOffsetPoints'].items()},
                'maximumInPlacePoseError': pose_error, 'maximumExpressionError': face_error,
                'allFeetPlanted': True,
                'canonicalDifference': endpoint_difference(canonical, original),
                'originalAdjacentDifference': endpoint_difference(original, adjacent),
                'normalizedAdjacentDifference': endpoint_difference(canonical, adjacent),
            })
    proposal = {
        'schemaVersion': 1, 'kind': 'schema3CanonicalEndpointProposal',
        'status': 'requiresNativeHandoffVerification',
        'sourceManifestSHA256': hashlib.sha256((SOURCE / 'runtime/manifest.json').read_bytes()).hexdigest(),
        'canonicalDecodedSHA256': rig['canonical']['decodedSHA256'],
        'framesPerSecond': 30, 'displaySizePoints': {'width': 96, 'height': 96},
        'replaceRestFrame': 'neutral.png', 'preserveAllOtherFrames': True,
        'preserveFrameCountsTimingAndRootOffsets': True,
        'entries': entries,
    }
    (destination / 'canonical-endpoints.json').write_text(json.dumps(proposal, indent=2) + '\n')


def verify(destination=DESTINATION):
    rig = json.loads((destination / 'rest-rig.json').read_text())
    assert rig['status'] == 'artProofOnly'
    assert rig['boundaryVerification']['productionHandoffApproved'] is False
    layers = {layer['id']: layer for layer in rig['layers']}
    decoded = []
    assert len(layers) == len(rig['layers'])
    for layer in rig['layers']:
        image = read_rgba_png(destination / layer['file'])
        assert image.width == layer['framePixels']['width'] and image.height == layer['framePixels']['height']
        frame = layer['framePixels']
        assert 0 <= frame['x'] < SIZE and 0 <= frame['y'] < SIZE
        assert frame['x'] + image.width <= SIZE and frame['y'] + image.height <= SIZE
        assert hashlib.sha256(image.pixels).hexdigest() == layer['decodedSHA256']
        if 'maskFile' in layer:
            mask = read_rgba_png(destination / layer['maskFile'])
            assert (mask.width, mask.height) == (image.width, image.height)
            assert mask.pixels[3::4] == image.pixels[3::4], 'Eye mask differs from projected source geometry'
        if layer['id'] in ORDER:
            decoded.append((image, frame))
    pixels = composite(decoded)
    assert pixels == read_rgba_png(destination / rig['canonical']['file']).pixels, 'Canonical differs from real source-over layer composition'
    assert hashlib.sha256(pixels).hexdigest() == rig['canonical']['decodedSHA256']
    diff = endpoint_difference(read_rgba_png(destination / rig['canonical']['file']), read_rgba_png(SOURCE / 'runtime/rest.png'))
    assert diff == rig['boundaryVerification']['legacyDifference'], 'Legacy boundary report is stale'
    assert rig['provenance']['exporterSHA256'] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'Exporter changed after export'
    assert rig['provenance']['sourceSHA256'] == hashlib.sha256((SOURCE / 'acorn-hopper.blend').read_bytes()).hexdigest(), 'Blender source changed after export'
    proposal = json.loads((destination / 'canonical-endpoints.json').read_text())
    assert proposal['canonicalDecodedSHA256'] == rig['canonical']['decodedSHA256']
    source_manifest = json.loads((SOURCE / 'runtime/manifest.json').read_text())
    motion = json.loads((SOURCE / 'motion.json').read_text())
    expected_endpoints = {(clip, index) for clip, boundaries in motion['boundaries'].items() if clip != 'sleep'
                          for index, pose in ((0, boundaries[0]), (len(source_manifest['clips'][clip]['frames']) - 1, boundaries[1]))
                          if pose == 'ready'}
    actual_endpoints = {(entry['clipID'], entry['frameIndex']) for entry in proposal['entries']}
    assert actual_endpoints == expected_endpoints and len(proposal['entries']) == len(expected_endpoints), 'Unexpected ready junction inventory'
    for entry in proposal['entries']:
        assert entry['allFeetPlanted'] and entry['maximumInPlacePoseError'] <= 2e-5
        assert entry['maximumExpressionError'] <= 1e-6
        original = source_manifest['clips'][entry['clipID']]['frames'][entry['frameIndex']]
        assert entry['originalFile'] == original['file']
        assert entry['rootOffsetPoints'] == {key: value * 96 / 224 for key, value in original['rootOffsetPoints'].items()}
    return rig


def proof(destination, output):
    from PIL import Image, ImageDraw
    rig = verify(destination)
    layers = {layer['id']: layer for layer in rig['layers']}
    # 2× pixels represent point-size canvases; no enlarged art masquerades as
    # native proof. Labels explicitly say this is an offline static board.
    board = Image.new('RGB', (1560, 960), '#e9e7e2')
    draw = ImageDraw.Draw(board)
    draw.text((24, 16), 'ACORN REST RIG | offline @2x proof | 72 / 96 / 120 point canvases | NOT production accepted', fill='#333333')
    for row, bg in enumerate(('light', 'dark', 'busy')):
        y = 56 + row * 298
        draw.rectangle((12, y, 1548, y + 282), fill='#f8f5ef' if bg == 'light' else '#242830')
        if bg == 'busy':
            for yy in range(y, y + 282, 14):
                for xx in range(12, 1548, 14):
                    draw.rectangle((xx, yy, xx + 6, yy + 6), fill='#65746b' if (xx + yy) % 3 else '#ba9976')
        for col, points in enumerate((72, 96, 120)):
            x = 40 + col * 506
            draw.text((x, y + 10), f'{bg.upper()} / {points} pt / neutral & blink closed', fill='#333333' if bg == 'light' else '#eeeeee')
            for variant, amount in enumerate((0, 1)):
                items=[]
                for name in ORDER:
                    actual = name.replace('eye.', 'blink.') + '.1' if amount and name.startswith('eye.') else name
                    layer=layers[actual]
                    items.append((read_rgba_png(destination / layer['file']), layer['framePixels']))
                pixels=composite(items)
                sprite=Image.frombytes('RGBA',(SIZE,SIZE),pixels).resize((points*2,points*2),Image.Resampling.LANCZOS)
                board.paste(sprite,(x + variant * 250, y + 34),sprite)
    output.parent.mkdir(parents=True, exist_ok=True)
    board.save(output)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--blender', default='/Applications/Blender.app/Contents/MacOS/Blender')
    parser.add_argument('--output', type=Path, default=DESTINATION)
    parser.add_argument('--raw', type=Path, default=ROOT / '.build/rest-rig-v04/raw')
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--package-only', action='store_true')
    parser.add_argument('--proof', type=Path)
    argv=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else sys.argv[1:]
    args=parser.parse_args(argv)
    if args.worker:
        worker(args.raw.resolve()); return
    if args.proof:
        proof(args.output, args.proof); return
    if not args.check:
        if not args.package_only:
            subprocess.run([args.blender,'--background',str(SOURCE / 'acorn-hopper.blend'),'--python-exit-code','1',
                            '--python',str(Path(__file__).resolve()),'--','--worker','--raw',str(args.raw.resolve())],check=True)
        package(args.raw,args.output)
    rig=verify(args.output)
    print(json.dumps({'layers':len(rig['layers']), 'decodedLayerBytes':rig['decodedLayerBytes'],
                      'decodedMaskBytes':rig['decodedMaskBytes'], 'legacyExact':rig['boundaryVerification']['legacyExact'],
                      'productionHandoffApproved':False}))


if __name__ == '__main__':
    main()
