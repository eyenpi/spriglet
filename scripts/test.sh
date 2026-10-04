#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
python3 "$task_root/tools/Architecture/check.py"
swift test --package-path "$task_root/Packages/CompanionKit" -Xswiftc -warnings-as-errors
"$task_root/scripts/test-desktop.sh" --app-only
