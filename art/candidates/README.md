# Character candidate proofs

Two original editable Blender prototypes explore a smaller, quicker companion:

| Candidate | Construction | Controls | Movement |
| --- | --- | ---: | --- |
| [Acorn Hopper](proof-v01/acorn-hopper/acorn-hopper.blend) | Rounded body, separate cap, one leaf, capsule paws/feet | 9 | One squash-and-hop, 0.8 seconds |
| [Moss Mouse](proof-v01/moss-mouse/moss-mouse.blend) | Low bean body, round head, leaf ears, short sprig tail, four feet | 11 | Two low bounds with a directional turn, 0.8 seconds |

These are selection prototypes, not replacement shipping characters. Both include left and right locomotion, transparent renders, camera turnarounds, a clay review, and a native comparison at a **96-point canvas**. Neither has a complete interaction library. Their source manifest's idle, pet, settle, and sleep entries are explicitly static rest aliases required by the current renderer.

## Review in the native renderer

From the repository root:

```sh
bash tools/CandidateReview/build.sh
open tools/CandidateReview/.build/CandidateReview.app
```

The separate review app uses the unmodified shipping `PetRenderView` and `SampleImageDecoder`. It shows an enlarged neutral model above two actual-size playback cards, on light and dark backgrounds. Use **Hop / dash →**, **← Replay**, and **Rest**. It changes no Spriglet preferences or bundled artwork. It automatically checks finite playback and writes local observations under `.build/candidate-review/`.

## Edit in Blender

Open either `.blend` in **Blender 5.2.1 LTS**. The selected rig opens with an **IN-PLACE INSPECTION** Action: press Space to review the 24-frame movement in the close camera. The other two Actions contain actual right/left world travel. The `Stage` bone is unkeyed and is used only to compensate travel while exporting images.

The model consists of ordinary editable meshes, vertex colors, named bone groups, and eye `Blink` shape keys. Curve source datablocks are retained. There are no external textures, linked libraries, add-ons, particle hair, or generated image-to-3D meshes. The cap uses shallow shader bump; leaves use a single central ridge. A bounded Cycles catcher supplies the contact shadow. Compositor denoising preserves the original alpha coverage.

The [builder](scripts/build_candidates.py) reproduces both prototypes. It imports geometry and action helpers from `art/sprout/scripts/`; it does not load or modify the shipping Sprout scene. The geometry is authored through parameters and revised against actual camera renders. The original concept images influenced the proportions and palette; they are not textures mapped onto a rough mesh.

```sh
blender --background --factory-startup --python-exit-code 1 \
  --python art/candidates/scripts/build_candidates.py -- \
  --candidate acorn-hopper --mode all --samples 40 --device METAL

blender --background --factory-startup --python-exit-code 1 \
  --python art/candidates/scripts/build_candidates.py -- \
  --candidate moss-mouse --mode all --samples 40 --device METAL
```

On macOS, substitute the Blender app's `Contents/MacOS/Blender` executable if `blender` is not on PATH. `--device CPU` works without Metal. `--mode preview` writes the editable scene and local review poses; `--mode export` writes the scene and complete runtime sequence; `--mode all` does both. To experiment without overwriting the checked-in proof, use `--output .build/candidate-experiment` and `--review .build/candidate-experiment-review`.

Review outputs include `hero.png`, true orthographic `front.png`, `side.png`, `back.png`, `clay.png`, `anticipation.png`, `airborne.png`, and `landing.png`. The 768-pixel review images are not runtime-size evidence. The native view measures the 96-point presentation independently.

## Validate and export comparison media

```sh
python3 tools/CandidateReview/verify_assets.py
blender --background art/candidates/proof-v01/acorn-hopper/acorn-hopper.blend \
  --python-exit-code 1 --python tools/CandidateReview/verify_blend.py
blender --background art/candidates/proof-v01/moss-mouse/moss-mouse.blend \
  --python-exit-code 1 --python tools/CandidateReview/verify_blend.py
tools/CandidateReview/.build/CandidateReview.app/Contents/MacOS/CandidateReview --check
bash tools/CandidateReview/render-media.sh
```

`render-media.sh` requires FFmpeg. It exports a PNG comparison, 30-fps MP4, and looping GIF under `.build/candidate-review/`. This media uses the actual exported PNGs and their root offsets. It is labeled as an offline comparison, not a desktop recording; GIF timing and a chat viewer's scaling are not native timing or point-size evidence.

The asset check validates all 98 unique PNGs, dimensions, clear borders, animation margins, 24-frame timing, signed root travel, measured rig positions, and grounded stance. The saved-scene check reopens each `.blend` in a new process and compares its evaluated animation to the exported contact measurements. A planted foot must remain fixed; contacts are not inferred from the intended motion alone. Native checks exercise both directions on both backgrounds and confirm that image submissions and display links stop at the end.

Numerical checks do not establish a pixel-perfect match to the concept sheets or artistic approval. The current work proves that these designs can be built, edited, animated, and displayed at small size. Facial appeal, leaf motion, and the preferred candidate still require visual selection before a full animation library is produced.

## Provenance

The concepts were explored using AI-generated images. These mesh constructions, rigs, materials, and authored poses were created specifically for Spriglet in Blender, with no third-party model assets. The repository's MIT license applies. `build.json` records the Blender version, geometry/control counts, render settings, and builder/helper hashes. `motion.json` contains reproducible authored contact data. Personal concept sheets, render comparisons, and machine check reports remain local.
