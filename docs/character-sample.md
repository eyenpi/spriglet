# Sprout — first playable character sample

The sample carries the selected A · Sprout design into the app: warm olive velvet, an ivory face and belly, small dark eyes, peach cheeks, and an asymmetric leaf silhouette. Its editable Blender rig produces a finite **idle → short walk → petting reaction → settle** sequence. Both walking directions are rendered under the same camera and lights.

## Play and inspect

Build with `./scripts/run.sh`, open **Prototype Controls…** from the leaf menu, and choose **Play Character Sample**. **Idle**, **Pet**, **Walk Left**, and **Walk Right** let you inspect the same assets separately. The full sample chooses a direction with room for the complete path. Explicit walking directions report insufficient room before starting.

For a review without modifying saved preferences, quit an existing Spriglet instance and launch the built executable with `--sample-review`. That mode opens controls, starts the sample, and disables automatic behavior. The [native validation fixture](../tools/CharacterSampleValidation/README.md) supplies known light and dark backgrounds with a real 224-point pet window.

The offline comparison movies in [sample-v01/review](../art/sprout/sample-v01/review) combine the exact runtime PNGs and root offsets over light and dark colors. They are asset reviews, not recordings of the window compositor. A video viewer may scale them; the native fixture records the actual point and backing-pixel dimensions.

## Animation contract

| Clip | Frames at 30 fps | Duration | Result |
| --- | ---: | ---: | --- |
| Idle | 37 | 1.233 s | A breath, small look, and blink; returns to neutral |
| Walk right | 73 | 2.433 s | Turns, takes four steps, turns back; travels +78.4 points |
| Walk left | 73 | 2.433 s | Separately rendered opposite walk; travels −78.4 points |
| Pet | 34 | 1.133 s | Soft head tilt, leaf motion, happy closed eyes |
| Settle | 25 | 0.833 s | Starts in the pet reaction's final pose and returns to neutral |

One complete sequence is **169 frames / 5.633 seconds**. The bundle contains 242 clip frames and two static poses. Sleep and wake select a still image; they are not additional animated clips. The existing behavior planner's blink/look/stretch requests currently share the authored idle asset, and the UI presents that honestly as **Idle**.

Every PNG has a 448 × 448 RGBA canvas displayed at 224 × 224 macOS points. At a 2× backing scale one source pixel corresponds to one backing pixel. The body occupies less than the full canvas, leaving room for leaf and limb motion. The projected ground anchor is recorded in the manifest using bottom-left pixel coordinates. Its point equivalent is obtained by dividing by two.

Each frame in [manifest.json](../Sources/Spriglet/Resources/SproutSample/manifest.json) names its PNG and a cumulative `rootOffsetPoints` within that clip. The timeline carries the previous clip's final offset into the next clip, so entering pet or settle cannot snap the window back to its starting position.

The normal Blender Action contains real world travel. For export, a separate Stage bone compensates for that travel to keep the character inside its fixed image canvas. The manifest restores the same displacement to the desktop window. The travel axis is the runtime camera's horizontal direction. Planted feet remain in world contact while the root advances; turn-in and turn-out steps move one foot at a time. The contact record tracks projected sole samples and ground height through stance intervals, including turns.

The runtime uses one current [`NSView.displayLink(target:selector:)`](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)) callback to select a frame and apply its corresponding window offset. There is no independent window easing curve. If the next image is not decoded, authored time, image, and root displacement all hold. The app checks the complete trajectory against the usable display area before play and interrupts if the display changes. It does not clamp an ongoing walk against an edge.

AppKit rounded the requested panel origins in the first native run, producing up to 0.873 points of error despite matched image/frame metadata. The desktop host now reads back the actual window origin and applies the remaining fraction to the child image layer before committing the frame. The effective position includes that remainder when another request begins. Static poses, cancellation, resizing, saved placement, nudges, and dragging preserve precise placement; hit testing follows the shifted image.

The image and window offset are coordinated in one application callback with implicit layer animations disabled. Native validation compares the actual panel origin plus the actual layer offset against the authored target, retaining the original 0.001-point tolerance. This is not proof of atomic physical presentation by WindowServer; the reported geometry and separate appearance review establish the narrower behavior recorded below.

