#!/usr/bin/env python3
"""Package the newest preview using its canonical version and validated Release build."""

import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    release = json.loads((ROOT / "Sources/Spriglet/Resources/Changelog.json").read_text())["releases"][0]
    if release["channel"] != "preview":
        raise SystemExit("Unsigned packaging is only available for preview releases. Use Developer ID for stable releases.")
    subprocess.run([str(ROOT / "scripts/package-release.sh"), "--mode", "local-preview",
                    "--version", release["appVersion"], "--build", str(release["build"]),
                    "--bundle-id", "dev.spriglet.app", "--app", str(args.app.resolve()),
                    "--output", str(args.output.resolve())], check=True)
