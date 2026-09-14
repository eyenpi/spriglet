# Sprout character source

The current character is [sprout-sample-v01.blend](sample-v01/sprout-sample-v01.blend). Open it in Blender 5.2.1 LTS to edit the geometry, materials, groom, rig, lighting, and animation Actions. There are no external textures, linked libraries, or add-on dependencies.

Select **Sprout Rig**, enter Pose Mode, and play the timeline for idle → walk → pet reaction → settle. The runtime uses transparent pre-rendered frames from a fixed camera. Both walking directions pair each pose with the matching desktop displacement, keeping planted feet grounded.

- [Rig editing, rebuilding, and export commands](sample-v01/README.md)
- [Runtime frames and motion manifest](../../Sources/Spriglet/Resources/SproutSample)
- [Asset and native playback checks](../../tools/CharacterSampleValidation/README.md)
- [Builder](scripts/build_sample.py), [motion authoring](scripts/sample_motion.py), and [surface-bound groom](scripts/sample_groom.py)

The [base geometry](review-01/sprout-design-v01.blend) is an input to the sample builder. `sample-build.json`, contact samples, alpha data, and groom data are the machine-readable inputs used to verify and reproduce the export. Verification output and review renders stay local and ignored.

The [icon scene](public-preview/spriglet-icon.blend) uses the same character. Its [renderer](public-preview/render_icon.py), [catalog exporter](public-preview/export_icon_catalog.sh), and [verifier](public-preview/verify_icon.py) reproduce the macOS app icon. Run them in a disposable Blender background process from the repository root.

Code and artwork use the repository's [MIT license](../../LICENSE).
