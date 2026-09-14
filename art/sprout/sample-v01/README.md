# Sprout animation pipeline

Open `sprout-sample-v01.blend` in Blender 5.2.1 LTS and play the timeline. It opens on the complete **idle → walk right → pet reaction → settle** action with an overview camera that accommodates the authored travel. The separately named runtime camera remains fixed for export. The base geometry in `../review-01/` is the builder input and is not overwritten.

## Editing the rig

Select **Sprout Rig** and enter Pose Mode. Four bone collections organize 14 named controls for root travel, body, head, eyes/blinks, ears, crown, paws, feet, and tail. The meshes use Armature modifiers and vertex groups. Each finite clip is a native editable Action with an explicit Object action slot. Foot poses are authored directly, with measured planted intervals; this sample does not require a physics solver or an IK add-on.

The **Stage · export compensation** bone is unkeyed. Keep it neutral while editing the actual travelling action. During PNG export it cancels the root displacement so the image stays on a fixed canvas; the same displacement is written to the runtime manifest. Both walking directions are separately posed and rendered with the same camera and lighting.

The native Curves groom uses **Deform Curves on Surface**, a unique `HairAttachmentUV` atlas, `surface_uv_coordinate` per strand, and `rest_position` on the skin. It follows the armature-deformed surface. Existing-topology pose/deformation changes are supported; topology or attachment-UV edits require regenerating the groom. Foot soles exclude fur roots below the sole band. `groom-binding-verification.json` records attachment measurements from representative poses.

## Runtime assets and contact data

The runtime resources are in `Sources/Spriglet/Resources/SproutSample/` relative to the repository root. `manifest.json` is published only after every PNG is exported and checked.

| Clip | Frames at 30 fps | Duration | Boundary poses |
|---|---:|---:|---|
| idle | 37 | 1.2333 s | neutral → neutral |
| walkRight | 73 | 2.4333 s | neutral → neutral, +78.4 pt travel |
| walkLeft | 73 | 2.4333 s | neutral → neutral, −78.4 pt travel |
| pet | 34 | 1.1333 s | neutral → petted |
| settle | 25 | 0.8333 s | petted → neutral |

There are 244 PNGs including static rest and sleep poses. Every image is 448 × 448 pixels, displayed at 224 × 224 points. `rootOffsetPoints` is cumulative from the clip's entry and must be applied using the same selected frame index as the image. The ground anchor and projected contact coordinates use a bottom-left origin.

`contact-samples.json` records world-space sole-center markers, planted flags, projected in-place positions, and endpoint bone matrices with root travel removed. Add two pixels per point of manifest root displacement to recover the travelling screen-space contact positions. Authoring distances are model units, not app points. Stance tolerances are recorded explicitly: 0.05 export pixels of screen drift and 0.00001 model units of ground-height error.

## Transparent export

A bounded Cycles shadow catcher has a smooth transparent edge. Automatic Cycles denoising produced faint alpha outside that geometry during testing. The final Blender 5.2 compositor denoises color, then replaces its alpha with the original render alpha. Every pixel on all four PNG borders must have alpha exactly zero; export stops if that check fails. `alpha-verification.json` records the final results. This preserves the rendered contact shadow without an opaque floor or rectangular halo.

The saved model retains 448-pixel, 48-sample render settings, the runtime camera, the bounded catcher, and the editable compositor. GPU device selection is process-local; the authoring scripts do not save Blender preferences.

## Rebuild and export

Run from the repository root, using a disposable Blender process:

```sh
BLENDER_USER_RESOURCES="$PWD/.build/art/sprout-runtime" /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python art/sprout/scripts/build_sample.py -- --mode export --resolution 448 --samples 48 --device METAL
```

This rebuilds the editable model and exports all runtime frames with matching saved 448-pixel, 48-sample settings. Optional workflows are a faster key-pose preview or a guarded re-export of the existing saved model:

```sh
BLENDER_USER_RESOURCES="$PWD/.build/art/sprout-runtime" /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python art/sprout/scripts/build_sample.py -- --mode preview --resolution 256 --samples 16 --device CPU

BLENDER_USER_RESOURCES="$PWD/.build/art/sprout-runtime" /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python art/sprout/scripts/build_sample.py -- --mode export --reuse-model --resolution 448 --samples 48 --device METAL
```

Preview saves production render settings in the editable model and uses lower settings only for its review images. `--reuse-model` checks the saved model, contact data, and authoring-source hashes before export. It rejects an edited model instead of silently using stale foot/root metadata, and changes export settings only in memory. Hand-edited Actions need fresh contact validation before their runtime export; the primary rebuild command regenerates the authored sample from the reviewed source.

## Verify the saved model

Run from the repository root:

```sh
BLENDER_USER_RESOURCES="$PWD/.build/art/sprout-runtime" /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python art/sprout/scripts/verify_sample.py
```

This reads the actual saved model, verifies its recorded input hashes, opening rig/action/camera, render settings, native groom binding, and raw-alpha compositor. It measures eight strand roots per groom at four poses, then evaluates both full foot meshes and their sole fibers at every declared planted walking frame. It also tests that an intentionally changed disposable model is refused by the export provenance guard. Results and explicit tolerances are written to the ignored `verification.json`; failure exits nonzero. No images are rendered and the model is never saved.

The verifier complements the independent PNG/contact validator in `tools/CharacterSampleValidation/`. Its representative groom checks do not exhaustively test every strand or every pose, and the saved-model checks do not replace the exported-image or native playback checks.

## Verified Blender references

- [Armature modifier and vertex groups](https://docs.blender.org/manual/en/5.2/modeling/modifiers/deform/armature.html)
- [Deform Curves on Surface and attachment data](https://docs.blender.org/manual/en/5.2/modeling/geometry_nodes/curve/operations/deform_curves_on_surface.html)
- [Current Action slots](https://docs.blender.org/api/5.2/bpy.types.ActionSlot.html)
- [Scene compositor API](https://docs.blender.org/api/5.2/bpy.types.Scene.html)

The installed 5.2.1 API and background render tests verify these paths. Deprecated `Material.use_nodes` and `Scene.use_nodes` switches and legacy particle hair are not used.
