#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
if pgrep -x Spriglet >/dev/null; then
    print -u2 'Quit the running Spriglet prototype before starting an isolated probe.'
    exit 2
fi
"$task_root/scripts/build.sh" Release >&2
task_report="$(mktemp -t spriglet-probe)"
trap 'rm -f "$task_report"' EXIT
"$task_root/.build/xcode/Build/Products/Release/Spriglet.app/Contents/MacOS/Spriglet" --probe > "$task_report"
cat "$task_report"
python3 - "$task_report" <<'PY'
import json, sys
with open(sys.argv[1]) as report_file:
    report = json.load(report_file)
sys.exit({"passed": 0, "failed": 1, "blocked": 2}.get(report.get("outcome"), 1))
PY
