# Development

Use an Apple silicon Mac running macOS 26 or later, with full Xcode selected through `xcode-select`. This preview was built with Xcode 26.6 / Swift 6.3.3 and macOS SDK 26.5. Open `Spriglet.xcodeproj`, choose the Spriglet scheme and My Mac, or use the scripts below.

## Build and run

```sh
./scripts/run.sh
./scripts/build.sh Debug
./scripts/build.sh Release
./scripts/test.sh
```

Build products live in `.build/xcode/Build/Products/Debug` and `Release`. Local builds use ad-hoc signing. Public Developer ID distribution is a separate process described in [distribution](distribution.md).

Launch modes, passed directly to the built executable:

| Argument | Purpose |
| --- | --- |
| `--controls` | Open everyday controls, preserving saved choices |
| `--sample-review` | Open controls and play the sample using temporary preferences |
| `--welcome-review` | Review first-run welcome using temporary preferences |
| `--probe` | Run the finite app check and exit |
| `--soak` | Run 100 repeated interactions and exit |

The app lives in the menu bar. Quit an existing instance before starting a separate review or diagnostic instance. The two review modes and command-line diagnostics do not save their temporary pet choices.

## Validate changes

`./scripts/test.sh` runs the local package's Swift Testing suite. It covers behavior, preferences, placement, animation manifests, frame boundaries, cumulative motion, and trajectory fitting. Debug and Release builds treat warnings as errors and use strict Swift 6 concurrency.

For exported character assets and native rendering, follow [CharacterSampleValidation](../tools/CharacterSampleValidation/README.md). For the current source and editable rig, see [the character pipeline](character-sample.md). Rebuilding Blender frames is not necessary for ordinary Swift UI changes.

In an unlocked desktop session, quit Spriglet and run:

```sh
./scripts/probe.sh > .build/runtime-probe.json
./scripts/soak.sh > .build/runtime-soak.json
```

The probe takes about a minute; the 100-cycle soak takes about 6–7 minutes. Both refuse to run beside an existing app instance. Avoid interacting with the desktop during measurement. Exit codes are 0 for passed checks, 1 for failed checks, and 2 when a run is blocked. The controls window's collapsed Diagnostics section exposes the same checks and supports cancellation and report copying.

Diagnostic reports can include machine-specific paths and process information. Keep raw reports local and sanitize them before publishing. Measurements are observations, not guarantees of production memory, GPU, or battery budgets.

## Architecture

SwiftUI/Observation owns controls; a transparent nonactivating AppKit panel hosts the pet. A child `CALayer` displays decoded PNGs. `NSView.displayLink(target:selector:)` chooses each authored frame and its matching window displacement. Decode underruns hold the image, authored time, and movement together. A finite clip invalidates its display link when finished. Quiet behavior uses one cancellable deadline instead of permanent polling.

`SprigletCore` is a local package of Sendable policy, preference, placement, manifest, and timeline values. The app source is grouped under App, Desktop, Rendering, and Diagnostics. The `SWIFT_VERSION = 6.0` setting selects Swift 6 language semantics; it does not mean the compiler is Swift 6.0.

Current API references: [view display link](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)), [layer image contents](https://developer.apple.com/documentation/quartzcore/calayer/contents), [ImageIO eager decode](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately), [explicit concurrent work](https://www.swift.org/blog/swift-6.2-released/), [scene launch behavior](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:)), and [DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup).
