# Spriglet app icon

The current logo gives Sprout a cheerful 2D/3D treatment: rounded green leaf ears, a cream face, rosy cheeks, soft clay-like shading, and a little wave. Large facial features and a clear silhouette keep it recognizable at small sizes.

![The current Spriglet app icon](spriglet-app-icon-1024.png)

## Artwork and provenance

- [Original generated image](spriglet-icon-source.png): the unchanged 1254 × 1254 output from the built-in `image_gen` tool, created on September 15, 2026.
- [Exact generation prompt](prompt.txt): the complete `logo-brand` design request.
- [Production master](spriglet-app-icon-1024.png): 1024 × 1024 opaque RGB PNG with an embedded sRGB profile, resized with the installed macOS `sips` tool.
- [Provenance](provenance.json): SHA-256 hashes for the original, prompt, master, and each bundled icon size.
- [App catalog](../../Sources/Spriglet/Assets.xcassets/AppIcon.appiconset): all ten macOS size/scale slots, from 16 to 1024 pixels, used by both Debug and Release.

The original generated source is the artwork source of truth; rerunning a generative prompt is not guaranteed to recreate identical pixels. To package the approved master or verify the current catalog, run from the repository root:

```sh
sh art/app-icon/export_icon_catalog.sh
python3 art/app-icon/verify_icon.py
./scripts/build.sh Debug
./scripts/build.sh Release
```

When intentionally replacing artwork, update the saved prompt, source, master, and provenance hashes together with the exported catalog. The verifier checks the approved hashes, all ten dimensions, opaque RGB format, sRGB profiles, and clean Xcode asset compilation. CI runs it too. Generated verification reports stay under `.build/art/app-icon/`. Review the icon visually at small sizes and through macOS after an artwork change.

The square artwork uses a full-bleed background and keeps the mascot inside the canvas. This follows Apple's [app icon design guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons); the existing macOS asset catalog supplies every size described in [Xcode's icon configuration documentation](https://developer.apple.com/documentation/xcode/configuring-your-app-icon). The catalog is verified with the installed Xcode 26.6 and macOS 26.5 SDK.

The [first-preview Blender icon](../sprout/public-preview/spriglet-icon.blend) remains historical artwork. Its renderer writes only to that historical folder. The current production exporter reads this folder's master.

Original artwork and tools use the repository's [MIT license](../../LICENSE). See [ASSETS.md](../../ASSETS.md).
