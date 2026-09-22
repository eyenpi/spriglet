#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
"$check_dir/build.sh"
"$check_dir/.build/ContextValidation.app/Contents/MacOS/ContextCheck"
