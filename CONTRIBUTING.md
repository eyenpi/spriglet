# Contributing

Spriglet is an early public preview for Apple silicon Macs running macOS 26 or later. Small, focused contributions and reproducible bug reports are welcome.

For a bug, include your macOS version, Mac model, what you did, what you expected, and whether Reduce Motion, Pause, or Pass Clicks Through was enabled. Remove local paths and other personal information from optional diagnostic reports. Please do not include screenshots of unrelated apps or private desktop content.

Build with full Xcode selected, then run `./scripts/test.sh` and the checks relevant to your change. App changes should build in Debug and Release. Animation changes should preserve the manifest timing, contact, transparency, and resource validation described in [the character checks](tools/CharacterSampleValidation/README.md).

App/website branding, privacy, help, and shared control labels have one source in `Configuration/Shared`. Follow the [shared content guide](tools/SharedContent/README.md); edit those sources, run `python3 tools/SharedContent/sync.py`, and commit the generated outputs too. Xcode, icon export, and Cloudflare builds also synchronize them automatically. Do not independently edit generated website pages, bundled documents, `SharedContent.generated.swift`, or the rendered App Store metadata.

Commit app source, tests, reusable tools, required artwork, and public usage instructions. Keep planning notes, personal files, agent instructions, machine reports, and review exports local. The `docs/` directory is reserved for ignored local material. Generated diagnostics belong under `.build/`. Run `python3 scripts/check-public-files.py` before pushing; CI runs the same check.

Use current supported Swift and Apple APIs and verify new choices against official documentation and the installed SDK. Keep the companion local and quiet. Avoid introducing third-party services or permanent polling for work that can be event-driven.

Code and artwork contributions are provided under the repository's MIT license. Keep third-party material out of a contribution unless its license and attribution are compatible and documented.

Before a release, record all user-visible changes, fixes, and relevant release tooling changes in `Sources/Spriglet/Resources/Changelog.json`. Run `python3 tools/ReleaseNotes/release_notes.py render` to update `CHANGELOG.md`; CI checks that the two agree. Keep published entries as historical records. Follow the [version and tag workflow](tools/ReleaseNotes/README.md) for new releases.
