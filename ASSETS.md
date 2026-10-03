# Artwork and license

Mallow is original artwork for Spriglet under the repository's MIT license. The lavender companion direction was explored with generated concept imagery; those exploratory files are not part of the active tree, and the production character is native vector drawing code, not a generated sprite pack or third-party model.

The documentation animation at `art/mallow/demo.gif` is a finite export of the production simulation and renderer on a simulated desktop, encoded with FFmpeg. Regenerate PNG frames with `./scripts/preview.sh`; it is documentation media, not an app asset. The live character, preview and app icon share `Packages/CompanionKit/Sources/CompanionRendering/MallowRenderer.swift` and the core pose contract. Code-generated shapes, gradients, expression, limbs and motion have no external fonts, textures, recordings or model dependencies.

The icon catalog contains ten opaque RGB PNG exports of the same vector character. `art/app-icon/provenance.json` records source and export hashes. Regenerate it with `art/app-icon/export_icon_catalog.sh` and verify with `art/app-icon/verify_icon.py`.

Retired Sprout, Acorn Hopper and Moss Mouse sprite/model pipelines are removed from the active tree. Their historical source and provenance remain in Git history. They are not bundled by the Mallow rewrite. No audio assets are shipped.
