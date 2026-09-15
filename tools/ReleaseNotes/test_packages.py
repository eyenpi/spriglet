"""Prevent wrong, modified or unsigned stable binaries from reaching releases."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import release_notes as release


class PackagePublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.commit = "a" * 40
        self.entry = {"appVersion": "0.2.0", "build": 4, "channel": "preview"}
        self.data = {"sourceRevision": self.commit, "sourceWorkingTreeDirty": False,
                     "version": "0.2.0", "build": "4", "bundleIdentifier": "dev.spriglet.app",
                     "architectures": ["arm64"], "minimumMacOS": "26.0", "diskImageVerified": True,
                     "signature": "local-preview", "notarizationTicketValidated": False,
                     "systemPolicyPassed": False, "artifacts": {}}
        lines = []
        for suffix in ("dmg", "zip"):
            name = f"Spriglet-0.2.0-4-macOS-arm64-LOCAL-UNSIGNED.{suffix}"
            path = self.root / name
            path.write_bytes(b"package fixture " + suffix.encode())
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.data["artifacts"][name] = {"sha256": digest, "size": path.stat().st_size}
            lines.append(f"{digest}  {name}\n")
        (self.root / "SHA256SUMS").write_text("".join(lines))
        self.save(self.data)

    def save(self, data):
        (self.root / "release.json").write_text(json.dumps(data))

    def check(self):
        return release.package_assets(self.root, self.entry, self.commit)

    def test_valid_preview_has_exactly_four_public_assets(self):
        self.assertEqual(len(self.check()), 4)

    def test_wrong_source_dirty_build_version_or_missing_verification_is_rejected(self):
        for field, invalid in (("sourceRevision", "b" * 40), ("sourceWorkingTreeDirty", True),
                               ("build", "3"), ("version", "0.1.0"), ("diskImageVerified", False),
                               ("architectures", ["x86_64"]), ("bundleIdentifier", "other.app"),
                               ("notarizationTicketValidated", True)):
            altered = dict(self.data, **{field: invalid})
            self.save(altered)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()

    def test_unsigned_stable_is_rejected(self):
        self.entry["channel"] = "stable"
        with self.assertRaisesRegex(ValueError, "stable"):
            self.check()

    def test_developer_id_without_accepted_notarization_is_rejected(self):
        self.save(dict(self.data, signature="developer-id"))
        with self.assertRaisesRegex(ValueError, "notarization"):
            self.check()

    def test_changed_or_missing_package_is_rejected(self):
        path = next(self.root.glob("*.dmg"))
        path.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.check()
        path.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.check()

    def test_unexpected_paths_checksums_and_files_are_rejected(self):
        data = deepcopy(self.data)
        data["artifacts"]["../outside.zip"] = next(iter(data["artifacts"].values()))
        self.save(data)
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.check()
        self.save(self.data)
        (self.root / "private.log").write_text("local diagnostics")
        with self.assertRaisesRegex(ValueError, "four public"):
            self.check()
        (self.root / "private.log").unlink()
        (self.root / "SHA256SUMS").write_text("changed")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            self.check()

    def test_symlink_package_is_rejected(self):
        path = next(self.root.glob("*.dmg"))
        path.unlink()
        path.symlink_to(next(self.root.glob("*.zip")).name)
        with self.assertRaisesRegex(ValueError, "unsafe"):
            self.check()
