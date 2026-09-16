# Shipping Acorn Hopper

The app ships exactly one pet: **Acorn Hopper**. There is no character picker,
selection preference, or hidden gallery. Moss Mouse remains editable future
source material under `art/candidates/`; the original Sprout frames remain a
legacy schema-1 test fixture and are excluded from the app target.

## Reproducible Blender-to-app export

```sh
python3 tools/CharacterAssets/export_acorn.py
python3 tools/CharacterAssets/export_acorn.py --check
python3 -m unittest discover -s tools/CharacterAssets -p 'test_*.py'
```

The input is the approved `art/candidates/transitions-v03/acorn-hopper/runtime`
export. All 194 PNGs are copied byte-for-byte into
`Sources/Spriglet/Resources/AcornHopper`. The packaged manifest changes only
point-space canvas dimensions and root offsets, from the 224-point authoring
basis to a 96-point standard canvas. Pixels, anchors, 30 fps timing, expressions,
and pose-matched animation boundaries are unchanged. Standard's opaque character
is about 64 points tall; Small / Standard / Large canvases are 72 / 96 / 120 points.
A standard hop travels 102.4 points in 0.8 seconds.

The same exporter also installs `character.json` and the verified cropped
`restRig/` layers from `art/candidates/rest-rig-v04`. The original schema-2
manifest and 194 frames remain byte-identical compatibility assets. Schema 3
normalizes the ten ready-pose clip endpoints to one recomposed neutral image,
preserving every frame count, time, and root offset. The renderer reads this
sidecar first and fails closed if it is invalid.

The rig separates body, cap, leaf, feet, shadow, eyes and finite blink states.
Its 442,100 decoded bytes include the gaze masks. All ranges, pivots and delays
are package data. `package_acorn.py --output DIRECTORY` builds an isolated
candidate; `--check` verifies its metadata and bytes. Native composition and
handoff review are described in [RestRigValidation](../RestRigValidation/README.md).

The read-only check rejects altered metadata, changed PNG bytes, missing frames,
and extra files. Candidate verification separately checks the original Blender
export and transition endpoints. Release validation compares every shipped
resource with this normalized export and rejects bundled legacy/future pets.

## Small extension boundary

- `PetAssetDefinition` identifies the asset directory and default identity.
  `PetRuntime` receives one definition and resource bundle at construction, with
  Acorn Hopper as the production default.
- `PetRenderView` receives an explicit resource directory. It knows neither
  character names nor UI selection, and the manifest owns native point size.
  The existing `SproutSampleManifest` type name remains for source compatibility;
  its versioned file format and timeline are already character-independent.
- `PetDisplaySize` applies relative multipliers to that authored size. Existing
  settings and saved custom names are preserved; new profiles default to Acorn.
- Shared finite transitions finish the current landing/settle before the latest
  pending request. Sleeping actions include the authored wake-up bridge. A held
  click freezes the image and root together; a real drag cancels movement.
- A future picker can supply a different definition at the composition boundary
  and introduce an explicitly versioned selection preference then. It does not
  need its own renderer, animation clock, or copy of desktop behavior.

Resource discovery uses Foundation's existing
[`Bundle.url(forResource:withExtension:subdirectory:)`](https://developer.apple.com/documentation/foundation/bundle/url(forresource:withextension:subdirectory:)).
This milestone introduces no new platform framework. App and native-harness
builds check Swift 6 concurrency against the installed Xcode SDK.

The native everyday harness covers held hops, nap-entry interruption, sleeping
primary activation, wake-before-toy timing, all three sizes, and bounded quiet
completion. These application-level checks do not certify compositor behavior,
physical click routing, or long-term battery use.
