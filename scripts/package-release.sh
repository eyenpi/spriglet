#!/bin/bash
# Repeatable packaging steps; timestamps/signing make artifacts non-bit-identical.
set -euo pipefail
set +x
umask 077
export LC_ALL=C

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_helper="$task_root/tools/ReleaseValidation/release_validation.py"
task_mode=local-preview
task_version=
task_build=
task_bundle_id=
task_output=
task_identity=
task_profile=
task_check=false

usage() {
    cat <<'USAGE'
Usage: scripts/package-release.sh --version VERSION --build BUILD --bundle-id ID
       [--mode local-preview|developer-id] [--output NEW_DIRECTORY] [--check]
       [--identity SHA1 --notary-profile KEYCHAIN_PROFILE]

local-preview (default): local ad hoc signature; LOCAL-UNSIGNED ZIP, no upload.
developer-id: requires a valid Developer ID Application identity and a working
             Keychain profile; signs, uploads to Apple, notarizes and staples.
--check: validate inputs/tools only; Developer ID also checks authentication
         read-only. Does not build, sign, upload, or create an output directory.

The identity is the certificate's 40-character SHA-1 identifier. Credentials
must already be stored by notarytool in Keychain, never supplied to this script.
Existing output directories are refused. Requires Xcode 26+ on macOS 26+.
USAGE
}

die() { printf 'Release preparation stopped: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) task_check=true; shift ;;
        --mode|--version|--build|--bundle-id|--output|--identity|--notary-profile)
            [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1."
            case "$1" in
                --mode) task_mode="$2" ;;
                --version) task_version="$2" ;;
                --build) task_build="$2" ;;
                --bundle-id) task_bundle_id="$2" ;;
                --output) task_output="$2" ;;
                --identity) task_identity="$2" ;;
                --notary-profile) task_profile="$2" ;;
            esac
            shift 2 ;;
        *) die "Unknown option. Use --help." ;;
    esac
done

