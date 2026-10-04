#!/bin/zsh
# Compiles the production macOS adapters into a finite native regression runner.
set -euo pipefail
if (( $# > 1 )) || [[ -n "${1:-}" && "${1:-}" != "--prepare-fullscreen" && "${1:-}" != "--prepare-introduction" && "${1:-}" != "--prepare-daily-use" && "${1:-}" != "--test-quit-timeout" && "${1:-}" != "--test-preferences" && "${1:-}" != "--test-introduction" && "${1:-}" != "--app-only" ]]; then
  print -u2 "Usage: test-desktop.sh [--prepare-fullscreen|--prepare-introduction|--prepare-daily-use|--test-quit-timeout|--test-preferences|--test-introduction|--app-only]"
  exit 2
fi
task_root="${0:A:h:h}"
task_package="$task_root/Packages/CompanionKit"
task_scratch="$task_root/.build/lifecycle-package"
swift build --scratch-path "$task_scratch" --package-path "$task_package" -Xswiftc -warnings-as-errors
task_binary="$(swift build --scratch-path "$task_scratch" --package-path "$task_package" --show-bin-path)"
if [[ -d "$task_binary/Modules" ]]; then
  task_modules="$task_binary/Modules"
  task_objects=("$task_binary"/CompanionCore.build/*.swift.o "$task_binary"/CompanionRendering.build/*.swift.o)
else
  # Recent Xcode toolchains use the Xcode build system for Swift packages.
  task_modules="$task_binary"
  task_objects=("$task_binary/CompanionCore.o" "$task_binary/CompanionRendering.o")
fi
task_output="$task_root/.build/lifecycle-validation"
mkdir -p "$task_output"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -target arm64-apple-macos26.0 -I "$task_modules" "${task_objects[@]}" \
  "$task_root"/Sources/Spriglet/Environment/*.swift \
  "$task_root"/Sources/Spriglet/Desktop/*.swift \
  "$task_root"/Sources/Spriglet/Runtime/*.swift \
  "$task_root"/Sources/Spriglet/Settings/*.swift \
  "$task_root/Sources/Spriglet/App/AppDelegate.swift" \
  "$task_root/Sources/Spriglet/App/AppControlAction.swift" \
  "$task_root/Sources/Spriglet/App/AppInstanceLease.swift" \
  "$task_root/Sources/Spriglet/App/MenuBarController.swift" \
  "$task_root/Sources/Spriglet/App/LaunchAtLogin.swift" \
  "$task_root/Sources/Spriglet/App/LaunchAtLoginPresentation.swift" \
  "$task_root/Sources/Spriglet/App/CompanionHelpPanel.swift" \
  "$task_root/Sources/Spriglet/App/SharedContent.generated.swift" \
  "$task_root"/tools/LifecycleValidation/*.swift -o "$task_output/lifecycle-validation"
if [[ "${1:-}" == --prepare-* ]]; then
  task_fixture="${1#--prepare-}"
  python3 - "$task_output" "$task_fixture" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

output = Path(sys.argv[1])
fixture = sys.argv[2]
contents = output / (fixture.title() + "Fixture.app/Contents")
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
shutil.copy2(output / "lifecycle-validation", contents / "MacOS/lifecycle-validation")
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump({"CFBundleIdentifier": "dev.spriglet.lifecycle-validation." + fixture,
                  "CFBundleExecutable": "lifecycle-validation", "CFBundleName": "Mallow Lifecycle Fixture",
                  "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication", "LSUIElement": True}, file)
if fixture == "fullscreen":
    (output / "fullscreen-result.txt").unlink(missing_ok=True)
PY
  task_fixture_app="$task_output/${(C)task_fixture}Fixture.app"
  codesign --force --sign - "$task_fixture_app"
  if [[ "$task_fixture" == "fullscreen" ]]; then
    print "Open $task_fixture_app and click its blank window to run real fullscreen acceptance."
    print "The outcome is saved in $task_output/fullscreen-result.txt."
  else
    print "Open $task_fixture_app to review native controls with isolated preferences and fake login registration. It exits after five minutes."
  fi
elif [[ "${1:-}" == "--test-quit-timeout" || "${1:-}" == "--test-preferences" || "${1:-}" == "--test-introduction" ]]; then
  "$task_output/lifecycle-validation" "$1"
else
  "$task_output/lifecycle-validation" "$@"
fi
