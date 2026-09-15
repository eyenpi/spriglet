# Sprout character source

The current character is [sprout-sample-v01.blend](sample-v01/sprout-sample-v01.blend). Open it in Blender 5.2.1 LTS to edit the geometry, materials, groom, rig, lighting, and animation Actions. There are no external textures, linked libraries, or add-on dependencies.

Select **Sprout Rig**, enter Pose Mode, and play the timeline for idle → walk → pet reaction → settle. The runtime uses transparent pre-rendered frames from a fixed camera. Both walking directions pair each pose with the matching desktop displacement, keeping planted feet grounded.

- [Rig editing, rebuilding, and export commands](sample-v01/README.md)
- [Runtime frames and motion manifest](../../Sources/Spriglet/Resources/SproutSample)
- [Asset and native playback checks](../../tools/CharacterSampleValidation/README.md)
- [Builder](scripts/build_sample.py), [motion authoring](scripts/sample_motion.py), and [surface-bound groom](scripts/sample_groom.py)

The [base geometry](review-01/sprout-design-v01.blend) is an input to the sample builder. `sample-build.json`, contact samples, alpha data, and groom data are the machine-readable inputs used to verify and reproduce the export. Verification output and review renders stay local and ignored.

The [current app icon](../app-icon/README.md) gives Sprout a playful clay-like treatment, with its own master artwork, catalog exporter, and verifier. The original [Blender icon scene](public-preview/spriglet-icon.blend) and [renderer](public-preview/render_icon.py) remain as historical artwork from the first preview; they do not export the current app icon catalog.

Code and artwork use the repository's [MIT license](../../LICENSE).
