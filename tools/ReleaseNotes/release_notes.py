#!/usr/bin/env python3
"""Generate and validate the public changelog and release notes from bundled JSON."""

import argparse
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
FEED = Path("Sources/Spriglet/Resources/Changelog.json")
REPOSITORY = "https://github.com/eyenpi/spriglet"
SECTIONS = ("added", "changed", "deprecated", "removed", "fixed", "security")
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-preview\.([1-9]\d*))?")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plain_text(value):
    return isinstance(value, str) and bool(value.strip()) and value == value.strip() and not any(ord(c) < 32 for c in value)


def validate(feed):
    require(isinstance(feed, dict) and type(feed.get("schemaVersion")) is int and feed["schemaVersion"] == 1, "Unsupported changelog schema.")
    releases = feed.get("releases")
    require(isinstance(releases, list) and releases, "At least one release is required.")
    versions, builds, previous_key, previous_date = set(), set(), None, None
    for release in releases:
        require(isinstance(release, dict), "Each release must be an object.")
        for field in ("version", "appVersion", "date", "channel", "title", "summary", "distribution"):
            require(plain_text(release.get(field)), f"Missing or invalid release field: {field}.")
        match = VERSION.fullmatch(release["version"])
        require(match is not None, "Use major.minor.patch or major.minor.patch-preview.N versions.")
        base = ".".join(match.groups()[:3])
        preview = match.group(4)
        require(release["appVersion"] == base, "App version must match the numeric release version.")
        require(release["channel"] == ("preview" if preview else "stable"), "Release channel and version suffix disagree.")
        build = release.get("build")
        require(type(build) is int and build > 0 and build not in builds, "Build numbers must be positive and unique.")
        require(release["version"] not in versions, "Duplicate release version.")
        released = date.fromisoformat(release["date"])
        require(released.isoformat() == release["date"], "Dates must use YYYY-MM-DD.")
        key = (*map(int, match.groups()[:3]), 0 if preview else 1, int(preview or 0))
        if previous_key is not None:
            require(key < previous_key and released <= previous_date, "Releases must be newest first.")
            require(build < min(builds), "Build numbers must increase between releases.")
        changes = release.get("changes")
        require(isinstance(changes, dict) and set(changes).issubset(SECTIONS), "Unknown change category.")
        require(any(changes.values()), "Every release needs at least one change.")
        for items in [*changes.values(), release.get("knownLimitations")]:
            require(isinstance(items, list) and all(plain_text(item) for item in items), "Changes and limitations must be arrays of plain text.")
        versions.add(release["version"])
        builds.add(build)
        previous_key, previous_date = key, released
    return feed


def read_feed(root=ROOT):
    return validate(json.loads((root / FEED).read_text()))


def release_markdown(release):
    lines = [f"## {release['version']} — {release['title']}", "", f"{release['date']} · App {release['appVersion']} · Build {release['build']}", "", release["summary"], "", release["distribution"], ""]
    for section in SECTIONS:
        items = release["changes"].get(section, [])
        if items:
            lines.extend([f"### {section.capitalize()}", "", *[f"- {item}" for item in items], ""])
    if release["knownLimitations"]:
        lines.extend(["### Known limitations", "", *[f"- {item}" for item in release["knownLimitations"]], ""])
    return "\n".join(lines).rstrip() + "\n"


def changelog_markdown(feed):
    intro = "# Changelog\n\nUser-visible changes and release engineering changes for every published version. Newest first.\n\nGenerated from [Changelog.json](Sources/Spriglet/Resources/Changelog.json), which is also bundled with the app. Edit that file and run `python3 tools/ReleaseNotes/release_notes.py render`; see the [release workflow](tools/ReleaseNotes/README.md).\n\n"
    return intro + "\n".join(release_markdown(release) for release in feed["releases"])


def select_release(feed, tag, latest=False):
    require(tag.startswith("v"), "Release tags must start with v.")
    found = next((release for release in feed["releases"] if "v" + release["version"] == tag), None)
    require(found is not None, f"No changelog entry for {tag}.")
    require(not latest or found is feed["releases"][0], "Only the newest changelog entry can be published.")
    return found


