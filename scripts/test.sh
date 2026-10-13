#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
python3 "$task_root/tools/Architecture/check.py"
swift test --package-path "$task_root/Packages/CompanionKit" -Xswiftc -warnings-as-errors
"$task_root/scripts/test-desktop.sh" --app-only
# Compile the opt-in global-input regression tool; running it requires an idle desktop.
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$task_root/tools/SettingsFocusValidation/main.swift" \
  -o "$task_root/.build/lifecycle-validation/settings-focus-validation"
