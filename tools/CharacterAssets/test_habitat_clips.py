import unittest
from pathlib import Path
import tempfile
import export_habitat_clips as habitat


class HabitatAuthoringTests(unittest.TestCase):
    def test_bounded_library(self):
        self.assertEqual(len(habitat.SPECS),7)
        self.assertEqual(sum(value[0] for value in habitat.SPECS.values()),160)

    def test_shared_visible_states_match_exact_parameters(self):
        states={}
        for clip,(count,start,end) in habitat.SPECS.items():
            for index,state in ((0,start),(count-1,end)):
                if state=='portal.hidden':continue
                pose,support=habitat.parameters(clip,index)
                self.assertIn(support,('feet','paws'))
                if state in states:self.assertEqual((pose,support),states[state])
                states[state]=(pose,support)

    def test_redirects_only_have_stable_support(self):
        for clip in habitat.SPECS:
            for marker in habitat.markers(clip):
                if marker['id']!='portalHidden':
                    self.assertIn(habitat.parameters(clip,marker['frameIndex'])[1],('feet','paws'))

    def test_pull_up_has_real_body_lift_under_fixed_paw_support(self):
        start,support=habitat.parameters('habitat.pullUp',0)
        end,last_support=habitat.parameters('habitat.pullUp',21)
        self.assertEqual(support,last_support)
        self.assertEqual(support,'paws')
        self.assertGreater(end['z']-start['z'],.2)
        for index in range(22):self.assertEqual(habitat.parameters('habitat.pullUp',index)[1],'paws')

    def test_portal_teleports_are_only_fully_hidden_boundaries(self):
        for clip,(_,start,end) in habitat.SPECS.items():
            if start=='portal.hidden' or end=='portal.hidden':self.assertIn(clip,habitat.PORTAL)

    def test_relocation_event_is_only_on_terminal_hidden_endpoints(self):
        for clip, (count, _, end) in habitat.SPECS.items():
            expected = ([{'frameIndex': count - 1, 'id': 'fullyHidden'}]
                        if end == 'portal.hidden' else [])
            actual = [event for event in habitat.semantic_events(clip)
                      if event['id'] == 'fullyHidden']
            self.assertEqual(actual, expected)

    def test_clipping_only_applies_inside_declared_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'frame.png'
            pixels=bytes((60,90,120,255))*habitat.PIXELS**2
            habitat.write_png(path,habitat.PIXELS,habitat.PIXELS,pixels)
            before=path.read_bytes()
            habitat.clip_portal(path,'habitat.peekIn',18)
            self.assertEqual(path.read_bytes(),before)
            habitat.clip_portal(path,'habitat.peekIn',0)
            image=habitat.read_rgba_png(path)
            alpha=image.pixels[3::4]
            self.assertFalse(any(alpha[:16*habitat.PIXELS]))
            self.assertTrue(all(value==255 for value in alpha[16*habitat.PIXELS:]))

    def test_support_art_is_absent_at_ready_and_hidden(self):
        for clip,(count,start,end) in habitat.SPECS.items():
            for index,state in ((0,start),(count-1,end)):
                if state in ('ready','portal.hidden'):
                    self.assertEqual(habitat.parameters(clip,index)[0]['ledge'],0)

    def test_driver_endpoint_snap_does_not_hide_fractional_animation_errors(self):
        self.assertEqual(habitat.blink_driver_error(1.,.9999734759),0)
        self.assertGreater(habitat.blink_driver_error(1.,.99),1e-5)
        self.assertGreater(habitat.blink_driver_error(.50002,.5),1e-5)

    @unittest.skipUnless((habitat.DESTINATION/'clips.json').exists(),'Habitat renders not exported yet')
    def test_real_art_support_hashes_and_occlusion_contract(self):
        result=habitat.verify()
        self.assertLess(result['maximumSupportDriftWorld'],2e-5)
        self.assertLess(result['compressedImageBytes'],18*1024*1024)


if __name__=='__main__':unittest.main()
