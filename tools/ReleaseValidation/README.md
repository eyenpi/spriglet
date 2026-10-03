# Release packaging

The current application renders Mallow as native vector artwork. Validation checks the executable, architecture, minimum OS, bundled documents, privacy manifest and signature. Retired character frame packs, sound packs and loose PNG frames are rejected. The icon is compiled by Xcode.

## Local unsigned preview

```sh
./scripts/build.sh Release
python3 tools/ReleaseValidation/package_preview.py \
  --app .build/xcode/Build/Products/Release/Spriglet.app \
  --output .build/releases/NEW_DIRECTORY
```

Choose a new output directory. Packaging uses the canonical changelog version/build, creates an ad hoc signed ZIP and DMG, verifies the mounted installation layout and writes checksums and a source report. It does not upload anything. A local ad hoc preview is not Apple-notarized.

## Distribution signing

`scripts/package-release.sh --help` describes Developer ID signing and notarization. Those operations require an explicit release request, an existing signing identity and a Keychain notarization profile. `--check` performs read-only preflight. Never put credentials in source files or command arguments.

## Checks

```sh
python3 -m unittest discover -s tools/ReleaseValidation -p 'test_*.py'
python3 tools/ReleaseNotes/release_notes.py check
python3 tools/AppStore/validate.py
```

The tests cover metadata, bundle resources, code inventory, entitlements, signature requirements, notarization response handling and DMG layout. They use temporary fixtures and mocked notarization calls. Native visual, focus and energy acceptance are separate checks.
