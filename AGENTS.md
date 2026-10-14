# Agent instructions

Follow CONTRIBUTING.md and the architecture section of README.md.

## Checks
- ./scripts/test.sh
- ./scripts/build.sh Debug and ./scripts/build.sh Release
- python3 tools/Architecture/check.py
- python3 scripts/check-public-files.py --working-tree
- Visual or motion changes: ./scripts/preview.sh
- Shared content edits: python3 tools/SharedContent/sync.py
