import copy
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zlib
from unittest.mock import patch

import validate as store


class StoreValidationTests(unittest.TestCase):
    def setUp(self):
        self.metadata = json.loads((store.ROOT / "tools/AppStore/metadata/en-US.json").read_text())

    def test_metadata_rejects_unfinished_and_overlong_listing(self):
        for key, text in (("name", "x" * 31), ("keywords", "x" * 101),
                          ("description", "TODO"), ("supportURL", "https://example.com"),
                          ("privacyPolicyURL", "http://privacy.test"), ("price", "PAID")):
            with self.subTest(key=key):
                value = {**self.metadata, key: text}
                with self.assertRaises(store.release.ValidationError): store.validate_metadata(value)

    def test_support_contact_requires_the_selected_domain(self):
        for address in ("", "support", "support@another.example", " support@meetspriglet.com"):
            with self.subTest(address=address), self.assertRaises(store.release.ValidationError):
                store.validate_metadata({**self.metadata, "supportEmail": address})

    def test_keyword_byte_limit(self):
        with self.assertRaises(store.release.ValidationError):
            store.validate_metadata({**self.metadata, "keywords": "é" * 60})

    def test_privacy_audit_rejects_missing_reasons_and_collection(self):
        value = plistlib.loads((store.ROOT / "Sources/Spriglet/PrivacyInfo.xcprivacy").read_bytes())
        for mutate in (lambda v: v["NSPrivacyAccessedAPITypes"].pop(),
                       lambda v: v["NSPrivacyAccessedAPITypes"].append(v["NSPrivacyAccessedAPITypes"][0]),
                       lambda v: v.update(NSPrivacyTracking=True),
                       lambda v: v.update(NSPrivacyCollectedDataTypes=[{}])):
            bad = copy.deepcopy(value)
            mutate(bad)
            with self.assertRaises(store.release.ValidationError): store.validate_privacy(bad)

    def test_bundle_requires_category_and_encryption_declaration(self):
        value = plistlib.loads((store.ROOT / "Configuration/Info.plist").read_bytes())
        for key in ("LSApplicationCategoryType", "ITSAppUsesNonExemptEncryption", "LSUIElement"):
            bad = dict(value)
            del bad[key]
            with self.assertRaises(store.release.ValidationError): store.validate_store_info(bad)

    def test_source_rejects_stale_offline_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = ["Configuration/Info.plist", "Configuration/Spriglet.entitlements",
                     "Sources/Spriglet/PrivacyInfo.xcprivacy", "tools/AppStore/metadata/en-US.json",
                     "Sources/Spriglet/App/AppDocumentView.swift", "PRIVACY.md", "Sources/Spriglet/Resources/PrivacyPolicy.md"]
            for name in files:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((store.ROOT / name).read_bytes())
            (root / files[-1]).write_text("Old policy")
            with self.assertRaisesRegex(store.release.ValidationError, "Bundled document"):
                store.check_source(root)

    def test_screenshots_require_real_mac_dimensions_and_no_alpha(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(store.release.ValidationError): store.validate_screenshots(directory)
            for width, height, color in ((1440, 900, 6), (1920, 1080, 2)):
                # A structurally plausible header, but unsuitable for App Store screenshots.
                header = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                header += struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0) + b"\0" * 4
                (directory / "test.png").write_bytes(header)
                with self.assertRaises(store.release.ValidationError): store.validate_screenshots(directory)

    def test_signed_option_needs_an_archive(self):
        with patch("sys.argv", ["validate.py", "--signed"]): self.assertEqual(store.main(), 1)

    def test_screenshot_decode_rejects_a_truncated_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            header = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
            header += struct.pack(">IIBBBBB", 1440, 900, 8, 2, 0, 0, 0) + b"\0" * 4
            (directory / "broken.png").write_bytes(header)
            with self.assertRaises((store.release.ValidationError, subprocess.CalledProcessError)):
                store.validate_screenshots(directory)

    def test_valid_rgb_screenshot_and_count_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            def chunk(kind, data):
                return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
            header = struct.pack(">IIBBBBB", 1440, 900, 8, 2, 0, 0, 0)
            pixels = zlib.compress((b"\0" + b"\xff\xff\xff" * 1440) * 900)
            png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")
            (directory / "01.png").write_bytes(png)
            self.assertEqual(store.validate_screenshots(directory), 1)
            for index in range(2, 12): (directory / f"{index:02}.png").write_bytes(png)
            with self.assertRaisesRegex(store.release.ValidationError, "1–10"):
                store.validate_screenshots(directory)


if __name__ == "__main__": unittest.main()
