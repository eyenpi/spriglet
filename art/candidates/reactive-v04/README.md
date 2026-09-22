# Acorn authored reactive phrase

This separate Blender library adds an alert glance, directional turn, short
hop and planted brake. It does not rename or alias the original idle/walk clips.
The complete phrase is finite and returns to the same declared ready pose.

```sh
python3 tools/CharacterAssets/export_reactive_clips.py
python3 tools/CharacterAssets/export_reactive_clips.py --check
python3 tools/CharacterAssets/export_reactive_clips.py --verify-saved
python3 -m unittest discover -s tools/CharacterAssets -p 'test_reactive_clips.py'
# Optional Pillow and FFmpeg for ignored storyboards and the finite preview:
python3 tools/CharacterAssets/export_reactive_clips.py \
  --proof .build/reactive-v04
```

The exporter reads the original v03 scene without altering it. It saves new
editable Actions in `acorn-reactive.blend`, retains the original 448-pixel camera,
materials, lighting, fixed sample seed, denoising and alpha treatment, and
exports 30-fps PNGs with measured contacts and root displacement.

| Clip | Frames | Boundary |
| --- | ---: | --- |
| `reactive.alert` | 12 | ready → alert |
| `reactive.turn.left/right` | 12 each | alert → directed.left/right |
| `reactive.hop.left/right` | 26 each | directed.left/right → landed.left/right |
| `reactive.brake.left/right` | 16 each | landed.left/right → ready |
| `reactive.dismiss` | 12 | alert → ready |
| `reactive.abort.left/right` | 12 each | directed.left/right → ready |

There are 156 frame references across ten clips. Each shared state has one
canonical PNG, so adjacent stages use exactly identical images. Ready uses the
new layered-rest canonical from `rest-rig-v04`; it deliberately does not claim
to equal the historical monolithic v03 frame. The intermediate directed and
landed states are checked for identical in-place skeletons and expressions
before expensive rendering begins. Source hashes record this dependency.

At Standard's 96-point canvas, the hop covers 40 points and rises about 7.7
points. A body turn and compression precede launch. Paws and feet tuck during
flight; the cap and leaf trail the body. Both soles return to the same ground
plane before the final compression unwinds. Root translation happens only
between takeoff and landing. The complete alert/turn/hop/brake phrase lasts
2.2 seconds including shared boundary frame durations.

`clips.json` is a schema-3-compatible clip-library fragment, not a standalone
character package. Stable string IDs describe the ten clips and five new
pose states. Clips own body, face, shadow and secondary motion exclusively.
`behavior.json` separately declares the approach threshold, personality rarity,
safe travel, cooldown, token budget, and semantic alert/dodge candidates. These
values are versioned character data rather than branches in the application.
Markers identify planted feet and safe redirection at state boundaries, and
the brake ends at a settled marker. The hop emits `footDown` on landing.
`motion.json` contains independently evaluated sole positions, facial-driver
values, pose matrices and world roots for verification. Those bulky values do
not belong in playback frame metadata.

Playback must pair each image with its exact root offset and accumulate travel
across stages. A new request can redirect only at a declared state boundary;
it must not cancel a hop in the air. Reduced Motion uses the package's local
blink fallback and does not run this relocation phrase. Behavior arbitration
must make dodging rare and must not make clicking or dragging unreliable.
The grounded `dismiss` and `abort` bridges let direct interaction cancel a
dodge before launch; they return the alert or turned pose to ready without
moving either planted foot. A launched hop must land before braking.

For an intentional additive extension, `--reuse-unchanged` can retain existing
renders only when the original Blender source, ready canonical, Blender version,
sample/device settings, and **every evaluated pose, face, root and contact sample**
match the new authoring run. The saved Blender file and metadata are still
regenerated. A normal export always renders fresh.

The three ignored storyboards show the actual rendered frames at 72, 96 and
120-point canvases, each on light, dark and busy static backgrounds. The finite
MP4 uses real 30-fps timing and cumulative roots. These are offline source
proofs, not a desktop capture or a claim of native presentation, energy, or
hardware acceptance. Art should be inspected there and then in the app before
the library is promoted into shipping resources.
