#!/bin/bash
set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
fixture_app="$fixture_dir/.build/DesktopValidation.app"
fixture_sdk="$(xcrun --sdk macosx --show-sdk-path)"
fixture_arch="$(uname -m)"

mkdir -p "$fixture_app/Contents/MacOS"
/usr/bin/plutil -lint "$fixture_dir/Info.plist"
cp "$fixture_dir/Info.plist" "$fixture_app/Contents/Info.plist"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -O -parse-as-library -sdk "$fixture_sdk" -target "$fixture_arch-apple-macos26.0" \
    -framework AppKit "$fixture_dir/DesktopValidationApp.swift" \
    -o "$fixture_app/Contents/MacOS/DesktopValidation"
/usr/bin/codesign --force --sign - "$fixture_app"
printf 'Built fixture only; not launched: %s\n' "$fixture_app"
