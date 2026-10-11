#!/usr/bin/env python3
"""Check that tracked files, and optionally their history, belong in the public repo."""

from pathlib import Path, PurePosixPath
import argparse
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {".gitignore", ".gitleaksignore", "AGENTS.md", "README.md", "CHANGELOG.md", "LICENSE", "ASSETS.md", "PRIVACY.md", "CONTRIBUTING.md", "SECURITY.md"}
ROOT_DIRECTORIES = {".github", "Configuration", "Packages", "Sources", "Spriglet.xcodeproj", "art", "scripts", "tools"}
LOCAL_PREFIXES = ("tools/PublicRelease/", "tools/DesktopValidation/", "tools/CharacterSampleReview/", "art/sprout/sample-v01/review/")
LOCAL_NAMES = {".DS_Store", "verification.json", "verification-before-publication.json", "icon-verification.json", "icon-verification-before-publication.json"}
LOCAL_PARTS = {".build", ".swiftpm", ".wrangler", "node_modules", "xcuserdata", "__pycache__", ".codex", ".claude"}
HOME_PATH = re.compile(rb"/Users/[A-Za-z0-9_.-]+/")
KEY_HEADER = re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
TOKEN = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})")


# These sanitized evidence blobs were published before moving to art/.
# Permit only their original path/blob pairs in history; current docs stay local.
HISTORICAL_UI_EVIDENCE = {
    "docs/screenshots/drop-to-mallow/01-text-flow.png": "39c1820fb86e8912cda177f0d025a3b3ff73d7c5",
    "docs/screenshots/drop-to-mallow/02-undo-flow.png": "bf1babab783e33d79212342fc1c22deb2ba8150d",
    "docs/screenshots/drop-to-mallow/03-screenshot-with-date-flow.png": "bb5df985e215c9bc5dd110ddf3e61015a9ac242e",
    "docs/screenshots/drop-to-mallow/04-image-no-date-flow.png": "c5aae8ead427f0d144f53a639c3015cd34864ce0",
    "docs/screenshots/drop-to-mallow/README.md": "2e05b5ae65d2df3f687c3a4260f85ecca7fd86f9",
    "docs/screenshots/drop-to-mallow/source-image.png": "869e74ae98571acd99dd11a70a134c48878d6c9a",
    "docs/screenshots/drop-to-mallow/source-screenshot.png": "6ac8fbb822a53042abb9e2c1349dadffe104f207",
}


def historical_public_path(name, object_id):
    return HISTORICAL_UI_EVIDENCE.get(name) == object_id


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
    # Historical published commits contain this source model. Keep history
    # scannable; tools/Architecture/check.py rejects models in the active tree.
    if name.startswith("art/sprout/review-01/"):
        return name == "art/sprout/review-01/sprout-design-v01.blend"
    return not (path.name.startswith((".env", ".dev.vars")) or path.suffix in {".p12", ".pem", ".p8", ".key", ".mobileprovision", ".provisionprofile", ".pkg", ".pyc"}
                or any(part.endswith(".xcarchive") for part in path.parts) or re.search(r"\.blend[0-9]+$", path.name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--working-tree", action="store_true", help="Check current tracked and new files rather than index blobs")
    parser.add_argument("--history", action="store_true", help="also check all commits reachable from HEAD")
    args = parser.parse_args()
    if args.history and git("rev-parse", "--is-shallow-repository").strip() == b"true":
        raise RuntimeError("History checking requires a full checkout (fetch-depth: 0 in CI).")
    if args.working_tree:
        names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().split("\0")
        failures = []
        checked = 0
        for name in sorted(set(names)):
            if not name or not (ROOT / name).is_file(): continue
            if not public_path(name): failures.append(f"Local-only path: {name}"); continue
            data = (ROOT / name).read_bytes(); checked += 1
            if b"\0" not in data and (HOME_PATH.search(data) or KEY_HEADER.search(data) or TOKEN.search(data)):
                failures.append(f"Personal path or credential candidate in: {name}")
        if failures: print("\n".join(failures), file=sys.stderr); return 1
        print(f"Working-tree public file check passed: {checked} files.")
        return 0
    entries = []
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if entry:
            metadata, name = entry.split(b"\t", 1)
            entries.append((name.decode(), metadata.split()[1].decode(), False))
    revisions = git("rev-list", "HEAD").splitlines() if args.history else []
    for revision in revisions:
        for entry in git("ls-tree", "-r", "-z", revision.decode()).split(b"\0"):
            if entry:
                metadata, name = entry.split(b"\t", 1)
                entries.append((name.decode(), metadata.split()[2].decode(), True))
    failures = set()
    checked_blobs = set()
    for name, object_id, historical in set(entries):
        if not public_path(name) and not (historical and historical_public_path(name, object_id)):
            failures.add(f"Local-only path is tracked: {name}")
            continue
        if object_id in checked_blobs:
            continue
        checked_blobs.add(object_id)
        data = git("cat-file", "blob", object_id)
        if b"\0" not in data and (HOME_PATH.search(data) or KEY_HEADER.search(data) or TOKEN.search(data)):
            failures.add(f"Personal path or credential candidate in: {name}")
    if failures:
        print("\n".join(sorted(failures)), file=sys.stderr)
        return 1
    print(f"Public file check passed: {len(set(name for name, _, _ in entries))} paths, {len(checked_blobs)} blobs, {len(revisions)} historical commits.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
