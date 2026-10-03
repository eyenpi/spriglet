#!/bin/zsh
# Regenerate artwork directly from the production character renderer.
set -euo pipefail
task_root="${0:A:h:h:h}"
task_catalog="$task_root/Sources/Spriglet/Assets.xcassets/AppIcon.appiconset"
swift run --package-path "$task_root/Packages/CompanionKit" companion-preview --icons "$task_catalog"
python3 - "$task_root" <<'PY'
import hashlib,json,pathlib,shutil,sys
root=pathlib.Path(sys.argv[1])
source_names=['Packages/CompanionKit/Sources/CompanionRendering/MallowRenderer.swift',
              'Packages/CompanionKit/Sources/CompanionCore/MallowGeometry.swift',
              'Packages/CompanionKit/Sources/CompanionCore/CharacterPose.swift']
icons=root/'Sources/Spriglet/Assets.xcassets/AppIcon.appiconset'
provenance={'schemaVersion':2,'character':'Mallow','method':'native-vector','license':'MIT',
            'sourceFiles':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in source_names},
            'catalogImages':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(icons.glob('*.png'))}}
(root/'art/app-icon/provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
shutil.copy2(icons/'icon_512x512@2x.png',root/'art/app-icon/spriglet-app-icon-1024.png')
PY
python3 "$task_root/tools/SharedContent/sync.py"
