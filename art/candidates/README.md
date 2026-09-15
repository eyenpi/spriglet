# Character candidates · transitions 03

Two original editable Blender characters explore a smaller, quicker companion.
Both are retained; `proof-v01` and `refinement-v02` remain unchanged baselines.

| Candidate | Construction and personality | Controls | Travel |
| --- | --- | ---: | --- |
| [Acorn Hopper](transitions-v03/acorn-hopper/acorn-hopper.blend) | Round cheeks, scalloped chestnut cap, folded leaf, little raised paws; springy and pleased with itself | 9 bones | One squash-and-hop, 0.8 seconds |
| [Moss Mouse](transitions-v03/moss-mouse/moss-mouse.blend) | Low bean body, round head, independent leaf ears, sprig tail, four feet; curious and darting | 11 bones | Two directional bounds, 0.8 seconds |

Both have softer colors, larger eyes, friendlier brows, matte closed-eye creases,
happy smiles, and delayed secondary motion. V03 retains the V02 models and adds
authored sleep/wake transitions and state-aware playback. It covers transitions
among the current ready, curious, moving, happy and sleeping experiences, not
every possible gesture or a claim of a pixel-perfect concept match. The shipping
Sprout artwork, desktop behavior and preferences are unchanged.

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
| fallAsleep | 30 | Drowsy blink, failed attempt to stay awake, soft squash and lowered cap/ears |
| wakeUp | 24 | Begins in the exact sleep pose; eyes open, tiny stretch, delayed ear/cap recovery |
| sleep | 1 held pose | Closed eyes, softened body, lowered leaves/ears; no ticking loop |

There are 194 runtime PNGs per character: 192 finite animation frames plus rest
and sleep stills. Unlike proof-v01, interactions are not rest aliases. Finite
gestures end with a static image.

### Transition contract

The ready pose is a shared junction, not a separate pause inserted between
actions. Curious and movement clips start/end there. Pet ends happy; settle
connects happy back to ready. FallAsleep connects ready to asleep; wakeUp connects
asleep back to ready. Every entrance/exit matches both skeletal pose and facial
expression; feet remain grounded through the stationary transitions.

The player finishes the current action before changing states, including the
landing of a hop and the settle after affection. Only the latest pending intent
is retained. A request made during fallAsleep is resolved **after** that action
finishes, so the wake-up prefix cannot be omitted by stale sleep state. Movement
and petting from sleep automatically include wakeUp. Wake/rest from an awake
gesture settles it without another idle animation. No per-frame blending or
crossfading is used, and no claim is made of instantaneous mid-air interruption.

The new manifest schema 2 requires all seven finite clips. Schema 1 still accepts
exactly the five shipping clips. `SampleTransitionPlan` has an explicit legacy
fallback that never requests missing sleep/wake assets.

## Native review

From the repository root:

```sh
bash tools/CandidateReview/build.sh
open tools/CandidateReview/.build/CandidateReview.app
```

The separate app uses the shipping `PetRenderView` with an additive state-aware
`transition(to:)` entry point, and the unchanged `SampleImageDecoder`. Existing
shipping replay/action methods retain their behavior. Enlarged animated views
show poses in place; light/dark cards below show 96-point canvases with authored
travel. Controls are **Curious**, **Hop / dash**, **Pet both**, **Nap**,
**Wake / rest**, and **All states**. Movement alternates direction within the
card. All states plays a finite guided sequence. New clicks replace its remaining
steps and the pending intent; they do not reset the current pose or position.

It opens directly into the interactive comparison without waiting for automated
tests. It changes no Spriglet settings or bundled artwork. Running with `--check`
writes checks and a snapshot of its own view under `.build/candidate-transitions/`. The report
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
Export both current sets after a builder change: validation rejects stale hashes
for V03. Historical V02 source hashes are retained, not compared to today's builder.

Review images include `hero`, orthographic `front`/`side`/`back`, `clay`,
`anticipation`, `airborne`, `landing`, `idle`, `pet`, `sleep`, `fallAsleep`, and `wakeUp`.
Enlarged renders are artistic inspection, not native-size or timing evidence.

## Verify and export comparison media

```sh
python3 -m unittest discover -s tools/CandidateReview -p 'test_*.py'
python3 tools/CandidateReview/verify_assets.py
blender --background art/candidates/transitions-v03/acorn-hopper/acorn-hopper.blend \
  --python-exit-code 1 --python tools/CandidateReview/verify_blend.py
blender --background art/candidates/transitions-v03/moss-mouse/moss-mouse.blend \
  --python-exit-code 1 --python tools/CandidateReview/verify_blend.py
tools/CandidateReview/.build/CandidateReview.app/Contents/MacOS/CandidateReview --check
bash tools/CandidateReview/render-media.sh
```

Media export needs FFmpeg. It creates a PNG, 30-fps MP4, looping GIF, and
affection/sleep/transition stills under `.build/candidate-transitions/`, using exact
exported PNGs and cumulative root offsets across every state change. It is labeled
as an offline comparison, not a desktop
recording. Chat scaling and GIF timing do not establish native size or pacing.

The verifier checks all 388 PNGs, clear borders and margins, clip lengths,
genuine animation, root metadata, evaluated foot contacts, facial driver output,
and matched pose boundaries. Separate Blender processes reopen the saved files
and compare all actions with exported contact and expression measurements.
Regression cases cover sliding despite matching intent, stance breaks, missing
controls, malformed endpoints, and non-finite measurements.

Native checks exercise 24 individual sequences (six actions × two characters ×
two backgrounds), all 25 ordered experience pairs with requests during playback
(100 handovers), and rapid latest-request replacement (four more handovers).
They measure the actual clip order, zero host-position jumps at request boundaries,
buffering, final state, quiet sleep/rest, and cancellation of active/queued work.
Test fixtures explicitly reset between scenarios; interactive controls never do.
Core tests independently cover all 36 ordered intents, including both directions.
These establish implementation properties, not artistic approval,
all-frame GPU presentation, or acceptance as separate desktop panels.

## Provenance

AI-generated concept sheets informed the original exploration. The meshes,
rigs, materials and poses were authored for Spriglet with no third-party models.
The repository's MIT license applies. `build.json` records Blender, geometry,
controls, render settings and source hashes. `motion.json` records authored and
evaluated contacts/expressions and the named pose-boundary graph. Named Blender
Actions also carry `starts_at` / `ends_at` metadata. Concept sheets, render comparisons and machine
reports remain local. The older [first proof](proof-v01/) is preserved; its static
interaction aliases and model details are not the current library.
