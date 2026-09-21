#!/bin/bash
set -euo pipefail
check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"
check_output="$check_dir/.build"
check_sdk="$(xcrun --sdk macosx --show-sdk-path)"
check_arch="$(uname -m)"
check_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -O
    -sdk "$check_sdk" -target "$check_arch-apple-macos26.0")
mkdir -p "$check_output"

xcrun swiftc "${check_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletCore -emit-module-path "$check_output/SprigletCore.swiftmodule" \
    "$check_root"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$check_output/libSprigletCore.a"
xcrun swiftc "${check_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletConversation -emit-module-path "$check_output/SprigletConversation.swiftmodule" \
    -I "$check_output" "$check_root"/Packages/SprigletCore/Sources/SprigletConversation/*.swift \
    -o "$check_output/libSprigletConversation.a"
# The adapter is compiled with the app target's isolation settings.
xcrun swiftc "${check_flags[@]}" -parse-as-library -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
    -framework FoundationModels -I "$check_output" -L "$check_output" -lSprigletConversation -lSprigletCore \
    "$check_root/Sources/Spriglet/Conversation/CompanionReplyContent.swift" \
    "$check_root/Sources/Spriglet/Conversation/SystemConversationModel.swift" \
    "$check_dir/ConversationCheck.swift" \
    -o "$check_output/ConversationCheck"
printf 'Built conversation check; it reaches the model only with --live: %s\n' "$check_output/ConversationCheck"
