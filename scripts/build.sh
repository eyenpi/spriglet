#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_configuration="${1:-Debug}"
xcodebuild -project "$task_root/Spriglet.xcodeproj" -scheme Spriglet -configuration "$task_configuration" -derivedDataPath "$task_root/.build/xcode" -destination 'platform=macOS,arch=arm64' build
