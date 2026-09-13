#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
"$task_root/scripts/build.sh" Debug
open "$task_root/.build/xcode/Build/Products/Debug/Spriglet.app"
