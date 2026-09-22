import math
import unittest
import export_reactive_clips as reactive


class ReactiveAuthoringTests(unittest.TestCase):
    def test_all_shared_endpoints_have_identical_parameters_except_root(self):
        poses={}
        for clip,(count,start,end) in reactive.SPECS.items():
            for index,name in ((0,start),(count-1,end)):
                pose,planted=reactive.parameters(clip,index)
                pose.pop('travel')
                self.assertTrue(planted)
                if name in poses:
                    self.assertEqual(pose,poses[name])
                poses[name]=pose

    def test_planted_feet_never_translate(self):
        for clip,(count,_,_) in reactive.SPECS.items():
            previous=None
            for index in range(count):
                pose,planted=reactive.parameters(clip,index)
                if planted:
                    if previous is not None:
                        self.assertEqual(pose['travel'],previous)
                    self.assertAlmostEqual(pose['lift'],0,places=12)
                    previous=pose['travel']
                else:
                    self.assertGreater(pose['lift'],0)
                    previous=None

    def test_markers_do_not_authorize_airborne_redirect(self):
        for clip in reactive.SPECS:
            for marker in reactive.markers(clip):
                self.assertTrue(reactive.parameters(clip,marker['frameIndex'])[1])

    def test_hop_is_shorter_and_lower_than_legacy_travel(self):
        for side,sign in (('left',-1),('right',1)):
            clip='reactive.hop.'+side
            count=reactive.SPECS[clip][0]
            poses=[reactive.parameters(clip,i)[0] for i in range(count)]
            self.assertEqual(poses[-1]['travel'],sign*1.25)
            self.assertLess(max(pose['lift'] for pose in poses),.25)
            self.assertGreater(max(pose['lift'] for pose in poses),.20)
            self.assertTrue(all(math.isfinite(v) for p in poses for v in p.values()))

    def test_turn_faces_the_direction_of_travel(self):
        for side,sign in (('left',-1),('right',1)):
            pose=reactive.canonical_pose('directed.'+side)
            self.assertGreater(sign*pose['bodyYaw'],0)
            self.assertGreater(sign*pose['bodyLean'],0)

    def test_library_has_ten_authored_clips_and_156_references(self):
        self.assertEqual(len(reactive.SPECS),10)
        self.assertEqual(sum(value[0] for value in reactive.SPECS.values()),156)

    def test_prelaunch_cancellation_is_grounded_and_returns_ready(self):
        for clip in ('reactive.dismiss','reactive.abort.left','reactive.abort.right'):
            count,_,end=reactive.SPECS[clip]
            self.assertEqual(end,'ready')
            for index in range(count):
                pose,planted=reactive.parameters(clip,index)
                self.assertTrue(planted)
                self.assertEqual(pose['travel'],0)
                self.assertEqual(pose['lift'],0)

    @unittest.skipUnless((reactive.DESTINATION/'clips.json').exists(),'Blender art export not yet rendered')
    def test_exported_grounding_transparency_and_shared_pose_contract(self):
        report=reactive.verify()
        self.assertLess(report['maximumPlantedDriftWorld'],2e-5)
        self.assertLess(report['uniqueImages'],report['frames'])


if __name__ == '__main__':
    unittest.main()
