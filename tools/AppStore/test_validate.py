import copy
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from unittest.mock import patch

import validate as store


class StoreValidationTests(unittest.TestCase):
    def setUp(self):
        self.metadata = json.loads((store.ROOT / "tools/AppStore/metadata/en-US.json").read_text())

    def test_preflight_stdout_remains_machine_readable_json(self):
        result = subprocess.run([sys.executable, str(store.ROOT / "tools/AppStore/validate.py")], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["metadataLocale"], "en-US")

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
                     "Sources/Spriglet/App/SharedContent.generated.swift", "PRIVACY.md", "Sources/Spriglet/Resources/PrivacyPolicy.md"]
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

    def test_signature_checks_selected_team_and_distribution_certificate(self):
        entitlements = {"com.apple.security.app-sandbox": True}
        development = "Authority=Apple Development: Example\nTeamIdentifier=ABCDEFGHIJ\n"
        distribution = development.replace("Apple Development", "Apple Distribution")
        store.validate_signature(development, entitlements, "ABCDEFGHIJ")
        store.validate_signature(distribution, entitlements, "ABCDEFGHIJ", distribution=True)
        for details, values, team, exported in (
            (development, entitlements, "ABCDEFGHIJ", True),
            (distribution, entitlements, "ZZZZZZZZZZ", True),
            ("Signature=adhoc\nTeamIdentifier=ABCDEFGHIJ\n", entitlements, None, False),
            (distribution, {**entitlements, "com.apple.security.get-task-allow": True}, None, True),
            (distribution, {}, None, True),
            (distribution.replace("Apple Distribution", "Developer ID Application"), entitlements, None, True),
        ):
            with self.subTest(details=details, team=team, entitlements=values), self.assertRaises(store.release.ValidationError):
                store.validate_signature(details, values, team, exported)

    def test_bundle_checksum_detects_resource_edits_and_renames(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            first = app / "Support.md"
            first.write_text("Current build instructions")
            original = store.bundle_digest(app)
            first.write_text("Stale build instructions")
            self.assertNotEqual(original, store.bundle_digest(app))
            first.write_text("Current build instructions")
            first.rename(app / "PrivacyPolicy.md")
            self.assertNotEqual(original, store.bundle_digest(app))
            (app / "linked-resource").symlink_to(app / "PrivacyPolicy.md")
            with self.assertRaises(store.release.ValidationError): store.bundle_digest(app)

    def test_root_owned_installation_requires_readable_resources_and_executable_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Spriglet.app"
            executable = app / "Contents/MacOS/Spriglet"
            resource = app / "Contents/Resources/Support.md"
            for path in (executable, resource):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("Installed payload")
                path.chmod(0o644)
            for path in (app, *app.rglob("*")):
                if path.is_dir(): path.chmod(0o755)
            executable.chmod(0o755)
            store.validate_bundle_permissions(app)
            for path, mode in ((app, 0o700), (resource, 0o600),
                               (resource, 0o640), (resource.parent, 0o744),
                               (executable, 0o744)):
                with self.subTest(path=path.relative_to(app), mode=oct(mode)):
                    original = path.stat().st_mode & 0o777
                    path.chmod(mode)
                    try:
                        with self.assertRaises(store.release.ValidationError):
                            store.validate_bundle_permissions(app)
                    finally:
                        path.chmod(original)
            link = resource.parent / "linked-document"
            link.symlink_to(resource)
            with self.assertRaisesRegex(store.release.ValidationError, "Unexpected link"):
                store.validate_bundle_permissions(app)

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
