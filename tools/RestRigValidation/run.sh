#!/bin/bash
set -euo pipefail

validation_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
"$validation_dir/build.sh"
"$validation_dir/.build/RestRigValidation.app/Contents/MacOS/RestRigCheck"