## Editable source and rendering

Open [sprout-sample-v01.blend](../art/sprout/sample-v01/sprout-sample-v01.blend) in **Blender 5.2.1 LTS**. Select **Sprout Rig** and enter Pose Mode. Fourteen named controls cover the Stage/root, body, head, ears, crown, paws, feet, eyelids, and tail. Separate slotted Actions contain each clip, a static nap, and the complete travelling sample. The file opens with an overview camera; the locked runtime camera remains in the scene.

The 72,985 short native hair strands use attachment UVs, a `rest_position` attribute, and Blender's current [Deform Curves on Surface](https://docs.blender.org/manual/en/5.2/modeling/geometry_nodes/curve/operations/deform_curves_on_surface.html) node. They follow the armature-deformed meshes. The sole band is groomed clear of the ground. Ordinary rig edits keep the attachment relationship; changing topology requires regenerating the attachment data and groom.

The character retains the revised design's olive `63662E`, ivory `F1DBAB`, and leaf `536730` pigments. Its Cycles material uses short Huang hair with reduced first reflection for a velvet appearance, with AgX, Look None, and exposure zero. The runtime camera and three area lights are shared by every frame and both directions. Opposite walks are not mirrored PNGs. Source geometry, materials, armature, groom, cameras, and lights are all stored in the `.blend` without external texture or add-on dependencies.

A bounded Cycles shadow catcher supplies the soft contact shadow. Blender's current [compositing node group](https://docs.blender.org/api/5.2/bpy.types.Scene.html) denoises RGB while restoring the raw render alpha, avoiding denoiser residue outside the character. PNG dithering is disabled. Every exported frame must have exactly zero alpha on its outer border; light/dark review separately checks the visible fur and shadow edges.

The [build metadata](../art/sprout/sample-v01/sample-build.json) identifies the saved model, Blender build, scripts, rendering configuration, and runtime manifest by hash. The [saved-model verifier](../art/sprout/scripts/verify_sample.py) independently reopens the file and checks its rig, mesh contacts, groom attachments, and export configuration; its [retained result](../art/sprout/sample-v01/verification.json) records the run. The historical [review-01](../art/sprout/README.md) source remains unchanged. Rebuilding creates a fresh model from that source and the motion scripts; it does not merge manual edits into the generated rig.

The builder/exporter runs only in an isolated background Blender process. It does not operate a user's open editing session. To regenerate the sample after preserving any manual work:

```sh
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --python-exit-code 1 \
  --python art/sprout/scripts/build_sample.py -- \
  --mode export --resolution 448 --samples 48 --device METAL
```

This writes the generated model and metadata in `art/sprout/sample-v01` and the app frames in `Sources/Spriglet/Resources/SproutSample`. Use version control or a separate checkout before regeneration. `--device CPU` is the explicit fallback if the machine has no supported Metal device. Blender's current [Cycles GPU documentation](https://docs.blender.org/manual/ko/5.2/render/cycles/gpu_rendering.html) and an actual render verified Metal on this Mac. Offline Blender render cost does not predict app playback cost.

## Native renderer and resource policy

