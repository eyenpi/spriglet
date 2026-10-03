# Mallow app icon

The icon is rendered from the production vector character in `CompanionRendering/MallowRenderer.swift`. There is no separate image prompt, manual bitmap retouching or image resizing pipeline.

```sh
art/app-icon/export_icon_catalog.sh
python3 art/app-icon/verify_icon.py
```

The exporter draws all ten macOS catalog sizes directly, writes opaque RGB PNGs, refreshes `spriglet-app-icon-1024.png`, records source and output SHA-256 hashes in `provenance.json`, and synchronizes the prepared website logo. Xcode checks the catalog during the app build. Changing the vector source requires regeneration.

Artwork uses the repository's MIT license. The PNG master is a generated export; the renderer and pose contract are its editable source.
