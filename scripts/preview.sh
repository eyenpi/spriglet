#!/bin/zsh
# Uses the production simulation and vector renderer. Exports local PNG frames.
set -euo pipefail
task_root="${0:A:h:h}"
task_output="${1:-$task_root/.build/preview/frames}"
case "${2:-}" in
    "") swift run --package-path "$task_root/Packages/CompanionKit" companion-preview "$task_output" ;;
    --transitions) swift run --package-path "$task_root/Packages/CompanionKit" companion-preview --transitions "$task_output" ;;
    --interaction) swift run --package-path "$task_root/Packages/CompanionKit" companion-preview --interaction "$task_output" ;;
    --idle) swift run --package-path "$task_root/Packages/CompanionKit" companion-preview --idle "$task_output" ;;
    *) print -u2 "Usage: ./scripts/preview.sh [OUTPUT_DIRECTORY] [--transitions|--interaction|--idle]"; exit 2 ;;
esac
