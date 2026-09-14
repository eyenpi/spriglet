# Release preparation checks

[`scripts/package-release.sh`](../../scripts/package-release.sh) builds and verifies an Apple silicon macOS 26 Release archive. It writes to a new directory under `.build/releases/` and does not publish the result.

For a local development package:

```sh
scripts/package-release.sh --mode local-preview \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app
```

This uses an ad hoc signature and labels the ZIP `LOCAL-UNSIGNED`. A public app download requires a valid Developer ID Application identity and notarization credentials stored in Keychain. With those configured, replace `CERTIFICATE_SHA1` and the profile name:

```sh
scripts/package-release.sh --mode developer-id \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app \
  --identity CERTIFICATE_SHA1 --notary-profile spriglet-notary
```

Developer ID mode signs, submits to Apple's notary service, staples an accepted ticket, and verifies the final extracted app. Add `--check` to either command to check prerequisites without building or submitting. Test the final downloaded ZIP through Finder on a separate Mac before announcing a release.

`release_validation.py` is a Python standard-library helper run by Xcode's bundled `python3`. It validates metadata, source-to-archive character resources, the privacy manifest, architecture/deployment target, executable inventory, signature policy, and final notarization/system-policy results. It never launches the app. The notarization subcommand is internal to the authenticated Developer ID packaging path; it submits to Apple and retains only an allowlisted submission ID/status.

Run the focused checks without building, signing, or contacting Apple:

```sh
bash -n scripts/package-release.sh
xcrun python3 -m unittest discover -s tools/ReleaseValidation -p 'test_*.py' -v
scripts/package-release.sh --mode local-preview \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app --check
```

The tests cover metadata overrides/mismatches, missing or modified resources, unsafe paths, sandbox/debug entitlements, hardened-runtime/certificate/timestamp requirements, local ad hoc labeling, and non-accepted/sanitized notarization responses. They use temporary fixtures and mocked subprocesses for notarization. They do not duplicate the animation/alpha/contact/native lifecycle tests under `CharacterSampleValidation`.

The signature policy currently allows the app's one sandbox entitlement and one main executable. If a later release introduces a framework, helper, privileged capability, or provisioning requirement, extend the workflow with deliberate inside-out signing and corresponding validation. Do not use blanket deep signing to mask that change.

Current Apple references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), and [testing a notarised product](https://developer.apple.com/forums/thread/130560). Installed Xcode 26.6 tool help was checked for every invoked signing/notarization command. `syspolicy_check distribution` is the current app policy check; it does not execute Spriglet.
