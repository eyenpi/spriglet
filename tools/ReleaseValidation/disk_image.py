#!/usr/bin/env python3
"""Create a drag-to-Applications DMG and verify its mounted app before shipping."""

import argparse
import json
import os
from pathlib import Path
import subprocess

import release_validation as validation


def command(*args):
    subprocess.run(list(map(str, args)), check=True)


def check_layout(mount):
    validation.require((mount / "Applications").is_symlink()
                       and (mount / "Applications").readlink() == Path("/Applications"),
                       "DMG must contain the Applications shortcut.")
    validation.require((mount / "README.txt").is_file(), "DMG install guide is missing.")
    visible = {p.name for p in mount.iterdir() if not p.name.startswith(".")}
    validation.require(visible == {"Spriglet.app", "Applications", "README.txt"},
                       "Unexpected files in the disk image.")


def create(args):
    validation.require(not args.output.exists(), "Refusing to replace an existing disk image.")
    args.work.mkdir()
    stage = args.work / "Spriglet"
    stage.mkdir()
    command("/usr/bin/ditto", args.app, stage / "Spriglet.app")
    (stage / "Applications").symlink_to("/Applications")
    brand = json.loads((args.source_root / "Configuration/Shared/brand.json").read_text())
    website = brand["websiteURL"].rstrip("/")
    notice = ("UNSIGNED PREVIEW: This build is ad hoc signed, without Developer ID "
              "or Apple notarization. macOS Gatekeeper may block the download.\n\n"
              if args.mode == "local-preview" else "")
    (stage / "README.txt").write_text(
        f"{brand['appName']} {args.version} (build {args.build})\n\n" + notice
        + "Requires an Apple silicon Mac and macOS 26 or later.\n\n"
        "1. Drag Spriglet.app to Applications.\n"
        "2. Eject this disk image.\n"
        "3. Open Spriglet from Applications. Look for the leaf in your menu bar; "
        "Spriglet does not show a Dock icon.\n\n"
        "Use the leaf menu to show the pet, open Settings, or quit.\n"
        "Downloads and source: https://github.com/eyenpi/spriglet/releases\n"
        f"Help: {website}/support\n"
        f"Privacy: {website}/privacy\n")
    # Current macOS disk-image API. UDZO is Apple's distribution container format.
    command("/usr/sbin/diskutil", "image", "create", "from", "--format", "UDZO",
            "--volumeName", f"Spriglet {args.version}", stage, args.output)
    if args.mode == "developer-id":
        command("/usr/bin/codesign", "--sign", args.identity, "--timestamp",
                "--identifier", args.bundle_id + ".disk-image", args.output)
        validation.notarize(argparse.Namespace(zip=args.output, profile=args.notary_profile,
                                               output=args.work / "notarization.json"))
        command("/usr/bin/xcrun", "stapler", "staple", args.output)
        command("/usr/bin/xcrun", "stapler", "validate", args.output)
        command("/usr/bin/codesign", "--verify", "--strict", args.output)
    mount = args.work / "Mounted"
    # macOS 26 requires an existing mount point; macOS 27 can create it.
    mount.mkdir()
    command("/usr/sbin/diskutil", "image", "attach", "--readOnly", "--nobrowse",
            "--mountPoint", mount, args.output)
    try:
        validation.require(os.statvfs(mount).f_flag & os.ST_RDONLY, "DMG must mount read-only.")
        check_layout(mount)
        validation.verify(argparse.Namespace(
            app=mount / "Spriglet.app", archive=None, source_root=args.source_root,
            version=args.version, build=args.build, bundle_id=args.bundle_id,
            signature=args.mode, require_ticket=args.mode == "developer-id"))
    finally:
        command("/usr/sbin/diskutil", "eject", mount)
    print("DMG mounted read-only; installation layout, resources and signature verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "output", "work", "source-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("version", "build", "bundle-id"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--mode", choices=("local-preview", "developer-id"), required=True)
    parser.add_argument("--identity")
    parser.add_argument("--notary-profile")
    parser.add_argument("--require-ticket", action="store_true")
    create(parser.parse_args())
