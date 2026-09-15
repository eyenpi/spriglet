#!/bin/sh
# Package the approved icon master using the installed macOS image tool.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
master="$script_dir/spriglet-app-icon-1024.png"
catalog="$repo_root/Sources/Spriglet/Assets.xcassets"
icon_dir="$catalog/AppIcon.appiconset"
mkdir -p "$icon_dir"

for point_size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((point_size * scale))
        /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" "$master" \
            --out "$icon_dir/icon_${point_size}x${point_size}@${scale}x.png" >/dev/null
    done
done

cat > "$catalog/Contents.json" <<'JSON'
{
  "info": { "author": "xcode", "version": 1 }
}
JSON

cat > "$icon_dir/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "icon_16x16@1x.png", "idiom": "mac", "scale": "1x", "size": "16x16" },
    { "filename": "icon_16x16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16" },
    { "filename": "icon_32x32@1x.png", "idiom": "mac", "scale": "1x", "size": "32x32" },
    { "filename": "icon_32x32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32" },
    { "filename": "icon_128x128@1x.png", "idiom": "mac", "scale": "1x", "size": "128x128" },
    { "filename": "icon_128x128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128" },
    { "filename": "icon_256x256@1x.png", "idiom": "mac", "scale": "1x", "size": "256x256" },
    { "filename": "icon_256x256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256" },
    { "filename": "icon_512x512@1x.png", "idiom": "mac", "scale": "1x", "size": "512x512" },
    { "filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON

printf 'Exported all 10 macOS app icon slots to %s\n' "$icon_dir"
python3 "$repo_root/tools/SharedContent/sync.py"
