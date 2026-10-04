#!/bin/zsh
# Finite local profiling with the production core, renderer and native host.
set -euo pipefail
task_root="${0:A:h:h}"
task_package="$task_root/Packages/CompanionKit"
swift build -c release --package-path "$task_package" -Xswiftc -warnings-as-errors >&2
task_bin="$(swift build -c release --package-path "$task_package" --show-bin-path)"
if [[ -f "$task_bin/CompanionCore.o" ]]; then
  task_objects=("$task_bin/CompanionCore.o" "$task_bin/CompanionRendering.o")
  task_modules="$task_bin"
else
  task_objects=("$task_bin"/CompanionCore.build/*.o "$task_bin"/CompanionRendering.build/*.o)
  task_modules="$task_bin/Modules"
fi
mkdir -p "$task_root/.build/energy"
xcrun swiftc -O -g -parse-as-library -swift-version 6 -warnings-as-errors \
  -I "$task_modules" "${task_objects[@]}" \
  "$task_root"/Sources/Spriglet/Desktop/*.swift \
  "$task_root"/Sources/Spriglet/Environment/*.swift \
  "$task_root"/Sources/Spriglet/Settings/*.swift \
  "$task_root"/Sources/Spriglet/Runtime/*.swift \
  "$task_root/Sources/Spriglet/App/AppDelegate.swift" \
  "$task_root/Sources/Spriglet/App/MenuBarController.swift" \
  "$task_root/Sources/Spriglet/App/LaunchAtLogin.swift" \
  "$task_root/Sources/Spriglet/App/LaunchAtLoginPresentation.swift" \
  "$task_root/Sources/Spriglet/App/CompanionHelpPanel.swift" \
  "$task_root/Sources/Spriglet/App/SharedContent.generated.swift" \
  "$task_root/Sources/Spriglet/App/AppControlAction.swift" \
  "$task_root"/tools/EnergyProfile/*.swift \
  -o "$task_root/.build/energy/companion-energy"
exec "$task_root/.build/energy/companion-energy" "$@"
