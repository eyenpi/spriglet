"""Installation layout checks without mounting or changing a real disk."""

from pathlib import Path
import tempfile
import unittest

from disk_image import check_layout
from release_validation import ValidationError


class DiskImageLayoutTests(unittest.TestCase):
    def test_installable_layout_and_unexpected_content(self):
        with tempfile.TemporaryDirectory() as directory:
            mount = Path(directory)
            (mount / "Spriglet.app").mkdir()
            (mount / "README.txt").write_text("Install instructions")
            shortcut = mount / "Applications"
            shortcut.symlink_to("/Applications")
            check_layout(mount)
            (mount / "private.log").write_text("local")
            with self.assertRaisesRegex(ValidationError, "Unexpected"):
                check_layout(mount)
            (mount / "private.log").unlink()
            shortcut.unlink()
            shortcut.symlink_to("/tmp")
            with self.assertRaisesRegex(ValidationError, "shortcut"):
                check_layout(mount)
            shortcut.unlink()
            shortcut.mkdir()
            with self.assertRaisesRegex(ValidationError, "shortcut"):
                check_layout(mount)
