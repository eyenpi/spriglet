#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"
check_output="$check_dir/.build/native"
check_bundle="$check_dir/.build/CharacterSampleValidation.app"
check_sdk="$(xcrun --sdk macosx --show-sdk-path)"
check_arch="$(uname -m)"
check_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -O
    -sdk "$check_sdk" -target "$check_arch-apple-macos26.0")

mkdir -p "$check_output"
xcrun swiftc "${check_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletCore -emit-module-path "$check_output/SprigletCore.swiftmodule" \
    "$check_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$check_output/libSprigletCore.a"
xcrun swiftc "${check_flags[@]}" -parse-as-library -framework AppKit -framework QuartzCore \
    -framework ImageIO -framework CoreGraphics -framework ColorSync -framework CryptoKit \
    -I "$check_output" -L "$check_output" -lSprigletCore \
    "$check_root/Sources/Spriglet/Rendering/PetRenderView.swift" \
    "$check_root/Sources/Spriglet/Rendering/PetRenderView+Scene.swift" \
    "$check_root/Sources/Spriglet/Rendering/SampleImageDecoder.swift" \
    "$check_root/Sources/Spriglet/Desktop/PetWindowController.swift" \
    "$check_root/Sources/Spriglet/Desktop/PetInteractionView.swift" \
    "$check_root/Sources/Spriglet/Diagnostics/ProcessSample.swift" \
    "$check_dir/NativeSampleCheck.swift" -o "$check_output/NativeSampleCheck"
mkdir -p "$check_bundle/Contents/MacOS"
cp "$check_output/NativeSampleCheck" "$check_bundle/Contents/MacOS/NativeSampleCheck"
cat > "$check_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spriglet.character-sample-validation</string>
<key>CFBundleName</key><string>Character Sample Validation</string>
<key>CFBundleExecutable</key><string>NativeSampleCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$check_bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$check_bundle"
printf 'Built only; not launched: %s\n' "$check_output/NativeSampleCheck"
printf 'Packaged only; not launched: %s\n' "$check_bundle"
