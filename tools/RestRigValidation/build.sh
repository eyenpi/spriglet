#!/bin/bash
set -euo pipefail

validation_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
validation_root="$(cd -- "$validation_dir/../.." && pwd)"
validation_output="$validation_dir/.build"
validation_bundle="$validation_output/RestRigValidation.app"
validation_resources="$validation_root/.build/rest-rig-package"
validation_sdk="$(xcrun --sdk macosx --show-sdk-path)"
validation_arch="$(uname -m)"

if rg -n '(CVDisplayLink|CADisplayLink)' "$validation_root/Sources/Spriglet/Rendering/RestRigScene.swift"; then
    echo "RestRigScene must not introduce a display link." >&2
    exit 1
fi

mkdir -p "$validation_output" "$validation_bundle/Contents/MacOS"
python3 "$validation_root/tools/CharacterAssets/package_acorn.py" --output "$validation_resources"
rm -rf "$validation_bundle/Contents/Resources"
mkdir -p "$validation_bundle/Contents/Resources"
cp -R "$validation_resources" "$validation_bundle/Contents/Resources/RestRigPackage"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O \
    -sdk "$validation_sdk" -target "$validation_arch-apple-macos26.0" \
    -parse-as-library -emit-library -static -emit-module -module-name SprigletCore \
    -emit-module-path "$validation_output/SprigletCore.swiftmodule" \
    "$validation_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$validation_output/libSprigletCore.a"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O \
    -sdk "$validation_sdk" -target "$validation_arch-apple-macos26.0" \
    -framework AppKit -framework QuartzCore -framework ImageIO \
    -I "$validation_output" -L "$validation_output" -lSprigletCore \
    "$validation_root/Sources/Spriglet/Rendering/SampleImageDecoder.swift" \
    "$validation_root/Sources/Spriglet/Rendering/RestRigScene.swift" \
    "$validation_root/Sources/Spriglet/Rendering/PetRenderView.swift" \
    "$validation_root/Sources/Spriglet/Rendering/PetRenderView+Scene.swift" \
    "$validation_dir/RestRigCheck.swift" \
    -o "$validation_bundle/Contents/MacOS/RestRigCheck"
cat > "$validation_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spriglet.rest-rig-validation</string>
<key>CFBundleName</key><string>Rest Rig Validation</string>
<key>CFBundleExecutable</key><string>RestRigCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$validation_bundle/Contents/Info.plist"
codesign --force --sign - --entitlements "$validation_root/Configuration/Spriglet.entitlements" --timestamp=none "$validation_bundle"
printf 'Built signed sandbox validation app: %s\n' "$validation_bundle"
