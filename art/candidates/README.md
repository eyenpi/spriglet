# Character candidates · refinement 02

Two original editable Blender characters explore a smaller, quicker companion.
Both are retained; `proof-v01` remains an unchanged comparison baseline.

| Candidate | Construction and personality | Controls | Travel |
| --- | --- | ---: | --- |
| [Acorn Hopper](refinement-v02/acorn-hopper/acorn-hopper.blend) | Round cheeks, scalloped chestnut cap, folded leaf, little raised paws; springy and pleased with itself | 9 bones | One squash-and-hop, 0.8 seconds |
| [Moss Mouse](refinement-v02/moss-mouse/moss-mouse.blend) | Low bean body, round head, independent leaf ears, sprig tail, four feet; curious and darting | 11 bones | Two directional bounds, 0.8 seconds |

Both have softer colors, larger eyes, friendlier brows, matte closed-eye creases,
happy smiles, and delayed secondary motion. This is a basic interaction library,
not every possible gesture or a claim of a pixel-perfect concept match. The
shipping Sprout, desktop behavior, and preferences are unchanged.

## Animation library

All clips use 30 fps, 448 × 448 RGBA source frames, and a 224-point source
manifest displayed on a **96-point review canvas**. The opaque pet is smaller
than the canvas. Travel is approximately 101–102 review points in 0.8 seconds.

| Action | Frames | Behavior |
| --- | ---: | --- |
| idle | 42 | Finite curious tilt, blink, and ear/leaf motion; returns to rest |
| walkRight / walkLeft | 24 each | Anticipation, travel, grounded landing, settle |
| pet | 30 | Happy eyes and smile; acorn raises paws, mouse leans into affection |
| settle | 18 | Starts in the exact pet endpoint pose and returns to rest |
| sleep | 1 held pose | Closed eyes, softened body, lowered leaves/ears; no ticking loop |

There are 140 unique runtime PNGs per character. Unlike proof-v01, idle, pet,
settle and sleep are not rest aliases. Finite gestures end with a static image.

## Native review

From the repository root:

```sh
bash tools/CandidateReview/build.sh
open tools/CandidateReview/.build/CandidateReview.app
```

The separate app uses the unmodified shipping `PetRenderView` and
`SampleImageDecoder`. Enlarged animated views show poses in place; light/dark
cards below show 96-point canvases with authored travel. Controls are **Curious**,
**Hop / dash →**, **← Replay**, **Pet both**, **Nap**, and **Rest**. Pet plays pet
and settle together. Nap is a held pose, not an authored fall-asleep transition.

It changes no Spriglet settings or bundled artwork. Automatic checks and a
snapshot of its own view go under `.build/candidate-refinement/`. The report
records the display's measured backing scale instead of assuming Retina.

## Edit and rebuild in Blender

Open either current `.blend` in **Blender 5.2.1 LTS**. Press Space to play the
default **IN-PLACE INSPECTION** Action without leaving the close camera. A
`START HERE` text block explains the file. Choose another named rig Action and
set its frame range from the table. Its face follows automatically: rig custom
properties `Blink` and `Happy` drive editable eye, eyelid, and smile shape keys.
Body and face do not need separate action selection. Travel Actions retain real
world movement; the unkeyed `Stage` control compensates it only during export.

Construction uses ordinary meshes, vertex colors, bone groups, simple material
drivers, and retained curve source datablocks. There are no external textures,
linked libraries, add-ons, grooms, or generated image-to-3D meshes. Cap relief is
modeled into one shell with a rounded lip. Leaves are closed volumes. A bounded
Cycles catcher supplies contact shadows; denoising preserves raw alpha coverage.

The [builder](scripts/build_candidates.py) imports geometry/action helpers from
`art/sprout/scripts/` without loading or changing the shipping Sprout scene.

```sh
blender --background --factory-startup --python-exit-code 1 \
  --python art/candidates/scripts/build_candidates.py -- \
  --candidate acorn-hopper --mode all --samples 40 --device METAL

blender --background --factory-startup --python-exit-code 1 \
  --python art/candidates/scripts/build_candidates.py -- \
  --candidate moss-mouse --mode all --samples 40 --device METAL
```

On macOS, use the Blender app's `Contents/MacOS/Blender` executable if needed.
`--device CPU` works without Metal. Initial Metal shader compilation can take
longer than subsequent renders. `--mode preview` writes the scene and review
poses; `--mode export` writes the scene and runtime; `--mode all` does both.

For experiments, use `--output .build/candidate-experiment` and
`--review .build/candidate-experiment-review` to preserve checked-in assets.
Export both full sets after a builder change: validation rejects stale hashes.

Review images include `hero`, orthographic `front`/`side`/`back`, `clay`,
`anticipation`, `airborne`, `landing`, `idle`, `pet`, and `sleep`.
Enlarged renders are artistic inspection, not native-size or timing evidence.

## Verify and export comparison media

```sh
python3 -m unittest discover -s tools/CandidateReview -p 'test_*.py'
python3 tools/CandidateReview/verify_assets.py
blender --background art/candidates/refinement-v02/acorn-hopper/acorn-hopper.blend \
  --python-exit-code 1 --python tools/CandidateReview/verify_blend.py
blender --background art/candidates/refinement-v02/moss-mouse/moss-mouse.blend \
  --python-exit-code 1 --python tools/CandidateReview/verify_blend.py
tools/CandidateReview/.build/CandidateReview.app/Contents/MacOS/CandidateReview --check
bash tools/CandidateReview/render-media.sh
```

Media export needs FFmpeg. It creates a PNG, 30-fps MP4, looping GIF, and
affection/sleep stills under `.build/candidate-refinement/`, using exact exported
PNGs and root offsets. It is labeled as an offline comparison, not a desktop
recording. Chat scaling and GIF timing do not establish native size or pacing.

The verifier checks all 280 unique PNGs, clear borders and margins, clip lengths,
genuine animation, root metadata, evaluated foot contacts, facial driver output,
and matched pose boundaries. Separate Blender processes reopen the saved files
and compare all actions with exported contact and expression measurements.
Regression cases cover sliding despite matching intent, stance breaks, missing
controls, malformed endpoints, and non-finite measurements.

Native checks exercise 16 finite sequences (four actions × two characters × two
backgrounds), then verify that held sleep submits no further frames and runs no
display link. These establish implementation properties, not artistic approval,
all-frame GPU presentation, or acceptance as separate desktop panels.

## Provenance

AI-generated concept sheets informed the original exploration. The meshes,
rigs, materials and poses were authored for Spriglet with no third-party models.
The repository's MIT license applies. `build.json` records Blender, geometry,
controls, render settings and source hashes. `motion.json` records authored and
evaluated contacts/expressions. Concept sheets, render comparisons and machine
reports remain local. The older [first proof](proof-v01/) is preserved; its static
interaction aliases and model details are not the current library.
