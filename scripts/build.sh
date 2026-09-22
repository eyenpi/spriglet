#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_configuration="${1:-Debug}"
task_signing=()
# Siri and Shortcuts reach only team-signed builds; the default ad hoc signature is rejected.
if [[ -n "${SPRIGLET_DEVELOPMENT_TEAM:-}" ]]; then
  task_signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" "DEVELOPMENT_TEAM=$SPRIGLET_DEVELOPMENT_TEAM")
fi
python3 "$task_root/tools/SharedContent/sync.py"
xcodebuild -project "$task_root/Spriglet.xcodeproj" -scheme Spriglet -configuration "$task_configuration" -derivedDataPath "$task_root/.build/xcode" -destination 'platform=macOS,arch=arm64' "${task_signing[@]}" build
