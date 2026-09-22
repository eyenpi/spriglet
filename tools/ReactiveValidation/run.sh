#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
"$check_dir/build.sh"
"$check_dir/.build/ReactiveValidation.app/Contents/MacOS/ReactiveCheck"
