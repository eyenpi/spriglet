#!/bin/bash
set -euo pipefail

check_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
check_root="$(cd -- "$check_dir/../.." && pwd)"
check_output="$check_dir/.build/native"
check_snapshot="$check_output/source-snapshot"
check_bundle="$check_dir/.build/PersonalityValidation.app"
check_sdk="$(xcrun --sdk macosx --show-sdk-path)"
check_arch="$(uname -m)"
check_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -O
    -D SPRIGLET_BEHAVIOR_VALIDATION -sdk "$check_sdk" -target "$check_arch-apple-macos26.0")

python3 "$check_root/tools/SharedContent/sync.py" --check
mkdir -p "$check_output" "$check_bundle/Contents/MacOS" "$check_bundle/Contents/Resources"

# Compile a private byte-for-byte snapshot, so concurrent work cannot make the
# recorded source hashes describe a different source revision than the binary.
python3 - "$check_root" "$check_snapshot" "$check_bundle/Contents/Resources" <<'PY'
import hashlib, json, pathlib, shutil, subprocess, sys
root, snapshot, resources = map(pathlib.Path, sys.argv[1:])
paths = sorted(root.glob("Packages/SprigletCore/Sources/SprigletCore/*.swift"))
paths += [root / path for path in [
    "Sources/Spriglet/Rendering/PetRenderView.swift",
    "Sources/Spriglet/Rendering/PetRenderView+Scene.swift",
    "Sources/Spriglet/Environment/AppKitEnvironmentSource.swift",
    "Sources/Spriglet/Environment/PointerSource.swift",
    "Sources/Spriglet/Environment/DeadlineScheduler.swift",
    "Sources/Spriglet/Environment/PetAwarenessCoordinator.swift",
    "Sources/Spriglet/Rendering/SampleImageDecoder.swift",
    "Sources/Spriglet/Rendering/RestRigScene.swift",
    "Sources/Spriglet/Desktop/PetWindowController.swift",
    "Sources/Spriglet/Desktop/PetInteractionView.swift",
    "Sources/Spriglet/App/PetRuntime.swift",
    "Sources/Spriglet/App/ReactiveBehaviorCoordinator.swift",
    "Sources/Spriglet/App/SharedContent.generated.swift",
    "Sources/Spriglet/Services/PetSoundService.swift",
    "Sources/Spriglet/Diagnostics/ProcessSample.swift",
    "Sources/Spriglet/Diagnostics/RuntimeProbe.swift",
    "Sources/Spriglet/Diagnostics/SoakProbe.swift",
    "tools/PersonalityValidation/PersonalityCheck.swift",
    "tools/PersonalityValidation/build.sh",
]]
if snapshot.exists():
    shutil.rmtree(snapshot)
source_hashes = {}
for path in paths:
    relative = path.relative_to(root)
    destination = snapshot / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = path.read_bytes()
    destination.write_bytes(data)
    source_hashes[str(relative)] = hashlib.sha256(data).hexdigest()
asset_source = root / "Sources/Spriglet/Resources/AcornHopper"
asset_destination = resources / "AcornHopper"
if asset_destination.exists():
    shutil.rmtree(asset_destination)
shutil.copytree(asset_source, asset_destination)
asset_hashes = {str(path.relative_to(asset_destination)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(asset_destination.rglob("*")) if path.is_file()}
sound_destination = resources / "PetSounds"
if sound_destination.exists():
    shutil.rmtree(sound_destination)
shutil.copytree(root / "Sources/Spriglet/Resources/PetSounds", sound_destination)
sound_hashes = {str(path.relative_to(sound_destination)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(sound_destination.rglob("*")) if path.is_file()}
provenance = {
    "sourceSHA256": source_hashes,
    "assetSHA256": asset_hashes,
    "soundAssetSHA256": sound_hashes,
    "swiftVersion": subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip(),
    "sdkVersion": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
    "architecture": subprocess.check_output(["uname", "-m"], text=True).strip(),
    "compilerFlags": ["-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-O", "-D", "SPRIGLET_BEHAVIOR_VALIDATION", "macOS 26.0 minimum"],
}
(resources / "build-provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
PY

xcrun swiftc "${check_flags[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name SprigletCore -emit-module-path "$check_output/SprigletCore.swiftmodule" \
    "$check_snapshot"/Packages/SprigletCore/Sources/SprigletCore/*.swift \
    -o "$check_output/libSprigletCore.a"
xcrun swiftc "${check_flags[@]}" -parse-as-library -framework AppKit -framework QuartzCore \
    -framework ImageIO -framework CoreGraphics -framework ColorSync -framework CryptoKit -framework AVFAudio \
    -I "$check_output" -L "$check_output" -lSprigletCore \
    "$check_snapshot/Sources/Spriglet/Rendering/PetRenderView.swift" \
    "$check_snapshot/Sources/Spriglet/Rendering/PetRenderView+Scene.swift" \
    "$check_snapshot/Sources/Spriglet/Environment/AppKitEnvironmentSource.swift" \
    "$check_snapshot/Sources/Spriglet/Environment/PointerSource.swift" \
    "$check_snapshot/Sources/Spriglet/Environment/DeadlineScheduler.swift" \
    "$check_snapshot/Sources/Spriglet/Environment/PetAwarenessCoordinator.swift" \
    "$check_snapshot/Sources/Spriglet/Rendering/SampleImageDecoder.swift" \
    "$check_snapshot/Sources/Spriglet/Rendering/RestRigScene.swift" \
    "$check_snapshot/Sources/Spriglet/Desktop/PetWindowController.swift" \
    "$check_snapshot/Sources/Spriglet/Desktop/PetInteractionView.swift" \
    "$check_snapshot/Sources/Spriglet/App/PetRuntime.swift" \
    "$check_snapshot/Sources/Spriglet/App/ReactiveBehaviorCoordinator.swift" \
    "$check_snapshot/Sources/Spriglet/App/SharedContent.generated.swift" \
    "$check_snapshot/Sources/Spriglet/Services/PetSoundService.swift" \
    "$check_snapshot/Sources/Spriglet/Diagnostics/ProcessSample.swift" \
    "$check_snapshot/Sources/Spriglet/Diagnostics/RuntimeProbe.swift" \
    "$check_snapshot/Sources/Spriglet/Diagnostics/SoakProbe.swift" \
    "$check_snapshot/tools/PersonalityValidation/PersonalityCheck.swift" \
    -o "$check_bundle/Contents/MacOS/PersonalityCheck"

cat > "$check_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.spriglet.personality-validation</string>
<key>CFBundleName</key><string>Personality Validation</string>
<key>CFBundleExecutable</key><string>PersonalityCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$check_bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$check_bundle"
printf 'Built only; not launched: %s\n' "$check_bundle/Contents/MacOS/PersonalityCheck"
