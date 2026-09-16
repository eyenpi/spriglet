"""Focused safety/packaging regressions. No app, signing, or network calls."""

import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_validation as release


class ReleaseValidationTests(unittest.TestCase):
    def test_debug_entitlement_is_rejected_even_if_false(self):
        for key in ("com.apple.security.get-task-allow", "get-task-allow"):
            for value in (True, False, "true", 1):
                with self.subTest(key=key, value=value), self.assertRaises(release.ValidationError):
                    release.validate_entitlements({"com.apple.security.app-sandbox": True, key: value})

    def test_sandbox_and_reviewed_capabilities_are_required(self):
        release.validate_entitlements({"com.apple.security.app-sandbox": True})
        for value in ({}, {"com.apple.security.app-sandbox": False},
                      {"com.apple.security.app-sandbox": True, "com.apple.security.cs.disable-library-validation": True}):
            with self.assertRaises(release.ValidationError):
                release.validate_entitlements(value)

    def test_version_build_bundle_and_minimum_os_must_match(self):
        info = {"CFBundleIdentifier": "dev.spriglet.app", "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "2", "CFBundleExecutable": "Spriglet", "CFBundlePackageType": "APPL",
                "LSMinimumSystemVersion": "26.0"}
        release.validate_info(info, "0.1.0", "2", "dev.spriglet.app")
        for key in info:
            with self.subTest(key=key), self.assertRaises(release.ValidationError):
                release.validate_info(dict(info, **{key: "wrong"}), "0.1.0", "2", "dev.spriglet.app")

    def test_prepare_overrides_hardcoded_source_metadata_without_changing_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            configuration = root / "Configuration"
            configuration.mkdir()
            source_info = {"CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
                           "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"}
            (configuration / "Info.plist").write_bytes(plistlib.dumps(source_info))
            (configuration / "Spriglet.entitlements").write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
            output = root / "work"
            output.mkdir()
            release.prepare(argparse.Namespace(source_root=root, output=output, version="0.2.0", build="3", bundle_id="dev.spriglet.app"))
            self.assertEqual(release.read_plist(configuration / "Info.plist"), source_info)
            self.assertEqual(release.read_plist(output / "Info.plist"),
                             {"CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "3", "CFBundleIdentifier": "dev.spriglet.app"})

    def test_developer_id_requires_runtime_timestamp_and_team(self):
        valid = "CodeDirectory flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture (ABC1234567)\nTimestamp=13 Sep 2026\nTeamIdentifier=ABC1234567\n"
        entitlements = {"com.apple.security.app-sandbox": True}
        release.validate_signature_details(valid, entitlements, "developer-id")
        for part in ("runtime", "Authority=Developer ID Application:", "Timestamp=", "TeamIdentifier="):
            with self.subTest(part=part), self.assertRaises(release.ValidationError):
                release.validate_signature_details(valid.replace(part, "missing"), entitlements, "developer-id")
        with self.assertRaises(release.ValidationError):
            release.validate_signature_details(valid + "Signature=adhoc\n", entitlements, "developer-id")

    def test_local_mode_is_explicitly_adhoc(self):
        entitlements = {"com.apple.security.app-sandbox": True}
        release.validate_signature_details("CodeDirectory flags=0x10002(adhoc,runtime)\nSignature=adhoc\n", entitlements, "local-preview")
        with self.assertRaises(release.ValidationError):
            release.validate_signature_details("CodeDirectory flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture\n", entitlements, "local-preview")

    def test_unsafe_or_escaping_resource_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "assets"
            root.mkdir()
            for name in ("../outside.png", "/outside.png", "a//b.png", "a/./b.png", "a\\b.png", "https:asset.png", "asset.jpg"):
                with self.subTest(name=name), self.assertRaises(release.ValidationError):
                    release.resource_path(root, name)
            (root / "linked.png").symlink_to(Path(directory) / "outside.png")
            with self.assertRaises(release.ValidationError):
                release.resource_path(root, "linked.png")

    def test_resource_inventory_and_bytes_are_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/Spriglet/Resources/AcornHopper"
            app = root / "Spriglet.app"
            destination = app / "Contents/Resources/AcornHopper"
            clips = ("idle", "walkLeft", "walkRight", "pet", "settle", "fallAsleep", "wakeUp")
            names = {"rest.png", "sleep.png"} | {name + ".png" for name in clips}
            metadata = {"schemaVersion": 2, "canvasPixels": {"width": 448, "height": 448},
                        "displaySizePoints": {"width": 96, "height": 96},
                        "restFrame": "rest.png", "sleepFrame": "sleep.png",
                        "clips": {name: {"frames": [{"file": name + ".png"}]} for name in clips}}
            png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 448, 448)
            for folder in (source, destination):
                folder.mkdir(parents=True)
                (folder / "manifest.json").write_text(json.dumps(metadata))
                for name in names:
                    (folder / name).write_bytes(png)
            privacy = plistlib.dumps({"NSPrivacyTracking": False})
            (root / "Sources/Spriglet/PrivacyInfo.xcprivacy").write_bytes(privacy)
            (app / "Contents/Resources/PrivacyInfo.xcprivacy").write_bytes(privacy)
            self.assertEqual(release.verify_resources(app, root)["pngCount"], 9)
            excluded = app / "Contents/Resources/SproutSample"
            excluded.mkdir()
            with self.assertRaises(release.ValidationError):
                release.verify_resources(app, root)
            excluded.rmdir()
            (destination / "rest.png").write_bytes(png + b"changed")
            with self.assertRaises(release.ValidationError):
                release.verify_resources(app, root)
            (destination / "rest.png").write_bytes(png)
            (destination / "unreferenced.png").write_bytes(png)
            with self.assertRaises(release.ValidationError):
                release.verify_resources(app, root)
            (destination / "unreferenced.png").unlink()
            (destination / "sleep.png").unlink()
            with self.assertRaises(OSError):
                release.verify_resources(app, root)

    def test_layered_inventory_tracks_crops_masks_and_shared_frames(self):
        package = {"schemaVersion": 3, "canvasPixels": {"width": 448, "height": 448},
                   "poses": {"ready": {"stillFrame": "ready.png"}},
                   "clips": {"blink": {"frames": [{"file": "ready.png"}]}},
                   "layers": {"eye": {"file": "eye.png", "framePixels": {"width": 18, "height": 22},
                                      "mask": {"file": "eye.mask.png"}}}}
        self.assertEqual(release.character_image_inventory(package),
                         {"ready.png": (448, 448), "eye.png": (18, 22), "eye.mask.png": (18, 22)})
        package["layers"]["eye"]["file"] = "ready.png"
        with self.assertRaises(release.ValidationError):
            release.character_image_inventory(package)
        package["layers"]["eye"]["file"] = "eye.png"
        for width in (0, 2049, 18.5, True):
            package["layers"]["eye"]["framePixels"]["width"] = width
            with self.assertRaises(release.ValidationError):
                release.character_image_inventory(package)

    def test_architecture_and_macho_minimum_os_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Spriglet.app"
            binary = app / "Contents/MacOS/Spriglet"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + bytes(28))
            binary.chmod(0o755)
            for architecture, minimum_os, valid in ((b"arm64\n", b"26.0", True),
                                                    (b"x86_64\n", b"26.0", False),
                                                    (b"arm64 x86_64\n", b"26.0", False),
                                                    (b"arm64\n", b"15.0", False)):
                with patch.object(release, "run", side_effect=[architecture, b"platform MACOS\nminos " + minimum_os + b"\n"]):
                    if valid:
                        self.assertEqual(release.verify_code_inventory(app), ["arm64"])
                    else:
                        with self.assertRaises(release.ValidationError):
                            release.verify_code_inventory(app)

    def test_additional_code_requires_explicit_signing_review(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Spriglet.app"
            binary = app / "Contents/MacOS/Spriglet"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + bytes(28))
            binary.chmod(0o755)
            helper = binary.parent / "helper"
            helper.write_bytes(b"#!/bin/sh\n")
            with self.assertRaises(release.ValidationError):
                release.verify_code_inventory(app)
            helper.unlink()
            unexpected = app / "Contents/Resources/hidden-code"
            unexpected.parent.mkdir()
            unexpected.write_bytes(binary.read_bytes())
            with self.assertRaises(release.ValidationError):
                release.verify_code_inventory(app)

    def test_notary_failure_does_not_retain_credentials_or_raw_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "notarization.json"
            args = argparse.Namespace(zip=Path("fixture.zip"), profile="fixture-profile", output=output)
            response = subprocess.CompletedProcess([], 1, stdout=b'{"status":"Invalid","id":"12345678-1234-1234-1234-123456789abc","account":"private@example.invalid"}',
                                                   stderr=b"temporary-authenticated-upload-url-and-private-data")
            with patch.object(release.subprocess, "run", return_value=response), self.assertRaises(release.ValidationError):
                release.notarize(args)
            saved = output.read_text()
            self.assertNotIn("private", saved)
            self.assertNotIn("fixture-profile", saved)
            self.assertEqual(json.loads(saved)["status"], "Invalid")

    def test_notary_requires_accepted_status_and_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "notarization.json"
            args = argparse.Namespace(zip=Path("fixture.zip"), profile="fixture-profile", output=output)
            for status, returncode, should_pass in (("Accepted", 0, True), ("In Progress", 0, False), ("Accepted", 1, False), ("unknown", 0, False)):
                response = subprocess.CompletedProcess([], returncode, stdout=json.dumps({"status": status}).encode(), stderr=b"")
                with patch.object(release.subprocess, "run", return_value=response):
                    if should_pass:
                        release.notarize(args)
                    else:
                        with self.assertRaises(release.ValidationError):
                            release.notarize(args)


if __name__ == "__main__":
    unittest.main()