def check(root=ROOT, tag=None):
    feed = read_feed(root)
    require((root / "CHANGELOG.md").read_text() == changelog_markdown(feed), "CHANGELOG.md is out of date; run the render command.")
    newest = feed["releases"][0]
    project = (root / "Spriglet.xcodeproj/project.pbxproj").read_text()
    versions = re.findall(r"MARKETING_VERSION\s*=\s*([^;]+);", project)
    builds = re.findall(r"CURRENT_PROJECT_VERSION\s*=\s*([^;]+);", project)
    require(versions and set(versions) == {newest["appVersion"]}, "Xcode app version differs from the latest changelog entry.")
    require(builds and set(builds) == {str(newest["build"])}, "Xcode build number differs from the latest changelog entry.")
    if tag:
        select_release(feed, tag, latest=True)
    return feed


def check_bundle(app, root=ROOT):
    feed = check(root)
    newest = feed["releases"][0]
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleShortVersionString") == newest["appVersion"], "Built app version is incorrect.")
    require(info.get("CFBundleVersion") == str(newest["build"]), "Built app build number is incorrect.")
    resource = app / "Contents/Resources/Changelog.json"
    require(resource.is_file() and resource.read_bytes() == (root / FEED).read_bytes(), "Built app is missing the exact changelog resource.")


def notes(feed, tag):
    release = select_release(feed, tag)
    return release_markdown(release) + f"\n[Build instructions]({REPOSITORY}/blob/{tag}/README.md#try-the-public-preview) · [Full changelog]({REPOSITORY}/blob/{tag}/CHANGELOG.md)\n"


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments], text=True).strip()


def publish(tag):
    feed = check(tag=tag)
    release = select_release(feed, tag, latest=True)
    commit = git("rev-parse", "HEAD")
    require(git("rev-parse", f"refs/tags/{tag}^{{commit}}") == commit, "Check out the requested tag before publishing.")
    remote_refs = dict(line.split()[::-1] for line in git("ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}").splitlines())
    require(remote_refs.get(f"refs/tags/{tag}^{{}}", remote_refs.get(f"refs/tags/{tag}")) == commit, "Remote tag differs from the validated commit.")
    subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", commit, "origin/main"], check=True)
    require(git("status", "--porcelain") == "", "Publish from a clean checkout.")
    output = ROOT / ".build/release-notes" / tag
    output.mkdir(parents=True, exist_ok=True)
    body = notes(feed, tag)
    body_file = output / "release-notes.md"
    body_file.write_text(body)
    # Unique names avoid replacing assets when maintainers add app packages later.
    assets = [ROOT / "CHANGELOG.md", ROOT / FEED]
    repository = os.environ.get("GITHUB_REPOSITORY", "eyenpi/spriglet")
    title = f"Spriglet {release['version']} · {release['title']}"
    existing = subprocess.run(["gh", "release", "view", tag, "--repo", repository, "--json", "body,isDraft,isPrerelease,targetCommitish,name,assets"], text=True, capture_output=True)
    if existing.returncode == 0:
        value = json.loads(existing.stdout)
        require(value["body"] == body and value["name"] == title and not value["isDraft"] and value["isPrerelease"] == (release["channel"] == "preview") and value["targetCommitish"] == commit, "An existing release differs; published releases are not overwritten.")
        published_assets = {asset["name"]: asset for asset in value["assets"]}
        for asset in assets:
            published = published_assets.get(asset.name, {})
            require(published.get("state") == "uploaded" and published.get("digest") == "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest(), "An existing changelog asset is missing or differs; published assets are not overwritten.")
        print(f"Release {tag} already matches the changelog.")
        return
    require("release not found" in existing.stderr.lower(), "Could not determine release state; refusing an uncertain publication.")
    arguments = ["gh", "release", "create", tag, *map(str, assets), "--repo", repository, "--verify-tag", "--target", commit, "--title", title, "--notes-file", str(body_file)]
    if release["channel"] == "preview":
        arguments.extend(["--prerelease", "--latest=false"])
    subprocess.run(arguments, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("render")
    commands.add_parser("check").add_argument("--tag")
    commands.add_parser("notes").add_argument("tag")
    commands.add_parser("bundle").add_argument("app", type=Path)
    commands.add_parser("publish").add_argument("tag")
    args = parser.parse_args()
    if args.command == "render":
        (ROOT / "CHANGELOG.md").write_text(changelog_markdown(read_feed()))
    elif args.command == "check":
        check(tag=args.tag)
        print("Changelog, app version, and build number agree.")
    elif args.command == "notes":
        print(notes(check(), args.tag), end="")
    elif args.command == "bundle":
        check_bundle(args.app)
        print("Built app version and bundled changelog verified.")
    elif args.command == "publish":
        publish(args.tag)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release notes: {error}", file=sys.stderr)
        sys.exit(1)
