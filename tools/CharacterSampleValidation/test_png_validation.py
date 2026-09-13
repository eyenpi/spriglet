import struct
import tempfile
import unittest
from pathlib import Path
import zlib

from png_validation import PNGError, RGBAImage, alpha_measurements, read_rgba_png
from validate_assets import hit_test_probes


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def png(scanlines):
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))


class PNGValidationTests(unittest.TestCase):
    # Independently calculated filtered bytes for the same known two-row image.
    expected = bytes([10, 20, 30, 0, 100, 110, 120, 128, 12, 25, 31, 255, 90, 100, 120, 255])
    rows = [
        ([10, 20, 30, 0, 100, 110, 120, 128], [12, 25, 31, 255, 90, 100, 120, 255]),
        ([10, 20, 30, 0, 90, 90, 90, 128], [12, 25, 31, 255, 78, 75, 89, 0]),
        ([10, 20, 30, 0, 100, 110, 120, 128], [2, 5, 1, 255, 246, 246, 0, 127]),
        ([10, 20, 30, 0, 95, 100, 105, 128], [7, 15, 16, 255, 34, 33, 45, 64]),
        ([10, 20, 30, 0, 90, 90, 90, 128], [2, 5, 1, 255, 246, 246, 0, 0]),
    ]

    def read(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "known.png"
            path.write_bytes(data)
            return read_rgba_png(path, (2, 2))

    def test_all_five_filters_recover_known_color_and_alpha_bytes(self):
        for filter_id, (first, second) in enumerate(self.rows):
            with self.subTest(filter=filter_id):
                image = self.read(png(bytes([filter_id] + first + [filter_id] + second)))
                self.assertEqual(image.pixels, self.expected)

    def test_alpha_measurement_distinguishes_clear_partial_and_opaque(self):
        image = self.read(png(bytes([0] + self.rows[0][0] + [0] + self.rows[0][1])))
        measurement = alpha_measurements(image)
        self.assertEqual(measurement["transparentPixels"], 1)
        self.assertEqual(measurement["partialAlphaPixels"], 1)
        self.assertEqual(measurement["opaquePixels"], 2)
        self.assertEqual(measurement["maximumBorderAlpha"], 255)

    def test_crc_corruption_is_rejected(self):
        data = bytearray(png(bytes([0] + self.rows[0][0] + [0] + self.rows[0][1])))
        data[-1] ^= 1
        with self.assertRaisesRegex(PNGError, "CRC"):
            self.read(bytes(data))

    def test_truncated_and_extra_scanlines_are_rejected(self):
        valid = bytes([0] + self.rows[0][0] + [0] + self.rows[0][1])
        for stream in (valid[:-1], valid + b"\x00"):
            with self.assertRaisesRegex(PNGError, "scanline"):
                self.read(png(stream))

    def test_trailing_bytes_are_rejected(self):
        valid = png(bytes([0] + self.rows[0][0] + [0] + self.rows[0][1]))
        with self.assertRaisesRegex(PNGError, "trailing"):
            self.read(valid + b"extra")

    def test_hit_probes_distinguish_vertical_orientation(self):
        pixels = bytearray(64 * 64 * 4)
        for y in range(8, 27):
            for x in range(20, 41):
                pixels[(y * 64 + x) * 4:(y * 64 + x) * 4 + 4] = bytes([80, 100, 30, 255])
        image = RGBAImage(64, 64, bytes(pixels), "synthetic", ())
        probes = hit_test_probes(image)
        self.assertEqual(len(probes), 3)
        for probe in probes:
            x = int(probe["normalizedBottomLeft"]["x"] * 64)
            y = int((1 - probe["normalizedBottomLeft"]["y"]) * 64)
            alpha = pixels[(y * 64 + x) * 4 + 3]
            self.assertEqual(alpha > 224, probe["expectedHit"])


if __name__ == "__main__":
    unittest.main()
