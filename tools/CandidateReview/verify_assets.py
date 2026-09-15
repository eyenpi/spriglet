#!/usr/bin/env python3
"""Read-only checks for the two Blender candidate proofs and measured rig data."""

import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/CharacterSampleValidation'))
from png_validation import alpha_measurements, endpoint_difference, read_rgba_png

COUNTS = {'idle': 42, 'walkRight': 24, 'walkLeft': 24, 'pet': 30, 'settle': 18, 'sleep': 1}


def measure_contacts(samples):
    """Independent measurements of evaluated rig output, with explicit stance breaks."""
    drift = ground = rig_error = 0.
    previous, counts = {}, {}
    for sample in samples:
        for name, foot in sample['feet'].items():
            observed = foot['evaluatedWorld']
            if not all(math.isfinite(v) for v in observed + foot['world']):
                raise ValueError('Non-finite rig measurement')
            rig_error = max(rig_error, math.dist(observed, foot['world']))
            if foot['planted']:
                counts[name] = counts.get(name, 0) + 1
                ground = max(ground, abs(observed[2]))
                if name in previous:
                    drift = max(drift, math.dist(observed, previous[name]))
                previous[name] = observed
            else:
                previous.pop(name, None)
    return {'maximumPlantedDriftWorld': drift, 'maximumGroundErrorWorld': ground,
            'maximumEvaluatedRigErrorWorld': rig_error, 'plantedFrameCoverage': counts}


def pose_distance(first, second):
    if set(first) != set(second):
        return math.inf
    if any(len(first[key]) != len(second[key]) for key in first):
        return math.inf
    values = [abs(a - b) for key in first for a, b in zip(first[key], second[key])]
    return max(values, default=math.inf) if all(math.isfinite(v) for v in values) else math.inf


