# Release preparation checks

For Mac App Store distribution, use the separate [App Store submission workflow](../AppStore/README.md). The ZIP, DMG, and notarization commands below serve direct distribution outside the store.
Current source packages only Acorn Hopper: 194 exact Blender PNGs, seven finite
clips, and a 96-point standard canvas. Resource validation rejects the original
Sprout fixture or future Moss Mouse appearing in the app bundle. See the
[reproducible character export](../CharacterAssets/README.md).

[`scripts/package-release.sh`](../../scripts/package-release.sh) builds and verifies an Apple silicon macOS 26 Release archive. It writes to a new directory under `.build/releases/` and does not publish the result.

For a local development package:

```sh
scripts/package-release.sh --mode local-preview \
  --version 0.2.0 --build 4 --bundle-id dev.spriglet.app
```

This produces `LOCAL-UNSIGNED` DMG and ZIP files with an ad hoc signature. The DMG contains the app, an Applications shortcut, and install instructions. Unsigned previews can be downloaded from GitHub but macOS Gatekeeper may block them. Normal Gatekeeper acceptance requires a Developer ID Application identity and Apple notarization. With those configured, replace `CERTIFICATE_SHA1` and the profile name:

```sh
scripts/package-release.sh --mode developer-id \
  --version 0.2.0 --build 4 --bundle-id dev.spriglet.app \
  --identity CERTIFICATE_SHA1 --notary-profile spriglet-notary
```

Developer ID mode signs and notarizes the app and disk image, staples their accepted tickets, and verifies the final extracted and mounted apps. The signed path requires real credentials and must be exercised again before a signed public release. Add `--check` to either command to check prerequisites without building or submitting. Test the final downloaded DMG and ZIP through Finder on a separate Mac before announcing a release.

`release_validation.py` is a Python standard-library helper run by Xcode's bundled `python3`. It validates metadata, source-to-archive character resources, the privacy manifest, architecture/deployment target, executable inventory, signature policy, and final notarization/system-policy results. It never launches the app. The notarization subcommand is internal to the authenticated Developer ID packaging path; it submits to Apple and retains only an allowlisted submission ID/status.

Run the focused checks without building, signing, or contacting Apple:

```sh
bash -n scripts/package-release.sh
xcrun python3 -m unittest discover -s tools/ReleaseValidation -p 'test_*.py' -v
scripts/package-release.sh --mode local-preview \
  --version 0.2.0 --build 4 --bundle-id dev.spriglet.app --check
```

The tests cover metadata overrides/mismatches, missing or modified resources, unsafe paths, sandbox/debug entitlements, hardened-runtime/certificate/timestamp requirements, local ad hoc labeling, and non-accepted/sanitized notarization responses. They use temporary fixtures and mocked subprocesses for notarization. They do not duplicate the animation/alpha/contact/native lifecycle tests under `CharacterSampleValidation`.

The signature policy currently allows the app's one sandbox entitlement and one main executable. If a later release introduces a framework, helper, privileged capability, or provisioning requirement, extend the workflow with deliberate inside-out signing and corresponding validation. Do not use blanket deep signing to mask that change.

Current Apple references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), and [testing a notarised product](https://developer.apple.com/forums/thread/130560). Installed Xcode 27 signing/notarization help and macOS 27 `diskutil image` help were checked. Disk images use `diskutil image create from` (UDZO), introduced with macOS 26; no deprecated image creation command is used. `syspolicy_check distribution` is the current app policy check; it does not execute Spriglet.

## GitHub downloads

`Validate Spriglet` packages the existing validated Release build using `package_preview.py`, avoiding a second archive. It mounts the read-only DMG and checks its Applications shortcut, complete character resources, architecture, metadata and signature. CI uploads only the DMG, ZIP, `SHA256SUMS` and `release.json` as the `app-packages` artifact. Logs, intermediate apps and private machine reports remain local to the runner.

Successful branch/PR builds provide Actions artifacts (a GitHub sign-in is needed to download them). Tagged previews also attach the same files to public GitHub Releases, where downloads do not require Xcode or a GitHub account. PR artifacts expire after 7 days; other build artifacts after 90 days. Published release assets do not use that Actions retention limit.

Publication verifies the package hashes, version, build, clean source revision, architecture and signature status against the validated tag on `main`. Retries accept only identical published assets; they never replace a release. Unsigned packages are restricted to preview entries. Stable release packaging is deliberately blocked until Developer ID signing/notarization is configured; the workflow cannot silently ship an unsigned stable build. This workflow uses no signing secrets and keeps release-write permission out of PR builds.

To package an existing matching Release build locally:

```sh
python3 tools/ReleaseValidation/package_preview.py \
  --app .build/xcode/Build/Products/Release/Spriglet.app \
  --output .build/releases/preview
```

The output directory must be new. `release.json` records whether source changes were uncommitted; publication rejects dirty builds. `SHA256SUMS` covers both installable files. Copy only the four public files into a clean directory before using `release_notes.py publish --packages DIRECTORY`. An incomplete package retains an `INCOMPLETE` marker and is never uploaded by CI.