[[ "$task_mode" == local-preview || "$task_mode" == developer-id ]] || die "Choose local-preview or developer-id."
[[ "$task_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must be three decimal components, for example 0.1.0."
[[ "$task_build" =~ ^[1-9][0-9]*$ ]] || die "--build must be a positive integer."
[[ "$task_bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "--bundle-id must be a reverse-domain identifier."
if [[ "$task_mode" == developer-id ]]; then
    [[ "$task_identity" =~ ^[A-Fa-f0-9]{40}$ ]] || die "Developer ID mode requires --identity with a 40-character certificate SHA-1."
    [[ "$task_profile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || die "Developer ID mode requires a named --notary-profile stored in Keychain."
else
    [[ -z "$task_identity" && -z "$task_profile" ]] || die "Signing identity/profile apply only to developer-id mode."
fi

[[ "$(uname -s)" == Darwin ]] || die "Run this script on macOS."
task_python="$(xcrun --find python3)" || die "Select the full Xcode installation first."
for task_tool in xcodebuild lipo vtool; do
    xcrun --find "$task_tool" >/dev/null || die "The selected Xcode is missing $task_tool."
done
[[ "$(xcodebuild -version | awk '/^Xcode / { print int($2); exit }')" -ge 26 ]] || die "Xcode 26 or later is required."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]] || die "macOS 26 or later is required."
"$task_python" "$task_helper" check-entitlements "$task_root/Configuration/Spriglet.entitlements"

if [[ "$task_mode" == developer-id ]]; then
    for task_tool in notarytool stapler syspolicy_check; do
        xcrun --find "$task_tool" >/dev/null || die "The selected tools are missing $task_tool."
    done
    "$task_python" "$task_helper" check-identity "$task_identity"
    # Authenticate read-only. Never retain the team's history or credential data.
    xcrun notarytool history --keychain-profile "$task_profile" --output-format json >/dev/null 2>&1 \
        || die "The Keychain notarization profile could not authenticate. No upload occurred."
fi

task_output="${task_output:-$task_root/.build/releases/Spriglet-$task_version-$task_build-$task_mode}"
[[ ! -e "$task_output" && ! -L "$task_output" ]] || die "Output already exists; choose a new directory."
if [[ "$task_check" == true ]]; then
    printf 'Preflight passed (%s). No build, signing, upload, or artifact creation performed.\n' "$task_mode"
    exit 0
fi

mkdir -p "$(dirname "$task_output")"
mkdir "$task_output"
task_output="$(cd "$task_output" && pwd)"
task_work="$task_output/.work"
mkdir "$task_work"
touch "$task_output/INCOMPLETE"
trap 'printf "Packaging did not finish. The output remains marked INCOMPLETE; do not publish it.\n" >&2' ERR

"$task_python" "$task_helper" prepare \
    --source-root "$task_root" --output "$task_work" \
    --version "$task_version" --build "$task_build" --bundle-id "$task_bundle_id"

printf 'Archiving Release for Apple silicon. Build log: %s\n' "$task_work/build.log"
xcodebuild -project "$task_root/Spriglet.xcodeproj" -scheme Spriglet \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$task_work/Spriglet.xcarchive" -derivedDataPath "$task_work/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
    MARKETING_VERSION="$task_version" CURRENT_PROJECT_VERSION="$task_build" \
    PRODUCT_BUNDLE_IDENTIFIER="$task_bundle_id" INFOPLIST_FILE="$task_work/Info.plist" \
    archive >"$task_work/build.log" 2>&1

task_archive_app="$task_work/Spriglet.xcarchive/Products/Applications/Spriglet.app"
task_app="$task_work/Spriglet.app"
task_verify_args=(--source-root "$task_root" --version "$task_version" --build "$task_build" --bundle-id "$task_bundle_id")
"$task_python" "$task_helper" verify --app "$task_archive_app" \
    --archive "$task_work/Spriglet.xcarchive" --signature none "${task_verify_args[@]}" \
    >"$task_work/archive-verification.json"
/usr/bin/ditto "$task_archive_app" "$task_app"

if [[ "$task_mode" == local-preview ]]; then
    /usr/bin/codesign --force --sign - --options runtime --timestamp=none \
        --entitlements "$task_work/Distribution.entitlements" "$task_app" \
        >"$task_work/signing.log" 2>&1
    task_suffix=LOCAL-UNSIGNED
    cat >"$task_output/LOCAL-PREVIEW.txt" <<'NOTICE'
LOCAL PREVIEW ONLY — unsigned by a trusted Developer ID identity.
This app has an ad hoc signature for local development, is not notarized, and
is not a normal public download. Do not describe it as Gatekeeper-approved.
Source code and a recorded demo can be shared independently of this artifact.
NOTICE
else
    /usr/bin/codesign --force --sign "$task_identity" --options runtime --timestamp \
        --entitlements "$task_work/Distribution.entitlements" "$task_app" \
        >"$task_work/signing.log" 2>&1
    task_suffix=DeveloperID
fi

"$task_python" "$task_helper" verify --app "$task_app" --signature "$task_mode" \
    "${task_verify_args[@]}" >"$task_work/signed-verification.json"

if [[ "$task_mode" == developer-id ]]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$task_app" "$task_work/submission.zip"
    printf 'Submitting the signed app to Apple and waiting for notarization.\n'
    # The helper stores only the submission ID and status, never raw tool output
    # that could contain account details or temporary authenticated upload URLs.
    "$task_python" "$task_helper" notarize --zip "$task_work/submission.zip" \
        --profile "$task_profile" --output "$task_work/notarization.json"
    xcrun stapler staple "$task_app" >"$task_work/stapling.log" 2>&1
    xcrun stapler validate "$task_app" >>"$task_work/stapling.log" 2>&1
fi

task_zip="$task_output/Spriglet-$task_version-$task_build-macOS-arm64-$task_suffix.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$task_app" "$task_zip"
mkdir "$task_work/Extracted"
/usr/bin/ditto -x -k "$task_zip" "$task_work/Extracted"
task_final_app="$task_work/Extracted/Spriglet.app"
if [[ "$task_mode" == developer-id ]]; then
    task_verify_args+=(--require-ticket)
fi
"$task_python" "$task_helper" verify --app "$task_final_app" --signature "$task_mode" \
    "${task_verify_args[@]}" >"$task_output/verification.json"
"$task_python" "$task_helper" report --zip "$task_zip" --source-root "$task_root" \
    --verification "$task_output/verification.json" --output "$task_output/release.json"
(cd "$task_output" && /usr/bin/shasum -a 256 "$(basename "$task_zip")" >SHA256SUMS)
chmod 644 "$task_zip" "$task_output/SHA256SUMS" "$task_output/verification.json" "$task_output/release.json"
rm "$task_output/INCOMPLETE"
trap - ERR
printf 'Packaging and extracted-bundle verification passed: %s\n' "$task_zip"
if [[ "$task_mode" == local-preview ]]; then
    printf 'LOCAL PREVIEW ONLY: ad hoc signed, no Developer ID signature or notarization.\n'
else
    printf 'Developer ID signature, notarization ticket, and system-policy checks passed.\n'
fi
