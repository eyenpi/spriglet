# Changelog and release publishing

[`Sources/Spriglet/Resources/Changelog.json`](../../Sources/Spriglet/Resources/Changelog.json) is the source of truth for every version. The generator produces [`CHANGELOG.md`](../../CHANGELOG.md), the release body, and the changelog files attached to each new GitHub release. Xcode also bundles the same JSON as `Changelog.json`, ready for a future in-app What's New view.

## Record a version

Add a release to the start of `releases`, preserving existing published entries. Include its version, numeric app version, unique increasing build number, UTC release date, channel, title, summary, distribution availability, categorized changes, and known limitations. Record changes from the previous published version, including work merged between tags. The earliest entry documents the original public preview.

Schema 1 uses plain strings and arrays so an app can decode it without parsing Markdown. Supported categories are `added`, `changed`, `deprecated`, `removed`, `fixed`, and `security`. Empty categories are omitted from the rendered notes. `knownLimitations` is separate from completed changes.

Use `X.Y.Z-preview.N` with channel `preview` for previews, or `X.Y.Z` with channel `stable` for stable releases. Tags have a `v` prefix. The app version is numeric, such as `0.2.0`; the preview suffix belongs in the release version, not Apple's `CFBundleShortVersionString`. Update both Xcode build configurations' `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` to match the newest entry.

```sh
python3 tools/ReleaseNotes/release_notes.py render
python3 tools/ReleaseNotes/release_notes.py check
python3 -m unittest discover -s tools/ReleaseNotes -p 'test_*.py'
```

Preview the notes for an existing entry:

```sh
python3 tools/ReleaseNotes/release_notes.py notes v0.2.0-preview.1
```

The check rejects malformed data, duplicate versions/builds, incorrect ordering, stale Markdown, and disagreement with the Xcode version. CI also verifies the exact JSON bytes and version information inside both built app configurations.

## Publish a tag

Commit and push the release changes to `main`. Create a new annotated, `v`-prefixed tag at that commit and push that exact tag. Do not move an already published tag to different code.

Tags no longer trigger CI. PR checks and installer artifacts require the owner's [CI approval](../CI/README.md). After merging, build and validate the exact clean tag revision locally with the [packaging tools](../ReleaseValidation/README.md). Do not relabel an earlier PR merge artifact as a release: publication requires its recorded source revision to match the tag exactly.

Copy only the four public package files (DMG, ZIP, `SHA256SUMS`, and `release.json`) into a clean package directory, then publish with the authenticated local GitHub CLI:

```sh
python3 tools/ReleaseNotes/release_notes.py publish NEW_TAG --packages PACKAGE_DIRECTORY
```

Replace the placeholders with the newly created tag and validated package directory. The publisher verifies the newest changelog entry, exact tag commit, `main` ancestry, clean source report, and package checksums. It creates the release and attaches `CHANGELOG.md`, `Changelog.json`, the DMG and ZIP, `SHA256SUMS`, and `release.json`. Preview entries produce GitHub prereleases. This local command uses no GitHub runner minutes.

Rerunning publication accepts an already published release only when its commit, title, notes, preview status, and changelog asset checksums agree. A conflicting release is refused. A failed build or version check leaves the tag unpublished as a GitHub release; fix the problem and use a new version and tag if the code changes.

The publisher supports source, release notes, and unsigned installable previews. Signed app packages follow the [Developer ID packaging process](../ReleaseValidation/README.md). Unsigned packages cannot be published as stable releases. Public downloads are on the versioned GitHub release; individual PR builds also provide the `app-packages` Actions artifact.

Official references: [Apple app version format](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring), [GitHub job dependencies and permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax), and [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create).
