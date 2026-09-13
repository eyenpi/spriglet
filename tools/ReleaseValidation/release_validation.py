#!/usr/bin/env python3
"""Packaging validation only. Never launches Spriglet or changes source files."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys


class ValidationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, check=False)
    require(result.returncode == 0, f"{Path(arguments[0]).name} verification failed; no release is approved.")
    return result.stdout


def read_plist(path):
    with Path(path).open("rb") as stream:
        value = plistlib.load(stream)
    require(isinstance(value, dict), "Expected a dictionary property list.")
    return value


def validate_entitlements(value):
    require(isinstance(value, dict), "Invalid signing entitlements.")
    # Reject even a present false value: distribution has no debugging need.
    require("com.apple.security.get-task-allow" not in value and "get-task-allow" not in value,
            "Debug get-task-allow entitlement is forbidden in release preparation.")
    require(value.get("com.apple.security.app-sandbox") is True, "The app must remain sandboxed.")
    # Additional capabilities require an explicit packaging/signing review.
    require(set(value) == {"com.apple.security.app-sandbox"},
            "Unexpected entitlement; review the release signing policy before packaging.")


def validate_info(info, version, build, bundle_id):
    expected = {
        "CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version,
        "CFBundleVersion": build, "CFBundleExecutable": "Spriglet",
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "26.0",
    }
    for key, value in expected.items():
        require(info.get(key) == value, f"Bundle metadata mismatch: {key}.")


def resource_path(root, relative):
    require(isinstance(relative, str), "A sample asset path is not a string.")
    parts = relative.split("/")
    require(relative.endswith(".png") and all(part not in {"", ".", ".."} for part in parts)
            and not any(character in relative for character in ("\\", ":", "\x00")),
            "Unsafe sample asset path.")
    result = root.joinpath(*parts)
    require(not result.is_symlink() and result.resolve().is_relative_to(root.resolve()),
            "An asset resolves outside its resource directory.")
    return result


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def verify_resources(app, source_root):
    source = source_root / "Sources/Spriglet/Resources/SproutSample"
    packaged = app / "Contents/Resources/SproutSample"
    metadata_path = source / "manifest.json"
    require(digest(metadata_path) == digest(packaged / "manifest.json"), "Packaged character manifest differs from source.")
    metadata = json.loads(metadata_path.read_text())
    require(metadata.get("schemaVersion") == 1, "Unsupported character manifest version.")
    require(metadata.get("canvasPixels") == {"width": 448, "height": 448}, "Unexpected sample canvas.")
    require(set(metadata["clips"]) == {"idle", "walkLeft", "walkRight", "pet", "settle"}, "Missing character clip.")
    names = {metadata["restFrame"], metadata["sleepFrame"]}
    for clip in metadata["clips"].values():
        require(0 < len(clip["frames"]) <= 600, "Invalid character clip frame count.")
        names.update(frame["file"] for frame in clip["frames"])
    for name in sorted(names):
        original = resource_path(source, name)
        archived = resource_path(packaged, name)
        require(digest(original) == digest(archived), "A packaged character frame is missing or changed.")
        with archived.open("rb") as stream:
            header = stream.read(24)
        require(len(header) == 24 and header[:8] == b"\x89PNG\r\n\x1a\n"
                and header[12:16] == b"IHDR" and struct.unpack(">II", header[16:24]) == (448, 448),
                "A packaged character PNG has invalid dimensions or a wrong format.")
    actual = {str(path.relative_to(packaged)) for path in packaged.rglob("*.png")}
    require(actual == names, "Packaged sample contains missing or unreferenced PNGs.")
    privacy_source = source_root / "Sources/Spriglet/PrivacyInfo.xcprivacy"
    privacy_app = app / "Contents/Resources/PrivacyInfo.xcprivacy"
    require(read_plist(privacy_source) == read_plist(privacy_app), "Privacy manifest is missing or changed.")
    return {"pngCount": len(names), "manifestSHA256": digest(metadata_path),
            "privacyManifestSHA256": digest(privacy_app)}


def verify_code_inventory(app):
    executable = app / "Contents/MacOS/Spriglet"
    require(executable.is_file() and os.access(executable, os.X_OK), "Main executable is missing or not executable.")
    magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    binaries = []
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Unexpected bundle symlink; nested-code packaging needs review.")
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in magic:
                    binaries.append(path)
    require(binaries == [executable], "Unexpected executable/nested code; add explicit inside-out signing before release.")
    for name in ("Frameworks", "PlugIns", "XPCServices", "Helpers", "Library"):
        directory = app / "Contents" / name
        require(not directory.exists() or not any(directory.iterdir()), "Unexpected nested component; release signing needs review.")
    require(set((app / "Contents/MacOS").iterdir()) == {executable}, "Unexpected helper in the executable directory.")
    architectures = run(["/usr/bin/xcrun", "lipo", "-archs", str(executable)]).decode().split()
    require(architectures == ["arm64"], "The release must contain exactly arm64, as advertised.")
    build_info = run(["/usr/bin/xcrun", "vtool", "-show-build", str(executable)]).decode()
    require(re.search(r"\bplatform MACOS\b", build_info) and re.search(r"\bminos 26\.0(?:\s|$)", build_info),
            "Mach-O deployment target does not match macOS 26.0.")
    return architectures


def validate_signature_details(details, entitlements, mode):
    validate_entitlements(entitlements)
    require(re.search(r"flags=0x[0-9a-fA-F]+\([^\n]*\bruntime\b", details), "Hardened runtime is missing.")
    if mode == "local-preview":
        require("Signature=adhoc" in details and "Authority=" not in details, "Local preview must use only an ad hoc signature.")
    else:
        require("Authority=Developer ID Application:" in details and "Signature=adhoc" not in details,
                "A Developer ID Application signature is required.")
        require(re.search(r"^Timestamp=.+$", details, re.MULTILINE), "Secure signing timestamp is missing.")
        require(re.search(r"^TeamIdentifier=[A-Z0-9]{10}$", details, re.MULTILINE), "The signing team identifier is missing.")


def verify_signature(app, mode):
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    displayed = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)], capture_output=True, check=False)
    require(displayed.returncode == 0, "Could not inspect the code signature.")
    details = (displayed.stdout + displayed.stderr).decode()
    entitlements = plistlib.loads(run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)]))
    validate_signature_details(details, entitlements, mode)


def verify(args):
    app = args.app.resolve()
    info = read_plist(app / "Contents/Info.plist")
    validate_info(info, args.version, args.build, args.bundle_id)
    if args.archive:
        archive_info = read_plist(args.archive / "Info.plist")
        properties = archive_info.get("ApplicationProperties", {})
        require(properties.get("ApplicationPath") == "Applications/Spriglet.app", "Archive application path is wrong.")
        for key, expected in (("CFBundleIdentifier", args.bundle_id), ("CFBundleShortVersionString", args.version), ("CFBundleVersion", args.build)):
            require(properties.get(key) == expected, f"Archive metadata mismatch: {key}.")
    resources = verify_resources(app, args.source_root.resolve())
    architectures = verify_code_inventory(app)
    if args.signature != "none":
        verify_signature(app, args.signature)
    if args.require_ticket:
        require(args.signature == "developer-id", "A notarization ticket only applies to Developer ID distribution.")
        run(["/usr/bin/xcrun", "stapler", "validate", str(app)])
        run(["/usr/bin/xcrun", "syspolicy_check", "distribution", str(app)])
    return {"schemaVersion": 1, "version": args.version, "build": args.build, "bundleIdentifier": args.bundle_id,
            "architectures": architectures, "minimumMacOS": "26.0", "signature": args.signature,
            "notarizationTicketValidated": args.require_ticket, "systemPolicyPassed": args.require_ticket,
            "resources": resources}


def prepare(args):
    info = read_plist(args.source_root / "Configuration/Info.plist")
    info.update({"CFBundleShortVersionString": args.version, "CFBundleVersion": args.build,
                 "CFBundleIdentifier": args.bundle_id})
    entitlements = read_plist(args.source_root / "Configuration/Spriglet.entitlements")
    validate_entitlements(entitlements)
    for name, value in (("Info.plist", info), ("Distribution.entitlements", entitlements)):
        with (args.output / name).open("wb") as stream:
            plistlib.dump(value, stream, fmt=plistlib.FMT_XML)


def notarize(args):
    completed = subprocess.run(["/usr/bin/xcrun", "notarytool", "submit", str(args.zip),
                                "--keychain-profile", args.profile, "--wait", "--timeout", "30m",
                                "--output-format", "json"], capture_output=True, check=False)
    try:
        response = json.loads(completed.stdout)
    except (ValueError, UnicodeError):
        response = {}
    # Whitelist fields. Do not retain raw stderr, account data or upload URLs.
    identifier = response.get("id")
    if not isinstance(identifier, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", identifier):
        identifier = None
    status = response.get("status")
    if status not in {"Accepted", "Invalid", "In Progress", "Rejected"}:
        status = "Unknown"
    args.output.write_text(json.dumps({"submissionID": identifier, "status": status}, indent=2) + "\n")
    require(completed.returncode == 0 and status == "Accepted",
            "Apple has not confirmed acceptance. Check the saved submission status before retrying; a timed-out submission may still be processing.")


def report(args):
    result = json.loads(args.verification.read_text())
    revision = run(["/usr/bin/git", "-C", str(args.source_root), "rev-parse", "HEAD"]).decode().strip()
    dirty = bool(run(["/usr/bin/git", "-C", str(args.source_root), "status", "--porcelain"]).strip())
    result.update({"artifact": args.zip.name, "sha256": digest(args.zip), "sourceRevision": revision,
                   "sourceWorkingTreeDirty": dirty,
                   "xcode": run(["/usr/bin/xcodebuild", "-version"]).decode().strip(),
                   "swift": run(["/usr/bin/xcrun", "swift", "--version"]).decode().strip()})
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    entitlements = commands.add_parser("check-entitlements")
    entitlements.add_argument("path", type=Path)
    identity = commands.add_parser("check-identity")
    identity.add_argument("sha1")
    for command in ("prepare", "verify"):
        sub = commands.add_parser(command)
        sub.add_argument("--source-root", type=Path, required=True)
        sub.add_argument("--version", required=True)
        sub.add_argument("--build", required=True)
        sub.add_argument("--bundle-id", required=True)
        if command == "prepare":
            sub.add_argument("--output", type=Path, required=True)
        else:
            sub.add_argument("--app", type=Path, required=True)
            sub.add_argument("--archive", type=Path)
            sub.add_argument("--signature", choices=("none", "local-preview", "developer-id"), required=True)
            sub.add_argument("--require-ticket", action="store_true")
    notarization = commands.add_parser("notarize")
    notarization.add_argument("--zip", type=Path, required=True)
    notarization.add_argument("--profile", required=True)
    notarization.add_argument("--output", type=Path, required=True)
    reporting = commands.add_parser("report")
    for name in ("zip", "source-root", "verification", "output"):
        reporting.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "check-entitlements":
            validate_entitlements(read_plist(args.path))
        elif args.command == "check-identity":
            require(re.fullmatch(r"[A-Fa-f0-9]{40}", args.sha1), "Invalid certificate SHA-1.")
            identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).decode()
            match = re.search(r"\b" + re.escape(args.sha1) + r'\s+"Developer ID Application: [^\n]+"', identities, re.IGNORECASE)
            require(match is not None, "The selected valid Developer ID Application identity is unavailable. No upload occurred.")
        elif args.command == "prepare":
            prepare(args)
        elif args.command == "verify":
            print(json.dumps(verify(args), indent=2, sort_keys=True))
        elif args.command == "notarize":
            notarize(args)
        elif args.command == "report":
            report(args)
    except (ValidationError, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print(f"Release validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
