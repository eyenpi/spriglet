"""Silent structural/reproducibility checks for the original bundled cues."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from generate_chimes import create

HERE = Path(__file__).resolve().parent
RESOURCES = HERE.parents[1] / 'Sources/Spriglet/Resources/PetSounds'


class ChimeTests(unittest.TestCase):
    def test_bundled_cues_are_small_finite_uncompressed_pcm(self):
        provenance = json.loads((HERE / 'chime-provenance.json').read_text())
        self.assertEqual(len(provenance['assets']), 2)
        for expected in provenance['assets']:
            with self.subTest(file=expected['file']):
                path = RESOURCES / expected['file']
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected['sha256'])
                with wave.open(str(path), 'rb') as audio:
                    self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()), (1, 2, 48_000, 'NONE'))
                    self.assertEqual(audio.getnframes(), expected['frames'])
                    self.assertLessEqual(audio.getnframes() / audio.getframerate(), 1)
                    data = audio.readframes(audio.getnframes())
                samples = [s[0] for s in struct.iter_unpack('<h', data)]
                peak = max(abs(sample) for sample in samples)
                self.assertEqual(peak, expected['maximumAbsoluteSample'])
                self.assertGreater(peak, 0)
                self.assertLessEqual(peak / 32767, 0.101)
                self.assertEqual(samples[0], 0)
                self.assertTrue(all(sample == 0 for sample in samples[-240:]))
                self.assertLess(len(path.read_bytes()), 65_536)

    def test_generator_reproduces_the_exact_bundled_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            generated = create(Path(directory))
            for item in generated:
                self.assertEqual((Path(directory) / item['file']).read_bytes(), (RESOURCES / item['file']).read_bytes())


if __name__ == '__main__':
    unittest.main()
