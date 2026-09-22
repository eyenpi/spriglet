# Acorn local portals and supported ledge proof

This editable seven-clip library provides peek, edge-look, dangle, a supported
pull-up/climb, floor exit/re-entry, and ledge exit. It never sends a window
sliding up another application's content. A host may relocate between habitats
only at the exact fully transparent `portal.hidden` pose.

```sh
python3 tools/CharacterAssets/export_habitat_clips.py
python3 tools/CharacterAssets/export_habitat_clips.py --check
python3 tools/CharacterAssets/export_habitat_clips.py --verify-saved
python3 -m unittest discover -s tools/CharacterAssets -p 'test_habitat_clips.py'
# Optional Pillow + FFmpeg for offline native-size boards and finite media:
python3 tools/CharacterAssets/export_habitat_clips.py --proof .build/habitats-v05
```

| Clip | Frames | Shared boundary |
| --- | ---: | --- |
| `habitat.floorExit` | 22 | ready → portal.hidden |
| `habitat.floorReentry` | 22 | portal.hidden → ready |
| `habitat.peekIn` | 24 | portal.hidden → ledge.peek |
| `habitat.edgeLook` | 30 | ledge.peek → ledge.peek |
| `habitat.dangle` | 18 | ledge.peek → ledge.hang |
| `habitat.pullUp` | 22 | ledge.hang → ledge.peek |
| `habitat.ledgeExit` | 22 | ledge.peek → portal.hidden |

All 160 references are 30-fps, 448 × 448 RGBA images on a 96-point Standard
canvas. The camera, character geometry, materials and lighting come from the
actual editable Acorn rig. The only new visible geometry is a pair of thin,
matte olive ledge lips outside the paws. They give a visible support datum
without crossing the face. Their visibility is keyed with each Action.

These are **floating portal ledges**, not a claim that the pet physically grips
the macOS menu bar. The short-armed Acorn anatomy needs substantial head room
above its hands. Grip anchors are approximately (134.159, 259.616) and
(289.768, 259.616) in top-left source pixels. The provider must allow 46 points
of head clearance above the grip and keep the entire portal window below the
protected menu strip. With the window top at the safe top boundary, the grips
sit about 55.6 points below it. Disable the candidate when this geometry cannot
fit. This proof makes no claim of notched-hardware acceptance.

During dangle and pull-up, the body moves 0.23 world units (about 7.4 points),
the feet tuck, and both paw contact markers remain fixed on their ledges.
Edge-look also preserves both grips while the body, cap and leaf react. The
exporter evaluates the actual armature and independently records support drift;
it does not substitute intended positions for evaluated contacts. The floor
catcher stays fixed on the floor while the character enters/exits its portal.

The platform root offsets are exactly zero: all visible movement is authored
skeletal motion inside a fixed local portal window. `motion.json` separately
records that real local root translation and measured support positions.
`clipPresentation` declares the only permitted occlusion: the floor line at
source Y=431 and top line at Y=16, with exact frame ranges. Portal clips disable
pointer interaction until a supported visible state is reached. Hidden has no
hit region and no alpha. Visible shared states have data-defined hit regions.

`clips.json` is a schema-3-compatible library fragment. It carries explicit
habitat/orientation/capability requirements, exact shared canonical paths,
planted-foot or gripped-paw markers, and safe redirection only at supported
visible junctions. Host relocation requires the terminal `fullyHidden` semantic
event on an exact `portal.hidden` endpoint; `portalHidden` remains an
interruption label and cannot authorize a host move by itself.
Reduced Motion falls back to local blink; these depth/portal clips do not run.
Wall geometry may exist in a provider, but this package deliberately does not
declare wall traversal support: no animated vertical slide is mislabeled as a
climb. The actual supported climb in this library is the ledge pull-up.

Resource policy retains the existing 12-frame decode bound. Compressed new
images must remain below 18 MiB. The separate Blender source, motion evidence
and offline review exports are authoring material, not runtime resources.
The ignored 72/96/120-point light/dark/busy boards and finite MP4 demonstrate
source artwork and timing; they do not certify native compositor behavior,
physical desktop click routing, protected-strip geometry, or energy usage.
