#!/usr/bin/env python3
"""Build Acorn's schema-3 package with explicitly normalized ready endpoints.

The legacy manifest and PNGs remain byte-identical compatibility resources.
Use --output for a candidate; --check is read-only and checks every added byte.
"""

import argparse
import copy
import json
import hashlib
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
LEGACY = ROOT / 'Sources/Spriglet/Resources/AcornHopper'
RIG = ROOT / 'art/candidates/rest-rig-v04/acorn-hopper'
REACTIVE = ROOT / 'art/candidates/reactive-v04/acorn-hopper'
PACKAGE_NAME = 'character.json'


def build_package(legacy, rig, endpoints):
    assert legacy['schemaVersion'] == 2
    assert legacy['canvasPixels'] == rig['sourceCanvasPixels']
    assert legacy['displaySizePoints'] == rig['displaySizePoints']
    boundaries = {
        'idle': ('ready', 'ready'), 'walkLeft': ('ready', 'ready'),
        'walkRight': ('ready', 'ready'), 'pet': ('ready', 'happy'),
        'settle': ('happy', 'ready'), 'fallAsleep': ('ready', 'asleep'),
        'wakeUp': ('asleep', 'ready'),
    }
    canonical = 'restRig/' + rig['canonical']['file']
    clips = {}
    for name, source in legacy['clips'].items():
        start, end = boundaries[name]
        moving = name in ('walkLeft', 'walkRight')
        frames = copy.deepcopy(source['frames'])
        clips[name] = {
            'startPoseID': start, 'endPoseID': end,
            'framesPerSecond': legacy['framesPerSecond'], 'frames': frames,
            'tags': ['locomotion' if moving else 'gesture'],
            'requirements': {'habitatIDs': [], 'orientationIDs': [], 'capabilityIDs': []},
            'motionClass': 'relocation' if moving else ('stationary' if name == 'idle' else 'local'),
            'interruptionMarkers': [{'id': 'settled', 'frameIndex': len(frames) - 1}],
            'semanticEvents': [],
            'ownership': {'mode': 'exclusive', 'channelIDs': ['body', 'face', 'shadow', 'secondaryMotion']},
        }
    replacements = set()
    for endpoint in endpoints['entries']:
        clip = clips[endpoint['clipID']]
        index = endpoint['frameIndex']
        frame = clip['frames'][index]
        assert endpoint['allFeetPlanted'] and endpoint['pose'] == 'ready'
        assert frame['file'] == endpoint['originalFile']
        assert all(abs(frame['rootOffsetPoints'][axis] - endpoint['rootOffsetPoints'][axis]) < 1e-9
                   for axis in ('x', 'y'))
        assert (index == 0 and clip['startPoseID'] == 'ready') or (
            index == len(clip['frames']) - 1 and clip['endPoseID'] == 'ready')
        frame['file'] = canonical
        clip['interruptionMarkers'].extend([{'id': 'feetPlanted', 'frameIndex': index},
                                             {'id': 'safeToRedirect', 'frameIndex': index}])
        clip['interruptionMarkers'].sort(key=lambda marker: (marker['frameIndex'], marker['id']))
        replacements.add((endpoint['clipID'], index))
    assert len(replacements) == 10, 'Every shared ready junction must use the new canonical'

    layers = {}
    for source in rig['layers']:
        layer = {key: source[key] for key in ('framePixels', 'pivotPixels', 'zIndex', 'defaultOpacity')}
        layer['file'] = 'restRig/' + source['file']
        if source.get('parent'):
            layer['parentID'] = source['parent']
        if source.get('maskFile'):
            layer['mask'] = {'file': 'restRig/' + source['maskFile'], 'activationChannelID': 'eyes.gaze'}
        layers[source['id']] = layer

    def channel(semantic, layer_ids, kind, duration, delay=0):
        return {'semanticID': semantic, 'layerIDs': layer_ids, 'kind': kind,
                'durationSeconds': duration, 'delaySeconds': delay, 'repeats': False}

    data = rig['channels']
    channels = {
        'eyes.gaze': channel('gaze', data['eyeGaze']['layers'],
            {'type': 'translation', 'maximumOffsetPixels': {'x': data['eyeGaze']['maximumOffsetPixels'],
                                                          'y': data['eyeGaze']['maximumOffsetPixels']}}, 0.16),
        'body.breath': channel('breath', [data['bodyBreath']['layer']],
            {'type': 'scale', 'maximumDelta': {'x': 0, 'y': data['bodyBreath']['maximumScaleY'] - 1}},
            data['bodyBreath']['durationSeconds']),
        'cap.lean': channel('lean', [data['capLean']['layer']],
            {'type': 'rotation', 'maximumDegrees': data['capLean']['maximumDegrees']}, 0.24, 0.035),
        'leaf.sway': channel('secondaryMotion', [data['leafSway']['layer']],
            {'type': 'rotation', 'maximumDegrees': data['leafSway']['maximumDegrees']}, 0.30,
            data['leafSway']['delaySeconds']),
    }
    for side in ('left', 'right'):
        sequence = [f'blink.{side}.{amount}' for amount in ('0.35', '0.7', '1', '0.7', '0.35')]
        channels[f'eye.{side}.blink'] = channel(f'blink.{side}', [f'eye.{side}'],
            {'type': 'discreteReplacement', 'layerIDs': sequence, 'replacesLayerIDs': [f'eye.{side}']},
            data['blink']['durationSeconds'])

    def intent(pose, names=(), replay=False, fallback=None, reduced=None):
        result = {'targetPoseID': pose, 'clipIDs': list(names), 'replaysAtTarget': replay}
        if fallback: result['fallbackIntentID'] = fallback
        if reduced: result['reducedMotionIntentID'] = reduced
        return result

    intents = {
        'ready': intent('ready'), 'curious': intent('ready', ['idle'], True),
        'moveLeft': intent('ready', ['walkLeft'], True, 'curious', 'ready'),
        'moveRight': intent('ready', ['walkRight'], True, 'curious', 'ready'),
        'happy': intent('ready', ['pet', 'settle'], True),
        'sleep': intent('asleep', ['fallAsleep']), 'wake': intent('ready'),
    }
    bindings = {f'transition.{name}': name for name in intents}
    bindings.update({f'petAction.{name}': target for name, target in {
        'blink': 'curious', 'lookAround': 'curious', 'stretch': 'curious',
        'fallAsleep': 'sleep', 'wakeUp': 'wake', 'react': 'happy',
    }.items()})
    canvas = legacy['canvasPixels']
    return {
        'schemaVersion': 3, 'identifier': 'acorn-hopper', 'displayName': 'Acorn Hopper',
        'coordinateSystem': 'topLeftPixels', 'canvasPixels': canvas,
        'displaySizePoints': legacy['displaySizePoints'], 'groundAnchorPixels': rig['groundAnchorPixels'],
        'contentBoundsPixels': {'x': 0, 'y': 0, **canvas},
        'featurePolicy': {'required': ['character-package.core', 'animation-graph.routes', 'layered-rest-rig'],
                          'optional': []},
        'capabilities': ['animatedSleep', 'layeredRest', 'gaze', 'blink'],
        'poses': {'ready': {'stillFrame': canonical, 'layerIDs': sorted(layers)},
                  'happy': {'stillFrame': legacy['clips']['pet']['frames'][-1]['file'], 'layerIDs': []},
                  'asleep': {'stillFrame': legacy['sleepFrame'], 'layerIDs': []}},
        'clips': clips, 'layers': layers, 'proceduralChannels': channels, 'hitRegions': {},
        'semanticBindings': bindings,
        'animationGraph': {'defaultPoseID': 'ready', 'intents': intents,
                           'transitionClipIDs': ['settle', 'wakeUp'], 'instantTransitions': []},
        'resourceBudget': {'maxDecodedImageBytes': 16 * 1_048_576, 'maxBufferedFrames': 12,
                           'maxDecodedLayerBytes': 1_048_576},
    }


