#!/usr/bin/env python3
"""Check that tracked files, and optionally their history, belong in the public repo."""

from pathlib import Path, PurePosixPath
import argparse
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {".gitignore", "README.md", "LICENSE", "ASSETS.md", "PRIVACY.md", "CONTRIBUTING.md"}
ROOT_DIRECTORIES = {".github", "Configuration", "Packages", "Sources", "Spriglet.xcodeproj", "art", "scripts", "tools"}
LOCAL_PREFIXES = ("tools/PublicRelease/", "tools/DesktopValidation/", "tools/CharacterSampleReview/", "art/sprout/sample-v01/review/")
LOCAL_NAMES = {"AGENTS.md", ".DS_Store", "verification.json", "verification-before-publication.json", "icon-verification.json", "icon-verification-before-publication.json"}
LOCAL_PARTS = {".build", ".swiftpm", "xcuserdata", "__pycache__", ".codex", ".claude"}
HOME_PATH = re.compile(rb"/Users/[A-Za-z0-9_.-]+/")
KEY_HEADER = b"-----BEGIN " + b"PRIVATE KEY-----"
TOKEN = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})")


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def public_path(name):
    path = PurePosixPath(name)
    if len(path.parts) == 1:
        return name in ROOT_FILES
    if path.parts[0] not in ROOT_DIRECTORIES:
        return False
    if name.startswith(LOCAL_PREFIXES) or path.name in LOCAL_NAMES or LOCAL_PARTS.intersection(path.parts):
        return False
    if name.startswith("art/sprout/review-01/"):
        return name == "art/sprout/review-01/sprout-design-v01.blend"
    return not (path.name.startswith(".env") or path.suffix in {".p12", ".pem", ".mobileprovision", ".pyc"} or re.search(r"\.blend[0-9]+$", path.name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="also check all commits reachable from HEAD")
    args = parser.parse_args()
    if args.history and git("rev-parse", "--is-shallow-repository").strip() == b"true":
        raise RuntimeError("History checking requires a full checkout (fetch-depth: 0 in CI).")
    entries = []
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if entry:
            metadata, name = entry.split(b"\t", 1)
            entries.append((name.decode(), metadata.split()[1].decode()))
    revisions = git("rev-list", "HEAD").splitlines() if args.history else []
    for revision in revisions:
        for entry in git("ls-tree", "-r", "-z", revision.decode()).split(b"\0"):
            if entry:
                metadata, name = entry.split(b"\t", 1)
                entries.append((name.decode(), metadata.split()[2].decode()))
    failures = set()
    checked_blobs = set()
    for name, object_id in set(entries):
        if not public_path(name):
            failures.add(f"Local-only path is tracked: {name}")
            continue
        if object_id in checked_blobs:
            continue
        checked_blobs.add(object_id)
        data = git("cat-file", "blob", object_id)
        if b"\0" not in data and (HOME_PATH.search(data) or KEY_HEADER in data or TOKEN.search(data)):
            failures.add(f"Personal path or credential candidate in: {name}")
    if failures:
        print("\n".join(sorted(failures)), file=sys.stderr)
        return 1
    print(f"Public file check passed: {len(set(name for name, _ in entries))} paths, {len(checked_blobs)} blobs, {len(revisions)} historical commits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