A child [`CALayer`](https://developer.apple.com/documentation/quartzcore/calayer/contents) holds the current `CGImage`. Keeping the image on a child layer avoids overwriting the view's own backing contents. Once a finite sequence completes, its display link is invalidated and the last image remains visible. Pause, hide, display interruption, and reset cancel pending decoding and queued work with a generation guard.

ImageIO decodes frames with [`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately). Animated frames use explicit [`@concurrent`](https://www.swift.org/blog/swift-6.2-released/) work away from the main actor, then pass SDK-supported sendable images back for presentation. The two still poses are decoded at view construction. The animation buffer is capped at 12 images; static images and the currently displayed image may also be retained. Missing or invalid assets produce a visible controls error and disable motion.

The app remains SwiftUI/Observation for controls and AppKit for the transparent nonactivating panel. Development uses Xcode 26.6, Swift 6.3.3, and macOS SDK 26.5 with Swift 6 semantics, complete concurrency checking, and warnings treated as errors. New APIs were checked against current Apple/Swift documentation and the installed SDK. No deprecated Core Video display-link API or legacy Blender particle-hair system was introduced.

## Validation evidence

The retained results in [docs/results/character-sample](results/character-sample) identify the actual source, exported assets, checks, and observations. The [validation README](../tools/CharacterSampleValidation/README.md) explains how to reproduce the native fixture and asset/contact checks. The [review exporter](../tools/CharacterSampleReview/README.md) reproduces both background-comparison movies.

| Check | Retained result |
| --- | --- |
| Swift Testing | [61 test functions / 276 expanded cases / 8 suites passed](results/character-sample/tests.json) |
| Validator regression tests | [11 Python tests passed](results/character-sample/tests.json) |
| Final assets | [10 checks passed over all 244 PNGs](results/character-sample/assets.json); zero alpha on every perimeter |
| Saved Blender rig | [Readback passed](../art/sprout/sample-v01/verification.json): 14 controls, 11 bound groom objects, 352 attachment probes, 164 planted-foot mesh checks |
| Separate native panel | [22 checks passed](results/character-sample/native-lifecycle.json), including zero measured effective-origin error, no mismatched frame/offset pairs, no buffer underruns, and walk → pet → second-walk continuity |
| Live native appearance | [14 checks passed](results/character-sample/native-review.json), with [CUA appearance observations](results/character-sample/ui-observations.json) at 224 points over light and dark backgrounds |
| Full Release app | [22 probe checks passed](results/character-sample/runtime-probe.json), including the complete sample, queued input, static naps, cancellation, and quiet rest |
| Repeated interaction | [100 cycles / 20 functional checks passed](results/character-sample/soak.json), including hide/show, pet → settle, and 45 seconds of quiet final rest |

Debug and Release builds both passed; all 245 bundled resource files matched their source hashes. The actual model's maximum sampled groom-root error was 4.81 × 10⁻⁷ authoring units. Its planted foot meshes met the ground within 7.45 × 10⁻⁹ units. Adding the manifest travel to the projected sole markers produced a maximum stance drift of 3.31 × 10⁻⁵ export pixels.

The [first native run](results/character-sample/native-lifecycle-before-compensation.json) is retained as a diagnostic failure: the old callback matched metadata but did not correct window rounding. The final run measures actual layer geometry and passes the unchanged tolerance. These are application geometry observations, not GPU frame-presentation claims.

CUA's capture of the review board omits a separate floating overlay. For appearance inspection, the fixture therefore places the **same live `PetRenderView`** inside its AppKit board at 224 points and plays the actual clips on each background. That review confirms native size, readability, alpha edges, and localized shadows. The separate-panel run independently measures the real desktop controller and its compensated movement. The light-background shadow looks grainier when enlarged to 448 pixels; it was accepted at native size for this sample.

The Release probe's final ten-second rest recorded zero image assignments, display-link callbacks, movement frames, or automatic actions. Physical footprint was 18.36 MiB at the end of that interval. The separate 100-cycle soak completed in 390.36 seconds with all 20 functional checks passing. Its warmed baseline and final settled footprint both rounded to 18.22 MiB; the largest sampled footprint was 18.59 MiB. All three final 15-second rest intervals recorded zero image, display-link, movement, or automatic-action activity and no pending behavior. These observations are not production memory or battery budgets. The [environment record](results/character-sample/environment.json) ties the evidence to the actual source and executable hashes. Historical phase 3 renderer, soak, and Metal measurements are not reused as evidence for this sample.

## Scope after this sample

This establishes one character's editable source → rendered frames and motion metadata → native playback → validation pipeline. The next production work is to expand the animation library and personality within measured storage and memory budgets. Physical cross-app input/focus, transparent-pixel routing, Spaces/full-screen/Stage Manager, monitor changes, real sleep/wake, sustained compositor/GPU profiling, battery life, and signing/distribution still require their broader acceptance passes. No account, networking, social features, or desktop surveillance has been added.
