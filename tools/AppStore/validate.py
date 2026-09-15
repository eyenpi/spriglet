#!/usr/bin/env python3
"""Local Mac App Store preparation checks; never signs, uploads, or approves a release."""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_validation", ROOT / "tools/ReleaseValidation/release_validation.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
require = release.require
CATEGORY = "public.app-category.entertainment"
SCREENSHOT_SIZES = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}
PRIVACY_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
}


def validate_metadata(value):
    limits = {"name": 30, "subtitle": 30, "description": 4000, "keywords": 100,
              "promotionalText": 170, "reviewNotes": 4000, "copyright": 200}
    for key, maximum in limits.items():
        text = value.get(key)
        require(isinstance(text, str) and 0 < len(text) <= maximum and text == text.strip(),
                f"Invalid or overlong metadata: {key}.")
        require(not re.search(r"\b(TODO|TBD|PLACEHOLDER)\b", text), f"Unfinished metadata: {key}.")
    require(len(value["keywords"].encode("utf-8")) <= 100, "Keywords exceed 100 UTF-8 bytes.")
    for key in ("supportURL", "marketingURL", "privacyPolicyURL"):
        parsed = urlparse(value.get(key, ""))
        require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
                and parsed.hostname not in {"example.com", "localhost"}, f"Invalid public URL: {key}.")
    require(value.get("price") == "FREE", "The first release must be free.")
    require(value.get("primaryCategory") == "ENTERTAINMENT", "Store and bundle categories must agree.")
    require(value.get("signInRequired") is False, "Spriglet needs no sign-in.")
    email = value.get("supportEmail", "")
    require(isinstance(email, str) and re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", email),
            "Invalid support email address.")
    host = urlparse(value["marketingURL"]).hostname
    require(all(urlparse(value[key]).hostname == host for key in ("supportURL", "privacyPolicyURL"))
            and email.rsplit("@", 1)[1] == host, "Product, support, privacy, and email domains must agree.")


def validate_privacy(value):
    require(value.get("NSPrivacyTracking") is False, "Tracking must remain disabled.")
    require(value.get("NSPrivacyCollectedDataTypes") == [], "Review any change to data collection.")
    require(not value.get("NSPrivacyTrackingDomains"), "Unexpected tracking domains.")
    entries = value.get("NSPrivacyAccessedAPITypes", [])
    reasons = {item["NSPrivacyAccessedAPIType"]: item["NSPrivacyAccessedAPITypeReasons"] for item in entries}
    require(len(entries) == len(reasons) and reasons == PRIVACY_REASONS, "Required-reason API declarations differ from the audit.")


def validate_store_info(info):
    require(info.get("LSApplicationCategoryType") == CATEGORY, "Missing Entertainment category.")
    require(info.get("ITSAppUsesNonExemptEncryption") is False, "Encryption declaration needs review.")
    require(info.get("LSUIElement") is True, "Review notes assume a menu-bar app.")
    require(bool(info.get("NSHumanReadableCopyright")), "Missing copyright.")


def png_info(path):
    with path.open("rb") as stream:
        header = stream.read(33)
    require(len(header) == 33 and header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR",
            f"Invalid PNG header: {path.name}.")
    width, height, depth, color = struct.unpack(">IIBB", header[16:26])
    return width, height, depth, color


def validate_screenshots(directory):
    require(directory.is_dir(), "Screenshot directory is missing.")
    paths = sorted(directory.glob("*.png"))
    require(1 <= len(paths) <= 10, "Provide 1–10 final PNG screenshots per locale.")
    for path in paths:
        width, height, depth, color = png_info(path)
        require((width, height) in SCREENSHOT_SIZES, f"Unsupported Mac screenshot dimensions: {path.name}.")
        require(depth == 8 and color == 2, f"Use 8-bit RGB PNG without alpha: {path.name}.")
        # Decode to a temporary BMP to exercise the pixels, keeping the input untouched.
        with tempfile.TemporaryDirectory() as temporary:
            decoded = Path(temporary) / "decoded.bmp"
            subprocess.run(["/usr/bin/sips", "-s", "format", "bmp", str(path), "--out", str(decoded)],
                           check=True, capture_output=True)
            require(decoded.is_file() and decoded.stat().st_size > width * height * 3,
                    f"Screenshot could not be decoded: {path.name}.")
    return len(paths)


