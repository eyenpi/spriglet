"""Stable candidates need an explicit local rehearsal, never implicit publication."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import package_preview as packaging


class PackagePreviewTests(unittest.TestCase):
    def test_stable_candidate_is_refused_without_explicit_rehearsal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "Sources/Spriglet/Resources/Changelog.json"
            feed.parent.mkdir(parents=True)
            feed.write_text(json.dumps({"releases": [{"channel": "stable", "appVersion": "0.3.1", "build": 6}]}))
            output = root / "packages"
            with patch.object(packaging.subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    packaging.main(["--app", str(root / "Spriglet.app"), "--output", str(output)], source_root=root)
                run.assert_not_called()
                self.assertFalse(output.exists())

    def test_preview_and_explicit_stable_rehearsal_use_only_local_unsigned_packaging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "Sources/Spriglet/Resources/Changelog.json"
            feed.parent.mkdir(parents=True)
            for channel, options in (("preview", []), ("stable", ["--rehearsal"])):
                with self.subTest(channel=channel):
                    feed.write_text(json.dumps({"releases": [{"channel": channel, "appVersion": "0.3.1", "build": 6}]}))
                    with patch.object(packaging.subprocess, "run") as run:
                        result = packaging.main(["--app", str(root / "Spriglet.app"), "--output", str(root / "packages"), *options], source_root=root)
                    self.assertEqual(result, 0)
                    run.assert_called_once()
                    command = run.call_args.args[0]
                    self.assertEqual(command[command.index("--mode") + 1], "local-preview")
                    self.assertNotIn("--identity", command)
                    self.assertNotIn("--notary-profile", command)


if __name__ == "__main__":
    unittest.main()
