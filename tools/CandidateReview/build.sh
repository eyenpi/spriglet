#!/bin/bash
set -euo pipefail

review_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
review_root="$(cd -- "$review_dir/../.." && pwd)"
review_output="$review_dir/.build"
review_bundle="$review_output/CandidateReview.app"
review_sdk="$(xcrun --sdk macosx --show-sdk-path)"
review_arch="$(uname -m)"
review_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -O
    -sdk "$review_sdk" -target "$review_arch-apple-macos26.0")

mkdir -p "$review_output" "$review_bundle/Contents/MacOS"
xcrun swiftc "${review_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletCore -emit-module-path "$review_output/SprigletCore.swiftmodule" \
    "$review_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$review_output/libSprigletCore.a"
xcrun swiftc "${review_flags[@]}" -parse-as-library -framework AppKit -framework QuartzCore \
    -framework ImageIO -framework CoreGraphics \
    -I "$review_output" -L "$review_output" -lSprigletCore \
    "$review_root/Sources/Spriglet/Rendering/PetRenderView.swift" \
    "$review_root/Sources/Spriglet/Rendering/PetRenderView+Scene.swift" \
    "$review_root/Sources/Spriglet/Rendering/SampleImageDecoder.swift" \
    "$review_root/Sources/Spriglet/Rendering/RestRigScene.swift" \
    "$review_dir/CandidateReview.swift" -o "$review_bundle/Contents/MacOS/CandidateReview"
xcrun swiftc "${review_flags[@]}" -parse-as-library -framework AppKit -framework ImageIO \
    -I "$review_output" -L "$review_output" -lSprigletCore \
    "$review_dir/RenderMedia.swift" -o "$review_output/RenderMedia"
cp "$review_dir/Info.plist" "$review_bundle/Contents/Info.plist"
plutil -lint "$review_bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$review_bundle"
printf 'Built: %s\n' "$review_bundle"
