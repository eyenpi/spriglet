# Native rest-rig validation

Run `./tools/RestRigValidation/run.sh` from the checkout on macOS 26 or later
with full Xcode selected. The tool compiles the production
`RestRigScene.swift` and `SampleImageDecoder.swift` with the current core
schema into an ad-hoc signed sandbox app.

The build first runs the shared `tools/CharacterAssets/package_acorn.py` packer
and bundles its generated schema-3 `CharacterPackage` into the signed app. The
packer’s authoritative `ready` pose includes every layer, including
default-opacity blink states needed by a finite phrase.

The validator creates a layer-backed AppKit view for each 72, 96, and 120 point
case. It renders the real Core Animation layer hierarchy and the canonical
`neutral.png` through matching Core Animation surfaces over light, dark, and
busy backgrounds, then compares their RGBA pixels. This detects registration,
grounding, and duplicated-eye regressions in the actual hierarchy without
editing pixels in Python. It also checks finite 160 ms blink and 3.2 s breath
phrases, gaze retargeting while an animation is in flight, stale-completion
cancellation after hide/stop, decoded-byte bounds, and the absence of a display
link in this isolated scene. The committed pixel thresholds are the measured
Core Animation composition baseline for this separated-alpha proof rig; they
are tighter for mean error, changed coverage, grounding, and registration than
for a single anti-aliased edge outlier.

The image comparison is an offscreen sRGB Core Animation check. It does not
certify extended-range or wide-gamut presentation, compositor behavior on every
display, or subjective visual quality; perform the planned interactive CUA
inspection before promoting the proof rig.

The 448-pixel source-resolution comparison additionally establishes exact
registration before downsampling (at most 2/255 channel difference). Native-size
differences include separate alpha-layer resampling and are reported explicitly.
Run the built executable with `--export` to save actual and canonical comparison
PNGs in its sandbox temporary directory, printed in the output. Use `--review`
for a disposable window with the production renderer at all three sizes and
finite blink, breath, gaze, reaction, nap, and wake controls. Closing it stops
all playback. This review changes no preferences or system settings.

Apple references: [layer-backed views](https://developer.apple.com/documentation/appkit/nsview/wantslayer),
[layer rendering](https://developer.apple.com/documentation/quartzcore/calayer/render%28in%3A%29),
[transactions](https://developer.apple.com/documentation/quartzcore/catransaction/flush%28%29),
and [finite animation completion](https://developer.apple.com/documentation/quartzcore/caanimationdelegate/animationdidstop%28_%3Afinished%3A%29).
