# Character sample validation

These tools check the authored Sprout sample and the real native renderer/desktop controller. They have no third-party dependencies, change no artwork or app settings, and do not launch Blender. The native executable opens disposable windows only when explicitly run.

## Asset checks

After the exporter publishes its final manifest, run from the repository root:

```sh
mkdir -p .build/character-validation
python3 tools/CharacterSampleValidation/validate_assets.py \
  Sources/Spriglet/Resources/SproutSample/manifest.json \
  --contacts art/sprout/sample-v01/contact-samples.json \
  --output .build/character-validation/assets.json
```

The reader verifies the 448 × 448 pixel / 224 × 224 point / 30 fps contract; bounded local paths; PNG chunk CRCs, scanline decoding, RGBA dimensions and transparency; clear canvas edges; and signed root travel. PNGs are processed sequentially, retaining only clip endpoints for image comparison.

The contact check adds each frame's cumulative root offset to its projected sole markers. Contiguous planted intervals must remain within the animator's declared **0.05 export pixel** drift and **0.00001 authoring unit** ground-height tolerances. It requires real contact coverage for both feet in both directions. Ground-height error is measured against `worldGroundZ`; the per-foot `groundHeight` field is the reported marker height, not the plane. Endpoint armature-space matrices are compared at the neutral and petted transitions with the authored 0.00001 element tolerance.

The report distinguishes passed numerical checks, failures, and pending evidence. It exits **0** for all numerical checks passed, **1** for failure, and **2** for incomplete evidence. Endpoint pixel differences are observations without a guessed artistic threshold. The report also supplies independently measured opaque/clear points for the native hit-mask check, including a vertically asymmetric pair.

The limited PNG decoder follows the [current W3C PNG Recommendation](https://www.w3.org/TR/png-3/) for chunk integrity, all five scanline filters, and unassociated alpha. It intentionally accepts only the export's noninterlaced 8-bit RGBA format. Numeric alpha checks do not establish attractive edges or color-managed compositing.

## Native 224-point fixture

Build the fixture without launching it:

```sh
tools/CharacterSampleValidation/build-native-check.sh
```

Then run the exact executable after the asset report is ready:

```sh
tools/CharacterSampleValidation/.build/native/NativeSampleCheck \
  --resources Sources/Spriglet/Resources/SproutSample \
  --asset-report .build/character-validation/assets.json \
  --output .build/character-validation/native-lifecycle.json
```

The roughly one-minute check places the actual 224-point nonactivating pet panel over fixed light and dark backgrounds. It runs idle → right walk → pet → settle on light, then the leftward sequence on dark. It records panel/view sizes and backing pixels, accepted image/offset pairs, frame-buffer underruns, cancellation, coalesced input, and stopped work after completion. It deliberately rejects one movement callback and separately pauses inside a callback that returns true, checking that a cancelled generation cannot commit a stale image.

WindowServer may round the panel's origin to whole points. The report retains that raw quantization error as an observation. Its placement check requires the actual panel origin **plus the actual child image-layer offset** to match each authored target within **0.001 point**; the requested renderer offset and desktop offset must agree with the actual layer geometry. A separate walk → queued pet/settle → reverse walk verifies that the subpoint residual survives request boundaries and that final travel is cumulative. These are application geometry checks, not an atomic compositor-presentation measurement.

The same build also creates an ad-hoc signed `.build/CharacterSampleValidation.app` with bundle ID `dev.spriglet.character-sample-validation`. It requests no entitlements or permissions. Window-specific screenshot tools may capture the background board without the separate floating panel. For a controllable review visible to those tools, use the embedded mode with absolute arguments:

```sh
open -n "$PWD/tools/CharacterSampleValidation/.build/CharacterSampleValidation.app" --args \
  --resources "$PWD/Sources/Spriglet/Resources/SproutSample" \
  --asset-report "$PWD/.build/character-validation/assets.json" \
  --output "$PWD/.build/character-validation/native-review.json" \
  --embedded-review --review-hold
```

`--embedded-review` places the same live `PetRenderView` inside the background board at exactly 224 points. Its display link selects each authored PNG and moves the view using that same frame's root offset. It checks both finite sequences, native size, clear/opaque hit probes, buffering, and stopped work after settlement. The JSON separates these measurements into `embeddedPlayback`; this mode does not exercise desktop window travel, external compositing, or input routing. It never substitutes an offline review image. The view uses AppKit's current [addSubview(_:)](https://developer.apple.com/documentation/appkit/nsview/addsubview(_:)) API, verified against the installed SDK.

After the automatic sequences, **Light sample** and **Dark sample** replay the live finite sequence on either background. **Finish review** closes the fixture and writes its report. Replays during the held review are for visual inspection; the measured playback records cover the initial automatic sequences. `--review-hold` also works after the separate-panel lifecycle checks. The plain binary remains available for automated runs. When the `.app` is launched without arguments, it locates this checkout relative to its build directory and writes an ignored `.build/character-sample-native-default.json` report.

The separate-panel lifecycle report includes warm, settled, paused, hidden, and final ten-second rest intervals. CPU percentage covers this fixture process relative to one core; footprint includes the review window and decoder. These observations are not the app's normal memory baseline, GPU/WindowServer work, energy, or battery measurements. The embedded review does not sample CPU or memory. Frame submissions and display-link callbacks do not prove atomic compositor presentation.

Closing the window or choosing Quit before the measured checks finish writes a cancellation result. `--review-only` retains the separate panel, runs its light/dark sequences, and skips interruption scenarios. Both review modes leave the final view open for up to 30 seconds unless `--review-hold` waits for the review controls instead. The full app's policy, saved preferences, and lifecycle integration are checked separately by the app probe.

Observe both backgrounds at their actual display size and retain separate UI evidence for likeness, edge halos, readable movement, and foot contact. A reported 224-point frame alone does not certify appearance. The implementation uses the view-associated [display link](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)); stopping it uses [invalidate()](https://developer.apple.com/documentation/quartzcore/cadisplaylink/invalidate()). Native scale is read from AppKit geometry and the window's [backing scale](https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor).

## Test the validators

```sh
./scripts/test.sh
python3 -m unittest discover -s tools/CharacterSampleValidation -p 'test_*.py' -v
```

The Swift suites cover exact 30 fps boundaries and the representable instant before them, integer prefetch selection, finite completion, cumulative/reversed travel, malformed manifests, and fitting the whole trajectory before starting. The independent PNG/contact tests include corrupt data, all filter types, unsynchronized movement, absent stance coverage, ground errors, and mismatched endpoint poses.

Generate reports from the resource set you are testing and keep them under `.build/`. Machine observations and local review records are not part of the source repository.
