#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
if pgrep -x Spriglet >/dev/null; then
    print -u2 'Quit the running Spriglet prototype before starting an isolated soak.'
    exit 2
fi
"$task_root/scripts/build.sh" Release >&2
if pgrep -x Spriglet >/dev/null; then
    print -u2 'Spriglet started while the build was running. Quit it before retrying the soak.'
    exit 2
fi
task_report="$(mktemp -t spriglet-soak)"
trap 'rm -f "$task_report"' EXIT
task_executable="$task_root/.build/xcode/Build/Products/Release/Spriglet.app/Contents/MacOS/Spriglet"
print -u2 'Running 100 show/hide/reaction cycles and a final rest (about 6–7 minutes). Use Cancel Check in Spriglet to cancel.'
"$task_executable" --soak > "$task_report"
if [[ ! -s "$task_report" ]]; then
    print -u2 'The soak ended without a report, for example after cancellation or quitting.'
    exit 2
fi
cat "$task_report"
python3 - "$task_report" "$task_executable" <<'PY'
import json, pathlib, sys
with open(sys.argv[1]) as report_file:
    report = json.load(report_file)
identity = report.get("buildIdentity", {})
recorded_path = identity.get("executablePath")
if (report.get("kind") != "desktop-soak"
        or identity.get("configuration") != "Release"
        or not recorded_path
        or pathlib.Path(recorded_path).resolve() != pathlib.Path(sys.argv[2]).resolve()):
    print("The report does not identify the requested Release soak executable.", file=sys.stderr)
    sys.exit(1)
if report.get("outcome") == "passed" and report.get("completedCycles") != 100:
    print("A passing soak report must include all 100 cycles.", file=sys.stderr)
    sys.exit(1)
sys.exit({"passed": 0, "failed": 1, "blocked": 2}.get(report.get("outcome"), 1))
PY