def expected(legacy):
    rig = json.loads((RIG / 'rest-rig.json').read_text())
    endpoints = json.loads((RIG / 'canonical-endpoints.json').read_text())
    package = build_package(legacy, rig, endpoints)
    files = {rig['canonical']['file']}
    for layer in rig['layers']:
        files.add(layer['file'])
        if layer.get('maskFile'): files.add(layer['maskFile'])
    resources = {'restRig/' + name: RIG / name for name in files}
    merge_authored_library(package, resources, REACTIVE, 'reactive')
    library = json.loads((REACTIVE / 'clips.json').read_text())
    resources['reactive/behavior.json'] = REACTIVE / 'behavior.json'
    package['featurePolicy']['optional'].append('behavior.reactive-v1')
    package['animationGraph']['intents']['reactive.alert'] = {
        'targetPoseID': 'ready',
        'clipIDs': ['reactive.alert', 'reactive.dismiss'],
        'replaysAtTarget': True,
        'fallbackIntentID': 'curious',
        'reducedMotionIntentID': 'curious',
    }
    for intent_id, clip_ids in library['phrases'].items():
        package['animationGraph']['intents'][intent_id] = {
            'targetPoseID': 'ready', 'clipIDs': clip_ids, 'replaysAtTarget': True,
            'fallbackIntentID': 'curious', 'reducedMotionIntentID': 'ready',
        }
    package['animationGraph']['transitionClipIDs'] += [
        'reactive.dismiss', 'reactive.abort.left', 'reactive.abort.right',
        'reactive.brake.left', 'reactive.brake.right',
    ]
    package['capabilities'].append('reactiveDodge')
    return package, resources


