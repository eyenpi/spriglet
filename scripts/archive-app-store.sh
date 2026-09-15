#!/bin/bash
# Prepare an Xcode archive; distribution and submission happen in Organizer.
set -euo pipefail
set +x
umask 077

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_team=
task_unsigned=false
task_check=false
task_provision=false
task_output=
task_bundle_id=dev.spriglet.app

usage() {
    cat <<'USAGE'
Usage: scripts/archive-app-store.sh (--unsigned | --team-id TEAM_ID)
       [--bundle-id ID] [--output NEW_DIRECTORY] [--check]
       [--allow-provisioning-updates]

--unsigned: local archive rehearsal; cannot be uploaded or distributed.
--team-id: archive with automatic Apple Development signing for the chosen team.
--allow-provisioning-updates: let Xcode contact Apple to manage signing profiles.
--check: check source and tools only, without creating an archive or contacting Apple.

Version/build come from the checked-in changelog and Xcode project. Existing output
directories are refused. This command never exports or uploads a build. Open the
signed archive in Xcode Organizer to validate and distribute to App Store Connect.
USAGE
}
die() { printf 'App Store archive stopped: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --unsigned) task_unsigned=true; shift ;;
        --check) task_check=true; shift ;;
        --allow-provisioning-updates) task_provision=true; shift ;;
        --team-id|--bundle-id|--output)
            [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1."
            case "$1" in
                --team-id) task_team="$2" ;;
                --bundle-id) task_bundle_id="$2" ;;
                --output) task_output="$2" ;;
            esac
            shift 2 ;;
        *) die "Unknown option. Use --help." ;;
    esac
done
if [[ "$task_unsigned" == true ]]; then
    [[ -z "$task_team" && "$task_provision" == false ]] || die "Unsigned rehearsal cannot configure a team or provisioning."
else
    [[ "$task_team" =~ ^[A-Z0-9]{10}$ ]] || die "Choose --unsigned or provide a ten-character --team-id."
fi
[[ "$task_bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "Invalid reverse-domain bundle identifier."
[[ "$(uname -s)" == Darwin ]] || die "macOS is required."
[[ "$(xcodebuild -version | awk '/^Xcode / {print int($2); exit}')" -ge 26 ]] || die "Select full Xcode 26 or later."
[[ "$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -ge 26 ]] || die "macOS SDK 26 or later is required for this project."
task_python="$(xcrun --find python3)"
"$task_python" "$task_root/tools/SharedContent/sync.py"
"$task_python" "$task_root/tools/AppStore/validate.py"
task_output="${task_output:-$task_root/.build/app-store/Spriglet}"
[[ ! -e "$task_output" && ! -L "$task_output" ]] || die "Output already exists; choose a new directory."
if [[ "$task_check" == true ]]; then
    printf 'Source and tool checks passed. Signing credentials and Apple acceptance have not been checked.\n'
    exit 0
fi

mkdir -p "$(dirname "$task_output")"
mkdir "$task_output"
task_output="$(cd "$task_output" && pwd)"
touch "$task_output/INCOMPLETE"
trap 'printf "Archive preparation failed. Keep the INCOMPLETE marker and inspect build.log.\n" >&2' ERR
task_signing=()
task_validation=(--source-root "$task_root")
if [[ "$task_unsigned" == true ]]; then
    task_signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
    printf 'UNSIGNED LOCAL REHEARSAL — not eligible for upload.\n' > "$task_output/UNSIGNED-REHEARSAL.txt"
else
    task_signing=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$task_team" "CODE_SIGN_IDENTITY=Apple Development")
    task_validation+=(--signed)
    if [[ "$task_provision" == true ]]; then task_signing+=(-allowProvisioningUpdates); fi
fi

printf 'Archiving Release. Build log: %s/build.log\n' "$task_output"
xcodebuild -project "$task_root/Spriglet.xcodeproj" -scheme Spriglet \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$task_output/Spriglet.xcarchive" -derivedDataPath "$task_output/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "PRODUCT_BUNDLE_IDENTIFIER=$task_bundle_id" "${task_signing[@]}" \
    archive > "$task_output/build.log" 2>&1
"$task_python" "$task_root/tools/AppStore/validate.py" \
    --archive "$task_output/Spriglet.xcarchive" "${task_validation[@]}" > "$task_output/local-validation.json"
"$task_python" - "$task_output" "$task_team" "$task_root" <<'PY'
import json, pathlib, plistlib, subprocess, sys
output, team, root = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
options = {'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'automatic',
           'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True}
if team:
    options['teamID'] = team
    with (output / 'ExportOptions.plist').open('wb') as stream: plistlib.dump(options, stream)
report = json.loads((output / 'local-validation.json').read_text())
report['sourceRevision'] = subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip()
report['sourceWorkingTreeDirty'] = bool(subprocess.check_output(['git', '-C', root, 'status', '--porcelain']).strip())
report['xcode'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
report['macOSSDK'] = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
(output / 'local-validation.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
PY
rm "$task_output/INCOMPLETE"
trap - ERR
printf 'Local archive checks passed: %s/Spriglet.xcarchive\n' "$task_output"
if [[ "$task_unsigned" == true ]]; then
    printf 'Unsigned rehearsal only. A new signed archive and Apple validation are still required.\n'
else
    printf 'Open the archive in Xcode Organizer, then Validate App and Distribute App > App Store Connect.\n'
fi
