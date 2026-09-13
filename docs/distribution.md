# Preparing a macOS download

Spriglet can be shared as source and a recorded demo now. A normal public binary still requires a **Developer ID Application certificate with its private key** and working Apple notarization credentials. On 13 September 2026 this Mac reported **0 valid signing identities**. No notarized Spriglet release has been produced or verified by this tooling yet.

The current app targets **Apple silicon and macOS 26 or later**. The packaging script uses the selected Xcode installation, a Release archive, and an isolated build directory. It does not publish anything to a website or release service. The Developer ID mode explicitly submits the app to Apple's notary service.

## Local preview

Run from the repository root:

```sh
scripts/package-release.sh --mode local-preview \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app --check

scripts/package-release.sh --mode local-preview \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app
```

This produces a ZIP ending in `macOS-arm64-LOCAL-UNSIGNED.zip`, a `LOCAL-PREVIEW.txt` notice, validation evidence, and `SHA256SUMS`. “Unsigned” here means **no trusted Developer ID signature**: the app receives an ad hoc signature with its sandbox entitlement for local development. It is not notarized and must not be offered as a normal public download. Use the source/demo for public previews while signing is unavailable.

The default output is `.build/releases/Spriglet-<version>-<build>-<mode>`. Supply `--output /absolute/new/directory` to change it. Existing directories are refused. Version, build number, and bundle identifier are required and override both build settings and a temporary copy of Info.plist; source files are unchanged.

## Developer ID release

An authorized Apple Developer account must first install a valid **Developer ID Application** identity and private key into the local Keychain. Obtain the certificate identifier using `security find-identity -v -p codesigning`. The script accepts its 40-character SHA-1, not a hardcoded person's identity. The certificate and password belong outside source control. [Apple: Developer ID](https://developer.apple.com/developer-id/)

Store notarization credentials interactively in Keychain:

```sh
xcrun notarytool store-credentials spriglet-notary
```

The tool prompts for missing credentials and validates them by default. Do not paste passwords, API private keys, or their contents into source files, command examples, issue reports, or build logs. The packaging script accepts only a Keychain profile name. [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

Replace the placeholder below with the valid certificate SHA-1:

```sh
scripts/package-release.sh --mode developer-id \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app \
  --identity CERTIFICATE_SHA1 --notary-profile spriglet-notary --check

scripts/package-release.sh --mode developer-id \
  --version 0.1.0 --build 2 --bundle-id dev.spriglet.app \
  --identity CERTIFICATE_SHA1 --notary-profile spriglet-notary
```

`--check` performs a read-only authentication check using `notarytool history`, discarding its output. It neither builds nor uploads. The full command stops on a missing/invalid identity, failed authentication, signing failure, non-accepted notarization, missing ticket, or failed verification. It signs the app with hardened runtime and a secure timestamp, submits a ZIP using `notarytool`, staples the accepted ticket to the app, then creates the **final ZIP after stapling**. ZIP files themselves are not a stapler target. [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Notarization waits up to 30 minutes. A timeout does not cancel Apple's processing. On failure the directory stays marked `INCOMPLETE`; a sanitized submission ID/status is retained in `.work/notarization.json` when available. Check the existing submission with `notarytool info` or `wait` using that ID and the Keychain profile before starting another submission. An interrupted or unknown response is not acceptance. This script does not retry uploads automatically.

## What is verified

- Archive and app version/build/bundle identifier; Mach-O architecture exactly `arm64`; minimum macOS version `26.0` in both Info.plist and the executable.
- Bundled character manifest and every referenced PNG against source hashes, PNG dimensions, the exact PNG inventory, and the privacy manifest.
- Sandbox entitlement, hardened runtime, strict recursive signature verification, and absence of `get-task-allow`. Unexpected additional entitlements or nested executable code are rejected for explicit review, rather than signed indiscriminately with `--deep`.
- For Developer ID: certificate type, signing team, secure timestamp, accepted notarization, staple validation, and `syspolicy_check distribution` on the app extracted from the final ZIP. No app is launched by these checks.

Apple documents inside-out signing for nested code; this app currently has one executable, so the script signs the outer app explicitly and refuses an unexpected helper/framework. [Apple: Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

Only share the successful final ZIP, checksum, and suitable release notes. `release.json` records the source revision, whether the working tree was dirty, tool versions, bundle metadata, and artifact hash. `.work` contains the archive, derived products, and local logs; it is not a download artifact. Keychain profile names and notarization credential data are omitted from public verification evidence. A repeatable process is provided; signing timestamps and archive metadata mean it does not promise byte-identical ZIPs.

Before announcing a signed download, test the **actual downloaded final ZIP** through Finder on a separate Gatekeeper-enabled Mac/user account, with ordinary system protections, and confirm install, first launch, welcome flow, controls, and quit. A passing policy check assesses execution policy; it does not prove application behavior. No Intel, older macOS, App Store, automatic updates, or fresh-machine testing is implied by this script. [Apple: Testing a notarised product](https://developer.apple.com/forums/thread/130560)

## Validation status

Research/tool checks used Xcode 26.6 (17F113), Swift 6.3.3, and the installed `codesign`, `notarytool`, `stapler`, `lipo`, `vtool`, and `syspolicy_check` interfaces. The local preflight and focused verifier tests pass; the missing-identity distribution path stops as intended. A read-only check of the pre-polish Release app passed metadata and all 244 PNGs but correctly rejected its injected `get-task-allow=true`; the packaging path disables base entitlement injection and signs from the sandbox-only entitlement file. The actual Release archive/ZIP check is to be run after the welcome/settings/icon integration. Developer ID signing, Apple acceptance, stapling, and fresh-machine launch remain **unverified until signing is configured and the full path succeeds**.
