#!/usr/bin/env python3
"""Package an unsigned preview or explicit local release rehearsal."""

import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main(arguments=None, source_root=ROOT):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rehearsal", action="store_true",
                        help="Allow local unsigned testing of a stable candidate; publication remains prohibited.")
    args = parser.parse_args(arguments)
    release = json.loads((source_root / "Sources/Spriglet/Resources/Changelog.json").read_text())["releases"][0]
    if release["channel"] != "preview" and not args.rehearsal:
        parser.error("Unsigned stable candidates require --rehearsal; they cannot be published as stable releases.")
    subprocess.run([str(source_root / "scripts/package-release.sh"), "--mode", "local-preview",
                    "--version", release["appVersion"], "--build", str(release["build"]),
                    "--bundle-id", "dev.spriglet.app", "--app", str(args.app.resolve()),
                    "--output", str(args.output.resolve())], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