def check_source(root):
    info = release.read_plist(root / "Configuration/Info.plist")
    validate_store_info(info)
    release.validate_entitlements(release.read_plist(root / "Configuration/Spriglet.entitlements"))
    validate_privacy(release.read_plist(root / "Sources/Spriglet/PrivacyInfo.xcprivacy"))
    metadata = json.loads((root / "tools/AppStore/metadata/en-US.json").read_text())
    validate_metadata(metadata)
    links = (root / "Sources/Spriglet/App/AppDocumentView.swift").read_text()
    require(f'"{metadata["privacyPolicyURL"]}"' in links and f'"{metadata["supportURL"]}"' in links,
            "In-app links and store URLs disagree.")
    require(f'"mailto:{metadata["supportEmail"]}"' in links, "In-app email and support contact disagree.")
    for source, bundled in (("PRIVACY.md", "PrivacyPolicy.md"), ("LICENSE", "License.txt")):
        require((root / source).read_bytes() == (root / "Sources/Spriglet/Resources" / bundled).read_bytes(),
                f"Bundled document differs from {source}.")
    icon_root = root / "Sources/Spriglet/Assets.xcassets/AppIcon.appiconset"
    icons = json.loads((icon_root / "Contents.json").read_text())["images"]
    expected = {(size, scale) for size in (16, 32, 128, 256, 512) for scale in (1, 2)}
    seen = set()
    for item in icons:
        size = int(item["size"].split("x")[0])
        scale = int(item["scale"].removesuffix("x"))
        require(item["idiom"] == "mac" and (size, scale) not in seen, "Invalid or duplicate Mac icon slot.")
        width, height, _, _ = png_info(icon_root / item["filename"])
        require((width, height) == (size * scale, size * scale), "App icon pixels do not match its catalog slot.")
        seen.add((size, scale))
    require(seen == expected, "Incomplete Mac app icon catalog.")
    subprocess.run([sys.executable, str(root / "tools/ReleaseNotes/release_notes.py"), "check"], check=True, stdout=sys.stderr)
    newest = json.loads((root / "Sources/Spriglet/Resources/Changelog.json").read_text())["releases"][0]
    return {"appVersion": newest["appVersion"], "build": str(newest["build"]), "metadataLocale": "en-US"}


def check_app(app, root, archive=None, signed=False):
    source = check_source(root)
    info = release.read_plist(app / "Contents/Info.plist")
    bundle_id = info.get("CFBundleIdentifier", "")
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id), "Invalid bundle identifier.")
    release.validate_info(info, source["appVersion"], source["build"], bundle_id)
    validate_store_info(info)
    require(bool(info.get("CFBundleIconName") or info.get("CFBundleIconFile")), "Built app icon is missing.")
    resources = release.verify_resources(app, root)
    architectures = release.verify_code_inventory(app)
    attributes = release.run(["/usr/bin/xattr", "-r", str(app)])
    require(b"com.apple.quarantine" not in attributes, "Quarantine attribute in app bundle; rebuild from trusted local sources.")
    for filename in ("PrivacyPolicy.md", "License.txt", "Changelog.json"):
        require((app / "Contents/Resources" / filename).read_bytes()
                == (root / "Sources/Spriglet/Resources" / filename).read_bytes(), f"Missing or stale bundled {filename}.")
    if archive:
        props = release.read_plist(archive / "Info.plist").get("ApplicationProperties", {})
        require(props.get("ApplicationPath") == "Applications/Spriglet.app", "Not an application archive.")
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            require(props.get(key) == info[key], f"Archive metadata mismatch: {key}.")
        dwarf = archive / "dSYMs/Spriglet.app.dSYM/Contents/Resources/DWARF/Spriglet"
        require(dwarf.is_file(), "Archive is missing its dSYM.")
        def uuids(path):
            output = release.run(["xcrun", "dwarfdump", "--uuid", str(path)]).decode()
            return set(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", output))
        binary_uuids = uuids(app / "Contents/MacOS/Spriglet")
        require(binary_uuids and binary_uuids == uuids(dwarf), "Archive and dSYM UUIDs differ.")
    if signed:
        release.run(["codesign", "--verify", "--strict", str(app)])
        entitlements = plistlib.loads(release.run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)]))
        require(entitlements.get("com.apple.security.app-sandbox") is True, "Signed app is not sandboxed.")
        require(not entitlements.get("com.apple.security.get-task-allow") and not entitlements.get("get-task-allow"), "Debug entitlement in archive.")
        details = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
        require("Signature=adhoc" not in details and re.search(r"TeamIdentifier=[A-Z0-9]{10}", details), "Trusted team signature is missing.")
    return {**source, "bundleIdentifier": bundle_id, "architectures": architectures, "resources": resources,
            "signedArchiveChecked": signed, "appleValidationPerformed": False, "submissionReady": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--screenshots", type=Path)
    args = parser.parse_args()
    try:
        require(not (args.app and args.archive), "Choose --app or --archive.")
        require(not args.signed or args.archive, "--signed requires --archive.")
        app = args.archive / "Products/Applications/Spriglet.app" if args.archive else args.app
        result = check_app(app, args.source_root, args.archive, args.signed) if app else check_source(args.source_root)
        if args.screenshots: result["screenshotCount"] = validate_screenshots(args.screenshots)
        print(json.dumps(result, indent=2, sort_keys=True))
    except (release.ValidationError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"App Store preparation check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
