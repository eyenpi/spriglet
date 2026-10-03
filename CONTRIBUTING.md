# Contributing

Spriglet's Mallow preview is a native companion for Apple silicon Macs running macOS 26 or later. Code and original artwork contributions use the repository's MIT license.

## Architecture boundaries

Read the architecture section in [README.md](README.md). Keep `CompanionCore` independent of AppKit and platform services. Keep rendering snapshot-only. Route native input and lifecycle changes through `CompanionRuntime`; do not add timers or global state to individual features. Prefer a concrete typed command over a general plugin framework before a capability exists.

`tools/Architecture/check.py` enforces imports and retired-runtime exclusions. Core behavior and physics use deterministic 120 Hz steps; preserve continuous poses, notch capture, click-through margins and the visible resting face when changing them.

## Validation

Use the full Xcode toolchain. Run `./scripts/test.sh`, `./scripts/build.sh Debug` and `./scripts/build.sh Release`. Test meaningful behavior changes; avoid tests that only repeat implementation details. Use `./scripts/preview.sh` to render the production simulation and renderer, then inspect the changed transitions. Run `./scripts/test-desktop.sh` for native lifecycle regressions on a logged-in Mac with a display. Follow [desktop acceptance](tools/LifecycleValidation/README.md) for physical sleep/lock, fullscreen, Spaces, displays and launch checks. Native drag/catch, focus and energy acceptance remain separate from unit tests and compilation.

For bug reports, include the app version, macOS version, display arrangement, triggering interaction and whether Reduce Motion or Low Power Mode is active. Keep unrelated apps and private desktop content out of screenshots.

## Content and artwork

App identity, labels, support, privacy and prepared website/store text have one source in `Configuration/Shared`. Edit those files and run `python3 tools/SharedContent/sync.py`; include generated changes. See [shared content](tools/SharedContent/README.md).

The character and icon share native vector artwork. Regenerate icons with `art/app-icon/export_icon_catalog.sh`; verify with `python3 art/app-icon/verify_icon.py`. Keep third-party material out unless its license and attribution are compatible and documented.

## Repository and delivery

Commit production source, meaningful tests, reusable tools, required artwork and public usage instructions. Local plans, personal records, reports and review exports belong under ignored `.build/` or `docs/`. Run `python3 scripts/check-public-files.py --working-tree` before reviewing a change and the normal public check before pushing. Retired 3D/sprite pipelines and temporary prototype exports must not return to the active tree.

Before a release, add user-visible changes and release-tooling changes to `Sources/Spriglet/Resources/Changelog.json`, preserve historical entries and render `CHANGELOG.md`. Keep Xcode version/build numbers aligned. See [release notes](tools/ReleaseNotes/README.md).

PR CI requires owner approval before allocating a runner; retain the guards in [CI approval](tools/CI/README.md). A local ad hoc build is not a notarized release. Publishing, signing with distribution credentials and uploading are explicit release actions, not part of ordinary build/test commands.