def check_candidate(root):
    build = json.loads((root / 'build.json').read_text())
    motion = json.loads((root / 'motion.json').read_text())
    manifest = json.loads((root / 'runtime/manifest.json').read_text())
    refined = build.get('revision') == 'refinement-v02'
    failures, stats, images = [], {}, {}

    def require(condition, message):
        if not condition:
            failures.append(message)

    require(build['controlBones'] <= 12, 'Control skeleton exceeds the proof budget')
    require(build['externalTextures'] == build['hairObjects'] == 0, 'Unexpected external texture or groom')
    require(manifest['canvasPixels'] == {'width': 448, 'height': 448}, 'Incorrect source pixel dimensions')
    require(manifest['displaySizePoints'] == {'width': 224, 'height': 224}, 'Incorrect source point dimensions')
    require(manifest['framesPerSecond'] == motion['framesPerSecond'] == 30, 'Incorrect frame rate')
    require(set(manifest['clips']) == {'walkRight', 'walkLeft', 'idle', 'pet', 'settle'}, 'Invalid clip set')
    if refined:
        require(build['framesPerClip'] == COUNTS, 'Incorrect authored action counts')
        require(set(motion['clips']) == set(COUNTS), 'Incorrect measured action set')
        require(build['builderSHA256'] == hashlib.sha256((ROOT / 'art/candidates/scripts/build_candidates.py').read_bytes()).hexdigest(), 'Builder changed after rendering')
        for name, digest in build['helperSHA256'].items():
            require(digest == hashlib.sha256((ROOT / 'art/sprout/scripts' / name).read_bytes()).hexdigest(), f'Helper changed after rendering: {name}')
    files = {manifest['restFrame'], manifest['sleepFrame']}
    boundary_files = set(files)
    for clip in manifest['clips'].values():
        files.update(frame['file'] for frame in clip['frames'])
        boundary_files.update((clip['frames'][0]['file'], clip['frames'][-1]['file']))
    for name in sorted(files):
        path = PurePosixPath(name)
        require(not path.is_absolute() and all(p not in ('', '..', '.') for p in name.split('/'))
                and path.suffix == '.png' and '\\' not in name and ':' not in name, 'Unsafe frame path')
        if failures and failures[-1] == 'Unsafe frame path':
            continue
        image = read_rgba_png(root / 'runtime' / name, expected_size=(448, 448))
        stats[name] = alpha_measurements(image)
        stats[name]['fileSHA256'] = image.file_sha256
        require(stats[name]['maximumBorderAlpha'] == 0, f'Clipped canvas: {name}')
        require(stats[name]['opaquePixels'] > 500, f'Empty character: {name}')
        require(stats[name]['partialAlphaPixels'] > 0, f'Missing antialiasing/transparency: {name}')
        box = stats[name]['alphaBoundsTopLeftPixels']
        require(box and box['minX'] >= 3 and box['minY'] >= 3
                and box['maxX'] <= 444 and box['maxY'] <= 444, f'Insufficient animation margin: {name}')
        if name in boundary_files:
            images[name] = image

    clip_reports = {}
    for clip_name in (COUNTS if refined else ('walkRight', 'walkLeft')):
        direction = 1 if clip_name == 'walkRight' else -1 if clip_name == 'walkLeft' else 0
        frames = manifest['clips'][clip_name]['frames'] if clip_name != 'sleep' else [
            {'file': manifest['sleepFrame'], 'rootOffsetPoints': {'x': 0., 'y': 0.}}]
        samples = motion['clips'][clip_name]
        expected_count = COUNTS[clip_name] if refined else 24
        require(len(frames) == len(samples) == expected_count, f'{clip_name}: wrong action length')
        require(frames[0]['rootOffsetPoints'] == {'x': 0., 'y': 0.}, f'{clip_name}: nonzero initial root')
        contact = measure_contacts(samples)
        maximum_root_error = maximum_expression_error = 0.
        for frame, sample in zip(frames, samples):
            world_root = sample['rootWorld']
            require(all(math.isfinite(v) for v in world_root + list(frame['rootOffsetPoints'].values())), f'{clip_name}: non-finite root')
            require(set(sample['feet']) == set(samples[0]['feet']), f'{clip_name}: missing foot measurement')
            root_points = sum(a * b for a, b in zip(world_root, motion['travelAxis'])) * 224 / motion['cameraScale']
            maximum_root_error = max(maximum_root_error, abs(root_points - frame['rootOffsetPoints']['x']), abs(frame['rootOffsetPoints']['y']))
            if refined:
                require(len(sample['evaluatedExpressions']) == 6, f'{clip_name}: missing facial controls')
                for obj, keys in sample['evaluatedExpressions'].items():
                    require(set(keys) == ({'Happy', 'Blink'} if obj.startswith('Eye.') else {'Happy'}), f'{clip_name}: incomplete expression keys')
                    for key, value in keys.items():
                        require(math.isfinite(value) and 0 <= value <= 1, f'{clip_name}: invalid expression value')
                        maximum_expression_error = max(maximum_expression_error, abs(value - sample['expression'][key]))
        require(contact['maximumEvaluatedRigErrorWorld'] < 2e-5, f'{clip_name}: evaluated rig differs from intended pose')
        require(maximum_root_error < 1e-4, f'{clip_name}: image/root metadata disagree')
        require(contact['maximumPlantedDriftWorld'] < 2e-5, f'{clip_name}: planted foot slides')
        require(contact['maximumGroundErrorWorld'] < 2e-5, f'{clip_name}: planted foot is above/below ground')
        require(maximum_expression_error < 1e-5, f'{clip_name}: wrong facial action applied')
        require(len(contact['plantedFrameCoverage']) == (4 if root.name == 'moss-mouse' else 2)
                and all(count >= min(8, expected_count) for count in contact['plantedFrameCoverage'].values()), f'{clip_name}: missing stance coverage')
        travel = frames[-1]['rootOffsetPoints']['x'] * 96 / 224
        require(95 < travel * direction < 115 if direction else all(math.dist(sample['rootWorld'], [0, 0, 0]) < 1e-6 for sample in samples), f'{clip_name}: wrong review travel')
        clip_reports[clip_name] = {
            'durationSeconds': len(frames) / 30, 'travelAt96Points': travel,
            **contact, 'maximumRootMetadataErrorPoints': maximum_root_error,
            'maximumExpressionError': maximum_expression_error,
            'endpointPixels': endpoint_difference(images[manifest['restFrame']], images[frames[-1]['file']]),
        }

    transitions = {}
    if refined:
        resting = motion['clips']['idle'][0]['inPlacePose']
        for clip in ('idle', 'walkRight', 'walkLeft', 'settle'):
            error = pose_distance(resting, motion['clips'][clip][-1]['inPlacePose'])
            require(error < 2e-5, f'{clip}: pose does not return to rest')
            transitions[clip + ' → rest'] = error
        error = pose_distance(motion['clips']['pet'][-1]['inPlacePose'], motion['clips']['settle'][0]['inPlacePose'])
        require(error < 2e-5, 'Pet/settle pose discontinuity')
        transitions['pet → settle'] = error
        require(motion['clips']['pet'][-1]['expression'] == motion['clips']['settle'][0]['expression'], 'Pet/settle expression discontinuity')
        require(images[manifest['sleepFrame']].pixels != images[manifest['restFrame']].pixels, 'Sleep is still a rest alias')
        for clip in ('idle', 'pet', 'settle'):
            require(len({stats[f['file']]['fileSHA256'] for f in manifest['clips'][clip]['frames']}) > 8,
                    f'{clip}: expected genuinely animated frames')

    rest = images[manifest['restFrame']]
    opaque = [i for i, a in enumerate(rest.pixels[3::4]) if a > 224]
    width = (max(i % 448 for i in opaque) - min(i % 448 for i in opaque) + 1) * 96 / 448
    height = (max(i // 448 for i in opaque) - min(i // 448 for i in opaque) + 1) * 96 / 448
    require(48 < height < 80, 'Neutral pet is outside the tiny-size target')
    return {'candidate': root.name, 'passed': not failures, 'failures': failures,
            'uniquePNGCount': len(files), 'neutralOpaqueSizeAt96Points': {'width': width, 'height': height},
            'maximumBorderAlpha': max(item['maximumBorderAlpha'] for item in stats.values()), 'clips': clip_reports,
            'maximumPoseElementErrorAtTransitions': transitions,
            'limits': 'Numerical checks establish export and authored contact properties, not likeness or appeal.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=ROOT / 'art/candidates/refinement-v02')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/candidate-refinement/asset-checks.json')
    args = parser.parse_args()
    results = [check_candidate(args.assets / candidate) for candidate in ('acorn-hopper', 'moss-mouse')]
    report = {'passed': all(item['passed'] for item in results), 'candidates': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
