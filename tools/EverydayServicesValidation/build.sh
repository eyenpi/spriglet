#!/bin/bash
set -euo pipefail
service_fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
service_project_dir="$(cd -- "$service_fixture_dir/../.." && pwd)"
service_sdk="$(xcrun --sdk macosx --show-sdk-path)"
service_arch="$(uname -m)"
mkdir -p "$service_fixture_dir/.build"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O -parse-as-library \
  -sdk "$service_sdk" -target "$service_arch-apple-macos26.0" \
  -framework AVFAudio -framework ServiceManagement -framework CryptoKit \
  "$service_project_dir/Sources/Spriglet/Services/PetSoundService.swift" \
  "$service_project_dir/Sources/Spriglet/Services/LoginItemService.swift" \
  "$service_fixture_dir/EverydayServicesCheck.swift" \
  -o "$service_fixture_dir/.build/EverydayServicesCheck"
printf 'Built services fixture only; no audio or login changes: %s\n' "$service_fixture_dir/.build/EverydayServicesCheck"
