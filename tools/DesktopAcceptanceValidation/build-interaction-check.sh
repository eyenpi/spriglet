#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"
check_output="$check_dir/.build/interaction"
check_bundle="$check_output/InteractionCheck.app"
check_sdk="$(xcrun --sdk macosx --show-sdk-path)"
check_arch="$(uname -m)"
check_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -O
    -sdk "$check_sdk" -target "$check_arch-apple-macos26.0")

python3 "$check_root/tools/SharedContent/sync.py" --check
mkdir -p "$check_output" "$check_bundle/Contents/MacOS" "$check_bundle/Contents/Resources"
xcrun swiftc "${check_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletCore -emit-module-path "$check_output/SprigletCore.swiftmodule" \
    "$check_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$check_output/libSprigletCore.a"
xcrun swiftc "${check_flags[@]}" -parse-as-library -framework AppKit -framework QuartzCore \
    -framework ImageIO -framework CoreGraphics -framework ColorSync -framework CryptoKit -framework AVFAudio \
    -I "$check_output" -L "$check_output" -lSprigletCore \
    "$check_root/Sources/Spriglet/Rendering/PetRenderView.swift" \
    "$check_root/Sources/Spriglet/Rendering/PetRenderView+Scene.swift" \
    "$check_root/Sources/Spriglet/Rendering/SampleImageDecoder.swift" \
    "$check_root/Sources/Spriglet/Desktop/PetWindowController.swift" \
    "$check_root/Sources/Spriglet/Desktop/TopBarEyesController.swift" \
    "$check_root/Sources/Spriglet/Desktop/TopBarMorphView.swift" \
    "$check_root/Sources/Spriglet/Desktop/PetInteractionView.swift" \
    "$check_root/Sources/Spriglet/App/PetRuntime.swift" \
    "$check_root/Sources/Spriglet/Environment/AppKitEnvironmentSource.swift" \
    "$check_root/Sources/Spriglet/App/SharedContent.generated.swift" \
    "$check_root/Sources/Spriglet/Services/PetSoundService.swift" \
    "$check_root/Sources/Spriglet/Diagnostics/ProcessSample.swift" \
    "$check_root/Sources/Spriglet/Diagnostics/RuntimeProbe.swift" \
    "$check_root/Sources/Spriglet/Diagnostics/SoakProbe.swift" \
    "$check_dir/InteractionCheck.swift" -o "$check_bundle/Contents/MacOS/InteractionCheck"
ln -sfn "$check_root/Sources/Spriglet/Resources/SproutSample" "$check_bundle/Contents/Resources/SproutSample"
ln -sfn "$check_root/Sources/Spriglet/Resources/AcornHopper" "$check_bundle/Contents/Resources/AcornHopper"
ln -sfn "$check_root/Sources/Spriglet/Resources/PetSounds" "$check_bundle/Contents/Resources/PetSounds"
cat > "$check_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spriglet.interaction-check</string>
<key>CFBundleName</key><string>Interaction Check</string>
<key>CFBundleExecutable</key><string>InteractionCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
plutil -lint "$check_bundle/Contents/Info.plist"
printf 'Built only; not launched: %s\n' "$check_bundle/Contents/MacOS/InteractionCheck"
