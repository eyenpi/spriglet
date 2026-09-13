#!/bin/bash
set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
fixture_root="$(cd -- "$fixture_dir/../.." && pwd)"
fixture_output="$fixture_dir/.build/lifecycle"
fixture_sdk="$(xcrun --sdk macosx --show-sdk-path)"
fixture_arch="$(uname -m)"
fixture_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -O
    -sdk "$fixture_sdk" -target "$fixture_arch-apple-macos26.0")

mkdir -p "$fixture_output"
# A private local core build keeps this retained check independent of Xcode's
# products and avoids changing any application build target or SwiftPM cache.
xcrun swiftc "${fixture_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletCore -emit-module-path "$fixture_output/SprigletCore.swiftmodule" \
    "$fixture_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$fixture_output/libSprigletCore.a"
xcrun swiftc "${fixture_flags[@]}" -parse-as-library -framework AppKit -framework SpriteKit \
    -I "$fixture_output" -L "$fixture_output" -lSprigletCore \
    "$fixture_root/Sources/Spriglet/Rendering/PetRenderView.swift" \
    "$fixture_root/Sources/Spriglet/Rendering/PrototypePetScene.swift" \
    "$fixture_root/Sources/Spriglet/Desktop/PetInteractionView.swift" \
    "$fixture_dir/RendererLifecycleCheck.swift" -o "$fixture_output/RendererLifecycleCheck"
printf 'Built lifecycle check only; not launched: %s\n' "$fixture_output/RendererLifecycleCheck"
