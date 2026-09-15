#!/bin/sh
# Refresh shared content before Wrangler reads the domain configuration.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
python3 tools/SharedContent/sync.py
python3 tools/AppStore/website/build.py --check
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.131.2 deploy -c tools/AppStore/website/wrangler.jsonc "$@"
