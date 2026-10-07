# Artwork and license

Mallow is original artwork for Spriglet under the repository's MIT license. The lavender companion direction was explored with generated concept imagery; those exploratory files are not part of the active tree, and the production character is native vector drawing code, not a generated sprite pack or third-party model.

The documentation animation at `art/mallow/demo.gif` is a finite export of the production simulation and renderer on a simulated desktop, encoded with FFmpeg. Regenerate PNG frames with `./scripts/preview.sh`; it is documentation media, not an app asset. The live character, preview, picking and app icon share `Packages/CompanionKit/Sources/CompanionCore/MallowGeometry.swift`, `Packages/CompanionKit/Sources/CompanionRendering/MallowRenderer.swift` and the core pose contract. Code-generated shapes, gradients, expression, limbs and motion have no external fonts, textures, recordings or model dependencies.

The icon catalog contains ten opaque RGB PNG exports of the same vector character. `art/app-icon/provenance.json` records source and export hashes. Regenerate it with `art/app-icon/export_icon_catalog.sh` and verify with `art/app-icon/verify_icon.py`.

The homepage uses small inline SVG illustrations transcribed from Mallow's native body curves, feet, facial coordinates and palette. They are decorative website artwork, not the production simulation. Website expressions and the local clock do not affect the app. If the native artwork changes, update the SVG in `tools/AppStore/website/home.html` alongside it.

The website self-hosts Instrument Serif Regular and Italic, copyright 2022 The Instrument Serif Project Authors, under the SIL Open Font License 1.1. The full license is in `tools/AppStore/website/FONT-LICENSE.txt`. The WOFF2 files are lossless format conversions of the TTF files from [Google Fonts](https://github.com/google/fonts/tree/main/ofl/instrumentserif), using FontTools 4.60.1 with Brotli. Font names and glyphs are preserved. These fonts are website assets only; they are not bundled in the Mac app.

Retired Sprout, Acorn Hopper and Moss Mouse sprite/model pipelines are removed from the active tree. Their historical source and provenance remain in Git history. They are not bundled by the Mallow rewrite. No audio assets are shipped.
