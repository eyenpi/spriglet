import copy
import json
from pathlib import Path
import tempfile
import unittest

import package_acorn


class AcornPackageTests(unittest.TestCase):
    def setUp(self):
        self.legacy = json.loads((package_acorn.LEGACY / 'manifest.json').read_text())
        self.rig = json.loads((package_acorn.RIG / 'rest-rig.json').read_text())
        self.endpoints = json.loads((package_acorn.RIG / 'canonical-endpoints.json').read_text())

    def test_canonical_junctions_preserve_all_authored_timing_and_root_motion(self):
        original = copy.deepcopy(self.legacy)
        package = package_acorn.build_package(self.legacy, self.rig, self.endpoints)
        self.assertEqual(self.legacy, original)
        changed = set()
        for name, clip in package['clips'].items():
            source = original['clips'][name]
            self.assertEqual(clip['framesPerSecond'], original['framesPerSecond'])
            self.assertEqual(len(clip['frames']), len(source['frames']))
            for index, (frame, old) in enumerate(zip(clip['frames'], source['frames'])):
                self.assertEqual(frame['rootOffsetPoints'], old['rootOffsetPoints'])
                if frame['file'] != old['file']:
                    changed.add((name, index))
                    self.assertEqual(frame['file'], package['poses']['ready']['stillFrame'])
        self.assertEqual(changed, {(entry['clipID'], entry['frameIndex']) for entry in self.endpoints['entries']})
        self.assertEqual(len(changed), 10)

    def test_noncanonical_or_moving_junction_cannot_be_substituted(self):
        for field, value in [('allFeetPlanted', False), ('originalFile', 'other.png'),
                             ('frameIndex', 1), ('rootOffsetPoints', {'x': 3, 'y': 0})]:
            with self.subTest(field=field):
                altered = copy.deepcopy(self.endpoints)
                altered['entries'][0][field] = value
                with self.assertRaises(AssertionError):
                    package_acorn.build_package(self.legacy, self.rig, altered)

    def test_tampered_package_or_layer_is_rejected(self):
        package, files = package_acorn.expected(self.legacy)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'manifest.json').write_text(json.dumps(self.legacy))
            (root / package_acorn.PACKAGE_NAME).write_text(json.dumps(package))
            for name, source in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(source.read_bytes())
            self.assertEqual(package_acorn.verify(root), set(files) | {package_acorn.PACKAGE_NAME})
            package['resourceBudget']['maxBufferedFrames'] = 99
            (root / package_acorn.PACKAGE_NAME).write_text(json.dumps(package))
            with self.assertRaises(AssertionError): package_acorn.verify(root)
            package['resourceBudget']['maxBufferedFrames'] = 12
            (root / package_acorn.PACKAGE_NAME).write_text(json.dumps(package))
            (root / next(iter(files))).write_bytes(b'changed')
            with self.assertRaises(AssertionError): package_acorn.verify(root)

    def test_reactive_behavior_is_versioned_and_copied_with_the_graph(self):
        package, files = package_acorn.expected(self.legacy)
        behavior = json.loads(files['reactive/behavior.json'].read_text())
        self.assertEqual(behavior['schemaVersion'], 1)
        self.assertEqual(behavior['characterIdentifier'], package['identifier'])
        self.assertEqual({candidate['intent']['intentID'] for candidate in behavior['candidates']},
                         {'dodge.left', 'dodge.right', 'reactive.alert'})
        self.assertTrue({candidate['intent']['intentID'] for candidate in behavior['candidates']}
                        <= set(package['animationGraph']['intents']))
        self.assertIn('behavior.reactive-v1', package['featurePolicy']['optional'])

    def test_habitat_library_is_finite_local_and_fail_closed(self):
        package, files = package_acorn.expected(self.legacy)
        library = json.loads((package_acorn.HABITATS / 'clips.json').read_text())
        intent_ids = {
            'habitat.floorExit', 'habitat.floorReentry', 'habitat.peekIn',
            'habitat.edgeLook', 'habitat.dangle', 'habitat.pullUp',
            'habitat.ledgeExit',
        }

        self.assertEqual(set(library['clips']), intent_ids)
        self.assertTrue(intent_ids <= set(package['animationGraph']['intents']))
        self.assertIn('animation.habitat-portals-v1', package['featurePolicy']['optional'])
        self.assertTrue({'localPortal', 'ledgeGrip'} <= set(package['capabilities']))
        self.assertNotIn('wallTraversal', package['capabilities'])
        self.assertEqual(package['resourceBudget']['maxBufferedFrames'], 12)
        self.assertEqual(package['poses']['ready']['layerIDs'],
                         sorted(layer['id'] for layer in self.rig['layers']))
        self.assertEqual(package['poses']['ledge.peek']['hitRegionID'], 'habitat.ledge.peek')
        self.assertEqual(package['poses']['ledge.hang']['hitRegionID'], 'habitat.ledge.hang')

        for intent_id in intent_ids:
            intent = package['animationGraph']['intents'][intent_id]
            self.assertEqual(intent['clipIDs'], [intent_id])
            self.assertEqual(intent['fallbackIntentID'], 'ready')
            self.assertEqual(intent['reducedMotionIntentID'], 'ready')
            self.assertTrue(all(frame['rootOffsetPoints'] == {'x': 0, 'y': 0}
                                for frame in package['clips'][intent_id]['frames']))

        for clip_id in ('habitat.floorExit', 'habitat.ledgeExit'):
            clip = package['clips'][clip_id]
            self.assertEqual(clip['semanticEvents'], [
                {'id': 'fullyHidden', 'frameIndex': len(clip['frames']) - 1}
            ])
            self.assertEqual(clip['frames'][-1]['file'],
                             package['poses']['portal.hidden']['stillFrame'])
        for clip_id in intent_ids - {'habitat.floorExit', 'habitat.ledgeExit'}:
            self.assertFalse(any(event['id'] == 'fullyHidden'
                                 for event in package['clips'][clip_id]['semanticEvents']))

        habitat_resources = {name for name in files if name.startswith('habitats/')}
        self.assertEqual(len(habitat_resources), 149)
        self.assertEqual(len(files), 307)


if __name__ == '__main__':
    unittest.main()
