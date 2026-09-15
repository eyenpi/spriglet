"""Regression cases for the candidate contact and endpoint measurements."""

import math
import unittest

from verify_assets import boundary_errors, measure_contacts, pose_distance


def sample(x=0., z=0., *, planted=True, intended=None):
    point = [x, 0., z]
    return {'feet': {'Foot.L': {'planted': planted, 'evaluatedWorld': point,
                               'world': point if intended is None else intended}}}


class ContactTests(unittest.TestCase):
    def test_stationary_sole(self):
        result = measure_contacts([sample(), sample(), sample()])
        self.assertEqual(result['maximumPlantedDriftWorld'], 0)
        self.assertEqual(result['plantedFrameCoverage'], {'Foot.L': 3})

    def test_matching_intent_does_not_hide_sliding(self):
        result = measure_contacts([sample(), sample(x=.05)])
        self.assertEqual(result['maximumEvaluatedRigErrorWorld'], 0)
        self.assertAlmostEqual(result['maximumPlantedDriftWorld'], .05)

    def test_flight_breaks_stance_interval(self):
        result = measure_contacts([sample(), sample(x=.1, z=.2, planted=False), sample(x=.3), sample(x=.3)])
        self.assertEqual(result['maximumPlantedDriftWorld'], 0)
        self.assertEqual(result['maximumGroundErrorWorld'], 0)

    def test_actual_rig_is_checked_not_just_expected(self):
        result = measure_contacts([sample(x=.04, intended=[0., 0., 0.])])
        self.assertAlmostEqual(result['maximumEvaluatedRigErrorWorld'], .04)

    def test_both_floating_and_sunken_feet_fail(self):
        for z in (-.02, .02):
            self.assertAlmostEqual(measure_contacts([sample(z=z)])['maximumGroundErrorWorld'], .02)

    def test_nonfinite_measurement_is_not_a_zero_error(self):
        for value in (math.inf, -math.inf, math.nan):
            with self.assertRaises(ValueError):
                measure_contacts([sample(x=value)])


class EndpointTests(unittest.TestCase):
    def test_matching_body_cannot_hide_facial_snap(self):
        rest = {'inPlacePose': {'Body': [0, 1]}, 'expression': {'Blink': 0., 'Happy': 0.}}
        wrong = {**rest, 'expression': {'Blink': 1., 'Happy': 0.}}
        result = boundary_errors(wrong, rest)
        self.assertEqual(result['pose'], 0)
        self.assertEqual(result['expression'], 1)

    def test_missing_facial_control_is_not_a_match(self):
        rest = {'inPlacePose': {'Body': [0, 1]}, 'expression': {'Blink': 0., 'Happy': 0.}}
        self.assertTrue(math.isinf(boundary_errors({**rest, 'expression': {'Happy': 0.}}, rest)['expression']))

    def test_nonfinite_facial_value_is_not_a_match(self):
        rest = {'inPlacePose': {'Body': [0, 1]}, 'expression': {'Blink': 0.}}
        self.assertTrue(math.isinf(boundary_errors({**rest, 'expression': {'Blink': math.nan}}, rest)['expression']))

    def test_matching_poses(self):
        self.assertEqual(pose_distance({'Body': [0, 1]}, {'Body': [0, 1]}), 0)

    def test_missing_control_is_not_a_match(self):
        self.assertTrue(math.isinf(pose_distance({'Body': [0]}, {'Head': [0]})))

    def test_truncated_matrix_is_not_a_match(self):
        self.assertTrue(math.isinf(pose_distance({'Body': [0, 1]}, {'Body': [0]})))

    def test_changed_pose_is_measured(self):
        self.assertAlmostEqual(pose_distance({'Body': [0, 1]}, {'Body': [.1, 1]}), .1)

    def test_nan_is_not_a_match(self):
        self.assertTrue(math.isinf(pose_distance({'Body': [0]}, {'Body': [math.nan]})))


if __name__ == '__main__':
    unittest.main()
