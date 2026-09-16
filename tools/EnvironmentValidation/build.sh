#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"
check_output="$check_dir/.build"
check_sdk="$(xcrun --sdk macosx --show-sdk-path)"
check_arch="$(uname -m)"

mkdir -p "$check_output"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O \
    -sdk "$check_sdk" -target "$check_arch-apple-macos26.0" \
    -framework AppKit \
    "$check_root/Sources/Spriglet/Environment/AppKitEnvironmentSource.swift" \
    "$check_dir/EnvironmentLifecycleCheck.swift" \
    -o "$check_output/EnvironmentLifecycleCheck"

printf 'Built: %s\n' "$check_output/EnvironmentLifecycleCheck"
