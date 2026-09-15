import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import export_acorn


class AcornExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = json.loads((export_acorn.SOURCE / 'manifest.json').read_text())

    def test_only_point_geometry_changes(self):
        before = copy.deepcopy(self.source)
        packaged = export_acorn.packaged_manifest(self.source)
        self.assertEqual(self.source, before)
        self.assertEqual(packaged['displaySizePoints'], {'width': 96, 'height': 96})
        packaged['displaySizePoints'] = before['displaySizePoints']
        for name, clip in packaged['clips'].items():
            for index, frame in enumerate(clip['frames']):
                original = before['clips'][name]['frames'][index]['rootOffsetPoints']
                for axis, value in frame['rootOffsetPoints'].items():
                    self.assertAlmostEqual(value, original[axis] * 96 / 224)
                frame['rootOffsetPoints'] = original
        self.assertEqual(packaged, before)

    def test_shipping_pngs_are_exact(self):
        self.assertEqual(export_acorn.verify(), 194)

    def test_unknown_source_contract_is_rejected(self):
        for key, value in [('schemaVersion', 1), ('displaySizePoints', {'width': 96, 'height': 96})]:
            invalid = copy.deepcopy(self.source)
            invalid[key] = value
            with self.assertRaises(AssertionError):
                export_acorn.packaged_manifest(invalid)

    def test_verifier_rejects_extra_and_changed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'AcornHopper'
            shutil.copytree(export_acorn.DESTINATION, destination)
            extra = destination / 'unused.txt'
            extra.write_text('not a shipping asset')
            with self.assertRaises(AssertionError):
                export_acorn.verify(destination)
            extra.unlink()
            (destination / self.source['restFrame']).write_bytes(b'changed')
            with self.assertRaises(AssertionError):
                export_acorn.verify(destination)


if __name__ == '__main__':
    unittest.main()
