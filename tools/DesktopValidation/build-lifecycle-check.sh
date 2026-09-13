#!/bin/bash
set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
if (( $# != 0 )); then
    printf '%s\n' 'This build command accepts no arguments. See tools/CharacterSampleValidation/README.md for current run options.' >&2
    exit 64
fi

printf '%s\n' \
    'Renderer lifecycle validation moved to tools/CharacterSampleValidation.' \
    'Building NativeSampleCheck only; no application will be launched.' \
    'The historical .build/lifecycle/RendererLifecycleCheck binary is not refreshed and does not validate the current rendered character.' >&2
exec "$fixture_dir/../CharacterSampleValidation/build-native-check.sh"
