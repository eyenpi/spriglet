"""Regression checks for physical-layer export and honest boundary evidence."""
from pathlib import Path
import tempfile
import unittest

import export_rest_rig as export


class RestRigExportTests(unittest.TestCase):
    def image(self, width, height, pixels):
        return export.RGBAImage(width, height, bytes(pixels), '', ())

    def test_transparent_crop_keeps_alignment_and_antialiasing(self):
        pixels = bytearray(12 * 12 * 4)
        pixels[(6 * 12 + 7) * 4:(6 * 12 + 7) * 4 + 4] = bytes((100, 80, 50, 127))
        frame, cropped = export.crop_image(self.image(12, 12, pixels))
        self.assertEqual(frame, {'x': 5, 'y': 4, 'width': 5, 'height': 5})
        restored = export.composite([(self.image(5, 5, cropped), frame)], 12)
        self.assertEqual(restored, bytes(pixels))

    def test_empty_layer_rejected(self):
        with self.assertRaises(ValueError):
            export.crop_image(self.image(1, 1, [0, 0, 0, 0]))

    def test_source_over_preserves_opaque_foreground_without_double_image(self):
        red = self.image(1, 1, [255, 0, 0, 255])
        green = self.image(1, 1, [0, 255, 0, 255])
        self.assertEqual(export.composite([(red, {'x': 0, 'y': 0}), (green, {'x': 0, 'y': 0})], 1), bytes([0, 255, 0, 255]))

    def test_png_roundtrip_keeps_unassociated_alpha(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'pixel.png'
            pixels = bytes([230, 40, 80, 64, 15, 20, 30, 255])
            export.write_png(path, 2, 1, pixels)
            self.assertEqual(export.read_rgba_png(path).pixels, pixels)

    def test_real_layers_exactly_recompose_their_new_canonical(self):
        rig = export.verify()
        self.assertLess(rig['decodedLayerBytes'] + rig['decodedMaskBytes'], 1024 * 1024)
        self.assertFalse(rig['boundaryVerification']['productionHandoffApproved'])
        self.assertFalse(rig['boundaryVerification']['legacyExact'])
        self.assertFalse(rig['channels']['bodyBreath']['repeats'])
        self.assertFalse(rig['channels']['blink']['repeats'])

    def test_blink_states_change_actual_authored_eye_shape(self):
        rig = export.verify()
        layers = {layer['id']: layer for layer in rig['layers']}
        for side in ('left', 'right'):
            keys = ['eye.' + side] + [f'blink.{side}.{amount}' for amount in ('0.35', '0.7', '1')]
            self.assertEqual(len({layers[key]['decodedSHA256'] for key in keys}), 4)
            open_eye = export.read_rgba_png(export.DESTINATION / layers[keys[0]]['file'])
            closed_eye = export.read_rgba_png(export.DESTINATION / layers[keys[-1]]['file'])
            self.assertLess(sum(closed_eye.pixels[3::4]), sum(open_eye.pixels[3::4]) / 2)

    def test_clean_face_has_no_baked_dark_open_eye_under_blink(self):
        rig = export.verify()
        layers = {layer['id']: layer for layer in rig['layers']}
        body = layers['body']
        image = export.read_rgba_png(export.DESTINATION / body['file'])
        for side in ('left', 'right'):
            frame = layers['eye.' + side]['framePixels']
            x = frame['x'] + frame['width'] // 2 - body['framePixels']['x']
            y = frame['y'] + frame['height'] // 2 - body['framePixels']['y']
            pixel = image.pixels[(y * image.width + x) * 4:(y * image.width + x) * 4 + 4]
            self.assertGreater(min(pixel[:3]), 100, 'Open-eye shadow was baked into exposed skin')


if __name__ == '__main__':
    unittest.main()
