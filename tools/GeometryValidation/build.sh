#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"
check_output="$check_dir/.build"
check_bundle="$check_output/GeometryValidation.app"
check_sdk="$(xcrun --sdk macosx --show-sdk-path)"
check_arch="$(uname -m)"

mkdir -p "$check_output" "$check_bundle/Contents/MacOS"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O \
    -sdk "$check_sdk" -target "$check_arch-apple-macos26.0" \
    -parse-as-library -emit-library -static -emit-module -module-name SprigletCore \
    -emit-module-path "$check_output/SprigletCore.swiftmodule" \
    "$check_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$check_output/libSprigletCore.a"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O \
    -sdk "$check_sdk" -target "$check_arch-apple-macos26.0" \
    -framework AppKit -framework CoreGraphics -I "$check_output" -L "$check_output" -lSprigletCore \
    "$check_root/Sources/Spriglet/Desktop/ScreenHabitatProvider.swift" \
    "$check_dir/GeometryCheck.swift" \
    -o "$check_bundle/Contents/MacOS/GeometryCheck"
cat > "$check_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spriglet.geometry-validation</string>
<key>CFBundleName</key><string>Geometry Validation</string>
<key>CFBundleExecutable</key><string>GeometryCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$check_bundle/Contents/Info.plist"
codesign --force --sign - --entitlements "$check_root/Configuration/Spriglet.entitlements" --timestamp=none "$check_bundle"
printf 'Built signed sandbox validation app: %s\n' "$check_bundle"
