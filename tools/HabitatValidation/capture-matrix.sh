#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"

if (($# < 3)); then
    cat >&2 <<'USAGE'
Usage: capture-matrix.sh CASE ATTESTATION VISUAL-EVIDENCE [VISUAL-EVIDENCE ...]

This command reads the current macOS/display state; it never changes Dock,
menu-bar, Stage Manager, Space, full-screen, or display settings.
USAGE
    exit 2
fi

case_id="$1"
attestation="$2"
shift 2
output_directory="${SPRIGLET_HABITAT_EVIDENCE_DIR:-$check_root/.build/habitat-matrix}"
log_directory="$(mktemp -d -t spriglet-habitat-matrix)"
trap 'rm -rf "$log_directory"' EXIT

geometry_log="$log_directory/geometry.log"
habitat_log="$log_directory/habitat.log"

"$check_root/tools/GeometryValidation/run.sh" | tee "$geometry_log"
"$check_dir/run.sh" --preview | tee "$habitat_log"

arguments=(
    capture
    --case "$case_id"
    --geometry-report "$geometry_log"
    --habitat-report "$habitat_log"
    --attestation "$attestation"
    --output-directory "$output_directory"
)
for artifact in "$@"; do
    arguments+=(--artifact "$artifact")
done
python3 "$check_dir/matrix_evidence.py" "${arguments[@]}"
