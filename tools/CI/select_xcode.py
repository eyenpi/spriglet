#!/usr/bin/env python3
"""Select and verify a pinned Xcode for a CI job, or check a local toolchain against a pin.

CI mode writes DEVELOPER_DIR to $GITHUB_ENV, so later steps use the pinned Xcode
without sudo or xcode-select. Any version drift fails the job with the difference.
"""

from pathlib import Path
import argparse
import json
import os
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / "tools/CI/toolchains.json"
FIELDS = ("runner", "xcode", "macOSSDK", "swift", "reason")


def load_pins(path=PINS):
    pins = json.loads(Path(path).read_text())
    for name, pin in pins.items():
        missing = [field for field in FIELDS if not isinstance(pin.get(field), str) or not pin[field]]
        if missing:
            raise ValueError(f"Toolchain '{name}' is missing {', '.join(missing)}")
    return pins


def version_matches(pinned, observed):
    """A pin names a release line: '27.0' accepts 27.0 and 27.0.1, never 27.1 or 26.6."""
    return observed == pinned or observed.startswith(pinned + ".")


def bundle_version(app):
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle).get("CFBundleShortVersionString")
    except (OSError, plistlib.InvalidFileException):
        return None


def find_xcode(version, applications=Path("/Applications")):
    """Prefer the runner image's versioned path, then any installed Xcode of that version."""
    preferred = applications / f"Xcode_{version}.app"
    candidates = [preferred] + sorted(path for path in applications.glob("Xcode*.app") if path != preferred)
    for app in candidates:
        found = bundle_version(app)
        if found and version_matches(version, found):
            return app
    installed = sorted(f"{path.name} ({bundle_version(path)})" for path in applications.glob("Xcode*.app"))
    raise LookupError(f"Xcode {version} is not installed. Found: {', '.join(installed) or 'none'}")


def parse_xcodebuild(text):
    version = re.search(r"^Xcode (\S+)", text, re.MULTILINE)
    build = re.search(r"^Build version (\S+)", text, re.MULTILINE)
    if not version or not build:
        raise ValueError(f"Unrecognized xcodebuild -version output: {text!r}")
    return version.group(1), build.group(1)


def parse_swift(text):
    match = re.search(r"Apple Swift version (\d+\.\d+(?:\.\d+)?)", text)
    if not match:
        raise ValueError(f"Unrecognized swift --version output: {text!r}")
    return match.group(1)


def observe(developer_dir):
    environment = dict(os.environ, DEVELOPER_DIR=str(developer_dir))

    def run(*command):
        return subprocess.run(command, check=True, capture_output=True, text=True, env=environment).stdout.strip()

    xcode, build = parse_xcodebuild(run("xcodebuild", "-version"))
    return {
        "developerDir": str(developer_dir),
        "xcode": xcode,
        "build": build,
        "macOSSDK": run("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "swift": parse_swift(run("xcrun", "swift", "--version")),
    }


def mismatches(pin, observed):
    return [f"{field}: pinned {pin[field]}, found {observed[field]}"
            for field in ("xcode", "macOSSDK", "swift") if not version_matches(pin[field], observed[field])]


def current_developer_dir():
    if os.environ.get("DEVELOPER_DIR"):
        return Path(os.environ["DEVELOPER_DIR"])
    return Path(subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("toolchain", help="a key in tools/CI/toolchains.json, such as build or codeql")
    parser.add_argument("--check", action="store_true",
                        help="verify the currently selected Xcode instead of selecting one")
    args = parser.parse_args(argv)

    pins = load_pins()
    if args.toolchain not in pins:
        parser.error(f"unknown toolchain '{args.toolchain}'; choose from {', '.join(sorted(pins))}")
    pin = pins[args.toolchain]

    try:
        developer_dir = current_developer_dir() if args.check else find_xcode(pin["xcode"]) / "Contents/Developer"
        observed = observe(developer_dir)
    except (LookupError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Toolchain '{args.toolchain}' unavailable: {error}", file=sys.stderr)
        return 1

    print(f"Toolchain '{args.toolchain}': Xcode {observed['xcode']} ({observed['build']}), "
          f"macOS SDK {observed['macOSSDK']}, Swift {observed['swift']} at {observed['developerDir']}")
    problems = mismatches(pin, observed)
    if problems:
        print(f"Toolchain '{args.toolchain}' does not match tools/CI/toolchains.json: " + "; ".join(problems),
              file=sys.stderr)
        return 1
    if not args.check:
        github_env = os.environ.get("GITHUB_ENV")
        if github_env:
            with open(github_env, "a") as handle:
                handle.write(f"DEVELOPER_DIR={developer_dir}\n")
            print("Later steps use this toolchain through DEVELOPER_DIR.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
