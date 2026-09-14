#!/usr/bin/env python3
"""Read-only checks for the two Blender candidate proofs and measured rig data."""

import argparse
import json
import math
from pathlib import Path, PurePosixPath
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/CharacterSampleValidation'))
from png_validation import alpha_measurements, endpoint_difference, read_rgba_png


def check_candidate(root):
    build = json.loads((root / 'build.json').read_text())
    motion = json.loads((root / 'motion.json').read_text())
    manifest = json.loads((root / 'runtime/manifest.json').read_text())
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
    files = {manifest['restFrame'], manifest['sleepFrame']}
    for clip in manifest['clips'].values():
        files.update(frame['file'] for frame in clip['frames'])
    for name in sorted(files):
        path = PurePosixPath(name)
        require(not path.is_absolute() and all(p not in ('', '..', '.') for p in name.split('/'))
                and path.suffix == '.png' and '\\' not in name and ':' not in name, 'Unsafe frame path')
        if failures and failures[-1] == 'Unsafe frame path':
            continue
        image = read_rgba_png(root / 'runtime' / name, expected_size=(448, 448))
        stats[name] = alpha_measurements(image)
        require(stats[name]['maximumBorderAlpha'] == 0, f'Clipped canvas: {name}')
        require(stats[name]['opaquePixels'] > 500, f'Empty character: {name}')
        require(stats[name]['partialAlphaPixels'] > 0, f'Missing antialiasing/transparency: {name}')
        box = stats[name]['alphaBoundsTopLeftPixels']
        require(box and box['minX'] >= 3 and box['minY'] >= 3
                and box['maxX'] <= 444 and box['maxY'] <= 444, f'Insufficient animation margin: {name}')
        if name == manifest['restFrame'] or name.endswith('/0023.png'):
            images[name] = image

    clip_reports = {}
    for clip_name, direction in (('walkRight', 1), ('walkLeft', -1)):
        frames = manifest['clips'][clip_name]['frames']
        samples = motion['clips'][clip_name]
        require(len(frames) == len(samples) == 24, f'{clip_name}: expected 0.8 seconds / 24 frames')
        require(frames[0]['rootOffsetPoints'] == {'x': 0., 'y': 0.}, f'{clip_name}: nonzero initial root')
        maximum_drift = maximum_ground_error = maximum_rig_error = maximum_root_error = 0.
        planted_previous, counts = {}, {}
        for frame, sample in zip(frames, samples):
            world_root = sample['rootWorld']
            root_points = sum(a * b for a, b in zip(world_root, motion['travelAxis'])) * 224 / motion['cameraScale']
            maximum_root_error = max(maximum_root_error, abs(root_points - frame['rootOffsetPoints']['x']), abs(frame['rootOffsetPoints']['y']))
            for name, foot in sample['feet'].items():
                observed = foot['evaluatedWorld']
                maximum_rig_error = max(maximum_rig_error, math.dist(observed, foot['world']))
                if foot['planted']:
                    counts[name] = counts.get(name, 0) + 1
                    maximum_ground_error = max(maximum_ground_error, abs(observed[2]))
                    if name in planted_previous:
                        maximum_drift = max(maximum_drift, math.dist(observed, planted_previous[name]))
                    planted_previous[name] = observed
                else:
                    planted_previous.pop(name, None)
        require(maximum_rig_error < 2e-5, f'{clip_name}: evaluated rig differs from intended pose')
        require(maximum_root_error < 1e-4, f'{clip_name}: image/root metadata disagree')
        require(maximum_drift < 2e-5, f'{clip_name}: planted foot slides')
        require(maximum_ground_error < 2e-5, f'{clip_name}: planted foot is above/below ground')
        require(len(counts) == (4 if root.name == 'moss-mouse' else 2)
                and all(count >= 8 for count in counts.values()), f'{clip_name}: missing stance coverage')
        travel = frames[-1]['rootOffsetPoints']['x'] * 96 / 224
        require(95 < travel * direction < 115, f'{clip_name}: wrong review travel')
        clip_reports[clip_name] = {
            'durationSeconds': len(frames) / 30, 'travelAt96Points': travel,
            'maximumPlantedDriftWorld': maximum_drift, 'maximumGroundErrorWorld': maximum_ground_error,
            'maximumEvaluatedRigErrorWorld': maximum_rig_error, 'maximumRootMetadataErrorPoints': maximum_root_error,
            'plantedFrameCoverage': counts,
            'endpointPixels': endpoint_difference(images[manifest['restFrame']], images[frames[-1]['file']]),
        }

    rest = images[manifest['restFrame']]
    opaque = [i for i, a in enumerate(rest.pixels[3::4]) if a > 224]
    width = (max(i % 448 for i in opaque) - min(i % 448 for i in opaque) + 1) * 96 / 448
    height = (max(i // 448 for i in opaque) - min(i // 448 for i in opaque) + 1) * 96 / 448
    require(48 < height < 80, 'Neutral pet is outside the tiny-size target')
    return {'candidate': root.name, 'passed': not failures, 'failures': failures,
            'uniquePNGCount': len(files), 'neutralOpaqueSizeAt96Points': {'width': width, 'height': height},
            'maximumBorderAlpha': max(item['maximumBorderAlpha'] for item in stats.values()), 'clips': clip_reports,
            'limits': 'Numerical checks establish export and authored contact properties, not likeness or appeal.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=ROOT / 'art/candidates/proof-v01')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/candidate-review/asset-checks.json')
    args = parser.parse_args()
    results = [check_candidate(args.assets / candidate) for candidate in ('acorn-hopper', 'moss-mouse')]
    report = {'passed': all(item['passed'] for item in results), 'candidates': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
