import json
from pathlib import Path
import shutil
import tempfile
import unittest

import sync


class SharedContentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(sync.ROOT / "Configuration/Shared", self.root / "Configuration/Shared")
        shutil.copy(sync.ROOT / "LICENSE", self.root / "LICENSE")
        self.icon_root = Path("Sources/Spriglet/Assets.xcassets/AppIcon.appiconset")
        shutil.copytree(sync.ROOT / self.icon_root, self.root / self.icon_root)
        sync.synchronize(self.root)

    def text(self, path): return (self.root / path).read_text()

    def test_policy_edit_reaches_app_repository_and_website(self):
        source = self.root / "Configuration/Shared/privacy.md"
        source.write_text(source.read_text() + "\nShared privacy update for {{appName}}.\n")
        with self.assertRaisesRegex(ValueError, "Stale shared content"):
            sync.synchronize(self.root, check=True)
        sync.synchronize(self.root)
        for path in ("PRIVACY.md", "Sources/Spriglet/Resources/PrivacyPolicy.md", "tools/AppStore/website/public/privacy.html"):
            self.assertIn("Shared privacy update for Spriglet.", self.text(path))

    def test_support_and_action_label_edit_reaches_both_surfaces(self):
        source = self.root / "Configuration/Shared/en-US.json"
        labels = json.loads(source.read_text())
        labels["playWithFirefly"] = "Play with a Glow"
        source.write_text(json.dumps(labels))
        sync.synchronize(self.root)
        for path in ("Sources/Spriglet/App/SharedContent.generated.swift", "Sources/Spriglet/Resources/Support.md",
                     "tools/AppStore/website/public/support.html", "tools/AppStore/metadata/en-US.json"):
            self.assertIn("Play with a Glow", self.text(path))
            self.assertNotIn("Play with Firefly", self.text(path))

    def test_contact_change_reaches_all_published_outputs(self):
        source = self.root / "Configuration/Shared/brand.json"
        brand = json.loads(source.read_text())
        brand.update(websiteURL="https://companion.example", supportEmail="help@companion.example")
        source.write_text(json.dumps(brand))
        sync.synchronize(self.root)
        for path in ("Sources/Spriglet/App/SharedContent.generated.swift", "PRIVACY.md", "Sources/Spriglet/Resources/Support.md",
                     "tools/AppStore/metadata/en-US.json", "tools/AppStore/website/public/privacy.html", "tools/AppStore/website/public/support.html"):
            self.assertIn("help@companion.example", self.text(path))
            self.assertNotIn("meetspriglet.com", self.text(path))
        self.assertIn('"pattern": "companion.example"', self.text("tools/AppStore/website/wrangler.jsonc"))

    def test_logo_follows_catalog_filename_and_bytes(self):
        catalog = self.root / self.icon_root / "Contents.json"
        value = json.loads(catalog.read_text())
        slot = next(i for i in value["images"] if i["size"] == "128x128" and i["scale"] == "1x")
        data = (self.root / self.icon_root / slot["filename"]).read_bytes()
        slot["filename"] = "replacement.png"
        (catalog.parent / slot["filename"]).write_bytes(data + b"fixture-change")
        catalog.write_text(json.dumps(value))
        sync.synchronize(self.root)
        self.assertEqual((self.root / "tools/AppStore/website/public/spriglet.png").read_bytes(), data + b"fixture-change")

    def test_bad_token_fails_before_writing_outputs(self):
        source = self.root / "Configuration/Shared/support.md"
        before = self.text("Sources/Spriglet/Resources/Support.md")
        source.write_text(source.read_text() + "{{misspelledEmail}}")
        with self.assertRaisesRegex(ValueError, "Unknown shared content token"):
            sync.synchronize(self.root)
        self.assertEqual(before, self.text("Sources/Spriglet/Resources/Support.md"))

    def test_unchanged_generation_preserves_timestamps_and_check_does_not_repair(self):
        path = self.root / "Sources/Spriglet/App/SharedContent.generated.swift"
        timestamp = path.stat().st_mtime_ns
        self.assertEqual(sync.synchronize(self.root), [])
        self.assertEqual(path.stat().st_mtime_ns, timestamp)
        path.write_text("stale")
        with self.assertRaises(ValueError): sync.synchronize(self.root, check=True)
        self.assertEqual(path.read_text(), "stale")

    def test_xcode_declares_every_generated_output(self):
        declared = (sync.ROOT / "Configuration/SharedContent.outputs.xcfilelist").read_text().splitlines()
        self.assertEqual(set(declared), {"$(SRCROOT)/" + name for name in sync.output_files()})
        inputs = (sync.ROOT / "Configuration/SharedContent.inputs.xcfilelist").read_text().splitlines()
        for path in (sync.ROOT / "Configuration/Shared").iterdir():
            self.assertIn("$(SRCROOT)/" + str(path.relative_to(sync.ROOT)), inputs)


if __name__ == "__main__": unittest.main()
