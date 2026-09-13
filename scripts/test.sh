#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
swift test --package-path "$task_root/Packages/SprigletCore"
