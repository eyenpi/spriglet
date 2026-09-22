# Habitat validation

Run `./tools/HabitatValidation/run.sh` for the signed, sandboxed native check.
It builds the current Acorn package and drives the real renderer,
`PetWindowController`, and nonactivating panel through complete and interrupted
floor/upper-habitat/floor visits. The JSON result verifies that:

- the production automatic gate defaults to off;
- host relocation occurs only from the authored semantic `fullyHidden` endpoint;
- the upper panel remains inside the current `visibleFrame` portal bounds;
- the whole visit is mouse-transparent and does not become key or main;
- cancellation returns through the authored exit and re-entry;
- cancellation during the initial floor exit reverses locally without any host
  relocation or stuck click-through state;
- a visible upper visit survives topology invalidation and a simulated safe-area
  shrink, then completes its stationary authored return through the production
  host motion callbacks;
- injected topology, relocation, context, playback, restore, and recovery-stop
  failures all finish or use the proven invisible abort without stranded state;
- the exact previous click-through state, actual floor position, and saved home
  are restored; and
- every declared habitat interruption marker is delivered by native playback;
- decoded frames stay within the package buffer limit; and
- submissions, display-link callbacks, and window movement remain exactly zero
  during a one-second post-settlement interval.

Pass `--preview` to show one complete visit at native size for visual review. The
ordinary check makes its panel transparent to avoid disturbing the desktop.
Neither mode polls system geometry, changes menu-bar or Dock settings, or enables
automatic production visits. The preview is evidence for the current machine
only; notched and non-notched hardware, menu auto-hide, full-screen, and Stage
Manager remain separate physical acceptance cases.

## Physical acceptance matrix

`matrix_evidence.py` turns those physical cases into a strict, reviewable
record. It never changes Dock, menu-bar, Stage Manager, Spaces, full-screen, or
display settings. Put the Mac in the requested state yourself, run the visible
preview, review it, and supply a screenshot or recording. The capture stores
canonical native JSON without build-machine paths, the exact source commit, the
manual attestation, and SHA-256 hashes of every evidence file.

List the sixteen required cases:

```sh
python3 tools/HabitatValidation/matrix_evidence.py list
```

For each case, create and edit a false-by-default attestation. Set a check to
`true` only after observing it and add concrete notes when the system state or
result is not obvious from the visual evidence.

```sh
python3 tools/HabitatValidation/matrix_evidence.py template \
  --case notched-menu-shown \
  --output .build/notched-menu-shown-attestation.json
```

Then capture against a clean commit. The wrapper runs both signed checks and
shows the actual habitat visit. It only reads the current state.

```sh
./tools/HabitatValidation/capture-matrix.sh \
  notched-menu-shown \
  .build/notched-menu-shown-attestation.json \
  .build/notched-menu-shown.mov
```

The required physical cases cover ordinary and notched displays with the menu
shown and auto-hidden, full-screen, Stage Manager, mixed-scale multi-display,
display hot-plug, a Space transition, and left/right/bottom/auto-hidden Dock
states. A geometry prerequisite is checked where AppKit can establish it. The
full-screen, Stage Manager, menu auto-hide, hot-plug, and Space states remain
explicit human attestations because public APIs cannot safely synthesize or
authoritatively certify those user-controlled states.

The art case requires three proof boards, one at each native size:

```sh
python3 tools/CharacterAssets/export_habitat_clips.py --proof .build/habitats-v05
./tools/HabitatValidation/capture-matrix.sh \
  art-native-size-board \
  .build/art-native-size-board-attestation.json \
  .build/habitats-v05/storyboard-72pt.png \
  .build/habitats-v05/storyboard-96pt.png \
  .build/habitats-v05/storyboard-120pt.png
```

Verify the directory after all cases have been recorded:

```sh
python3 tools/HabitatValidation/matrix_evidence.py verify \
  --directory .build/habitat-matrix
```

Verification fails if a case is absent, a native check failed, current hardware
does not satisfy a case prerequisite, source trees were dirty, commits differ,
an attestation remains false, or an evidence file changed. Only a report with
`physicalHardwareMatrixComplete: true` completes the physical audit. The
generated evidence directory is intentionally ignored by Git so recordings and
desktop imagery cannot enter the repository accidentally.
