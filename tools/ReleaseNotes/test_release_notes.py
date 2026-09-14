"""Release consistency and publication guards; no network or real Git mutations."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_notes as release


def entry(version="0.2.0-preview.1", build=3, day="2026-09-14"):
    return {
        "version": version, "appVersion": version.split("-")[0], "build": build,
        "date": day, "channel": "preview" if "-preview." in version else "stable",
        "title": "Companion update", "summary": "New companion controls.",
        "distribution": "Source preview.", "changes": {"added": ["Native Settings."]},
        "knownLimitations": ["Signed app download pending."],
    }


def feed():
    return {"schemaVersion": 1, "releases": [entry(), entry("0.1.0-preview.1", 2, "2026-09-13")]}


def write_fixture(root, value):
    resource = root / release.FEED
    resource.parent.mkdir(parents=True, exist_ok=True)
    resource.write_text(json.dumps(value))
    (root / "CHANGELOG.md").write_text(release.changelog_markdown(value))
    project = root / "Spriglet.xcodeproj/project.pbxproj"
    project.parent.mkdir(exist_ok=True)
    newest = value["releases"][0]
    project.write_text(f"MARKETING_VERSION = {newest['appVersion']};\nCURRENT_PROJECT_VERSION = {newest['build']};\n" * 2)


class ChangelogTests(unittest.TestCase):
    def test_schema_and_required_values(self):
        for value in ({}, {"schemaVersion": True, "releases": [entry()]}, {"schemaVersion": 1, "releases": []}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.validate(value)
        for field, invalid in (("version", "01.2.0"), ("appVersion", "0.1.0"), ("channel", "stable"),
                               ("build", True), ("build", 0), ("date", "20260914"),
                               ("title", "two\nlines"), ("summary", ""), ("knownLimitations", "None"),
                               ("changes", {"unknown": ["Change."]}), ("changes", {"added": []}),
                               ("changes", {"added": [42]})):
            value = feed()
            value["releases"][0][field] = invalid
            with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                release.validate(value)

    def test_duplicate_and_out_of_order_releases_are_rejected(self):
        for releases in ([entry(), entry()], list(reversed(feed()["releases"])),
                         [entry(), entry("0.1.0-preview.1", 3)],
                         [entry(), entry("0.1.0-preview.1", 4)],
                         [entry(), entry("0.1.0-preview.1", 2, "2026-09-15")]):
            with self.subTest(releases=releases), self.assertRaises(ValueError):
                release.validate({"schemaVersion": 1, "releases": releases})

    def test_stable_follows_its_previews_and_preview_numbers_are_numeric(self):
        value = {"schemaVersion": 1, "releases": [entry("0.2.0", 5), entry("0.2.0-preview.10", 4), entry("0.2.0-preview.2", 3)]}
        release.validate(value)
        value["releases"][1:3] = reversed(value["releases"][1:3])
        with self.assertRaises(ValueError):
            release.validate(value)

    def test_only_latest_tag_is_publishable_but_historical_notes_are_available(self):
        value = release.validate(feed())
        for tag in ("0.2.0-preview.1", "v9.0.0", "v0.1.0-preview.1"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.select_release(value, tag, latest=True)
        notes = release.notes(value, "v0.1.0-preview.1")
        self.assertIn("## 0.1.0-preview.1", notes)
        self.assertNotIn("0.2.0", notes)
        self.assertIn("/blob/v0.1.0-preview.1/README.md", notes)
        self.assertNotIn("### Fixed", notes)

    def test_markdown_and_both_build_configurations_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root, value = Path(directory), feed()
            write_fixture(root, value)
            release.check(root, "v0.2.0-preview.1")
            (root / "CHANGELOG.md").write_text("Stale release notes.")
            with self.assertRaisesRegex(ValueError, "out of date"):
                release.check(root)
            for old, new in (("MARKETING_VERSION = 0.2.0", "MARKETING_VERSION = 0.1.0"),
                             ("CURRENT_PROJECT_VERSION = 3", "CURRENT_PROJECT_VERSION = 2")):
                write_fixture(root, value)
                project = root / "Spriglet.xcodeproj/project.pbxproj"
                project.write_text(project.read_text().replace(old, new, 1))
                with self.subTest(old=old), self.assertRaises(ValueError):
                    release.check(root)

    def test_built_app_must_have_correct_versions_and_exact_changelog(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, feed())
            app = root / "Spriglet.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            info = {"CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "3"}
            plist = app / "Contents/Info.plist"
            plist.write_bytes(plistlib.dumps(info))
            resource = resources / "Changelog.json"
            for contents in (None, b"{}"):
                if contents is not None:
                    resource.write_bytes(contents)
                with self.subTest(contents=contents), self.assertRaisesRegex(ValueError, "changelog resource"):
                    release.check_bundle(app, root)
            resource.write_bytes((root / release.FEED).read_bytes())
            release.check_bundle(app, root)
            for key in info:
                plist.write_bytes(plistlib.dumps(dict(info, **{key: "wrong"})))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    release.check_bundle(app, root)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root, self.feed = Path(temporary.name), feed()
        write_fixture(self.root, self.feed)
        self.commit = "a" * 40
        self.tag = "v0.2.0-preview.1"
        self.local_commit = self.remote_commit = self.commit
        self.dirty = ""
        self.calls = []
        self.view_result = subprocess.CompletedProcess([], 1, "", "release not found")
        for name, replacement in (("ROOT", self.root), ("git", self.git), ("check", lambda **kwargs: release.validate(self.feed)),
                                  ("subprocess.run", self.fake_run)):
            patcher = patch.object(release, name, replacement) if "." not in name else patch("release_notes." + name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    def git(self, *arguments):
        if arguments == ("rev-parse", "HEAD"):
            return self.commit
        if arguments[0] == "rev-parse":
            return self.local_commit
        if arguments[0] == "ls-remote":
            return f"{'b' * 40}\trefs/tags/{self.tag}\n{self.remote_commit}\trefs/tags/{self.tag}^{{}}"
        if arguments[0] == "status":
            return self.dirty
        self.fail(f"Unexpected Git command: {arguments}")

    def fake_run(self, arguments, **kwargs):
        self.calls.append(arguments)
        if arguments[:3] == ["gh", "release", "view"]:
            return self.view_result
        return subprocess.CompletedProcess(arguments, 0)

    def published(self):
        item = self.feed["releases"][0]
        return {"body": release.notes(self.feed, self.tag), "name": f"Spriglet {item['version']} · {item['title']}",
                "isDraft": False, "isPrerelease": True, "targetCommitish": self.commit,
                "assets": [{"name": path.name, "state": "uploaded", "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
                           for path in (self.root / "CHANGELOG.md", self.root / release.FEED)]}

    def assert_no_create(self):
        self.assertFalse(any(arguments[:3] == ["gh", "release", "create"] for arguments in self.calls))

    def test_uncertain_release_state_never_creates(self):
        self.view_result = subprocess.CompletedProcess([], 1, "", "HTTP 503: Service Unavailable")
        with self.assertRaisesRegex(ValueError, "uncertain publication"):
            release.publish(self.tag)
        self.assert_no_create()

    def test_mismatched_tags_and_dirty_checkout_never_publish(self):
        for attribute, invalid in (("local_commit", "b" * 40), ("remote_commit", "c" * 40), ("dirty", " M README.md")):
            previous = getattr(self, attribute)
            setattr(self, attribute, invalid)
            with self.subTest(attribute=attribute), self.assertRaises(ValueError):
                release.publish(self.tag)
            self.assert_no_create()
            setattr(self, attribute, previous)

    def test_commit_outside_main_never_publishes(self):
        with patch("release_notes.subprocess.run", side_effect=subprocess.CalledProcessError(1, "merge-base")):
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish(self.tag)
        self.assert_no_create()

    def test_preview_publication_uses_exact_notes_assets_and_verified_tag(self):
        release.publish(self.tag)
        command = next(arguments for arguments in self.calls if arguments[:3] == ["gh", "release", "create"])
        self.assertIn("--verify-tag", command)
        self.assertIn("--prerelease", command)
        self.assertIn("--latest=false", command)
        self.assertEqual(command[command.index("--target") + 1], self.commit)
        self.assertEqual(Path(command[command.index("--notes-file") + 1]).read_text(), release.notes(self.feed, self.tag))
        self.assertEqual(command[4:6], [str(self.root / "CHANGELOG.md"), str(self.root / release.FEED)])

    def test_stable_release_is_not_marked_preview(self):
        self.feed["releases"][0] = entry("0.2.0", 3)
        self.tag = "v0.2.0"
        release.publish(self.tag)
        command = next(arguments for arguments in self.calls if arguments[:3] == ["gh", "release", "create"])
        self.assertNotIn("--prerelease", command)
        self.assertNotIn("--latest=false", command)

    def test_matching_existing_release_is_idempotent(self):
        self.view_result = subprocess.CompletedProcess([], 0, json.dumps(self.published()), "")
        release.publish(self.tag)
        self.assert_no_create()

    def test_conflicting_existing_release_or_assets_are_not_overwritten(self):
        value = self.published()
        for field, invalid in (("body", "Changed notes"), ("name", "Changed title"), ("isDraft", True),
                               ("isPrerelease", False), ("targetCommitish", "b" * 40), ("assets", [])):
            altered = dict(value, **{field: invalid})
            self.view_result = subprocess.CompletedProcess([], 0, json.dumps(altered), "")
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.publish(self.tag)
            self.assert_no_create()
        for field, invalid in (("digest", "sha256:changed"), ("state", "starter")):
            altered = deepcopy(value)
            altered["assets"][0][field] = invalid
            self.view_result = subprocess.CompletedProcess([], 0, json.dumps(altered), "")
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.publish(self.tag)
            self.assert_no_create()


if __name__ == "__main__":
    unittest.main()
