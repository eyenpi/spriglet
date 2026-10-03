#!/bin/zsh
# Uses the production simulation and vector renderer. Exports local PNG frames.
set -euo pipefail
task_root="${0:A:h:h}"
task_output="${1:-$task_root/.build/preview/frames}"
swift run --package-path "$task_root/Packages/CompanionKit" companion-preview "$task_output"