def merge_authored_library(package, resources, directory, prefix):
    """Merge a verified additive clip library without replacing the rest rig."""
    library = json.loads((directory / 'clips.json').read_text())
    assert library['schemaVersion'] == 1 and library['kind'] == 'schema3AuthoredClipLibrary'
    for key in ('canvasPixels', 'displaySizePoints', 'coordinateSystem'):
        assert library[key] == package[key], f'Incompatible library {key}'
    canonical = package['poses']['ready']['stillFrame']
    fragment_ready = library['poses']['ready']['stillFrame']
    assert (directory / fragment_ready).read_bytes() == resources[canonical].read_bytes()

    def path(name):
        assert isinstance(name, str) and name.endswith('.png')
        assert all(part not in ('', '.', '..') for part in name.split('/'))
        assert not any(character in name for character in ('\\', ':', '\0'))
        source = directory / name
        assert source.resolve().is_relative_to(directory.resolve()) and not source.is_symlink()
        assert hashlib.sha256(source.read_bytes()).hexdigest() == library['imagesSHA256'][name]
        if name == fragment_ready:
            return canonical
        target = prefix + '/' + name
        assert target not in resources or resources[target] == source
        resources[target] = source
        return target

    for pose_id, value in library['poses'].items():
        if pose_id == 'ready':
            path(value['stillFrame'])
            continue
        assert pose_id not in package['poses'], f'Duplicate pose {pose_id}'
        pose = copy.deepcopy(value)
        if pose.get('stillFrame'): pose['stillFrame'] = path(pose['stillFrame'])
        package['poses'][pose_id] = pose
    for clip_id, value in library['clips'].items():
        assert clip_id not in package['clips'], f'Duplicate clip {clip_id}'
        clip = copy.deepcopy(value)
        for frame in clip['frames']: frame['file'] = path(frame['file'])
        package['clips'][clip_id] = clip


def verify(destination=LEGACY):
    legacy = json.loads((destination / 'manifest.json').read_text())
    package, files = expected(legacy)
    assert json.loads((destination / PACKAGE_NAME).read_text()) == package, 'Schema-3 package differs from source'
    for name, source in files.items():
        assert (destination / name).read_bytes() == source.read_bytes(), f'Changed rest-rig asset: {name}'
    return set(files) | {PACKAGE_NAME}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        legacy = json.loads((LEGACY / 'manifest.json').read_text())
        package, files = expected(legacy)
        if args.output.resolve() != LEGACY.resolve():
            names = {legacy['restFrame'], legacy['sleepFrame'], 'manifest.json'}
            names.update(frame['file'] for clip in legacy['clips'].values() for frame in clip['frames'])
            for name in names:
                target = args.output / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(LEGACY / name, target)
        for name, source in files.items():
            target = args.output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        (args.output / PACKAGE_NAME).write_text(json.dumps(package, indent=2) + '\n')
    print(f'Acorn schema 3: {len(verify(args.output))} added package files verified.')


if __name__ == '__main__':
    main()
