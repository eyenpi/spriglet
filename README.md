# Spriglet · Mallow

A soft, local desktop companion for Apple silicon Macs running macOS 26 or later. Mallow rests beneath the notch with its face visible, blinking and breathing while you work. It has no action cards, settings window or permanent menu-bar controls.

Hover for a small reaction. Click to invite it out; touch again for a wave or swing. Drag to pick it up. Release near home to let it catch, or away from home for gravity and a squishy landing. Click elsewhere to return it to its resting peek. On a display without a notch, it rests at the upper right edge below the menu bar.

This is the first Mallow release, `v0.3.0-preview.1` (app 0.3.0, build 5). Downloads are on [GitHub releases](https://github.com/eyenpi/spriglet/releases/tag/v0.3.0-preview.1); choose the `LOCAL-UNSIGNED.dmg` for drag-to-Applications installation or the ZIP. macOS may block an unsigned download. Plugins and assistant services are not implemented. The local app uses ad hoc signing; it has not been Apple-notarized or submitted to the App Store.

![Mallow peeking, reacting and playing](art/mallow/demo.gif)

The preview above uses the production simulation and renderer on a simulated desktop.

## Build and run

Select the full Xcode 26 toolchain, then:

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/build.sh Release
./scripts/run.sh
```

Builds live under `.build/xcode/Build/Products/`. Reopening the app from Finder activates its ordinary app menu; Command-Q quits. Launch and character interaction do not steal keyboard focus. Right-click returns Mallow home. Escape also returns it home when this app receives keyboard input.

For a finite, reproducible animation preview using the production code:

```sh
./scripts/preview.sh .build/preview/frames
./scripts/preview.sh .build/preview/transitions --transitions
```

The exporter writes PNG frames locally. The transition sequence renders at 60 fps and covers emergence, grabbing during emergence, regrabbing a catch, reversing a retreat, a rapid upward throw and returning during a horizontal reversal. It runs no assistant service and reads no desktop content.

## Architecture

There is one production simulation and one renderer. The preview exporter uses those same modules.

| Layer | Location | Responsibility |
| --- | --- | --- |
| Core | `Packages/CompanionKit/Sources/CompanionCore` | Geometry, interaction state, fixed-step physics, pose blending, frame policy and typed commands. Pure Swift values; no AppKit, timers, files or networking. |
| Rendering | `Packages/CompanionKit/Sources/CompanionRendering` | Draw immutable snapshots as vector artwork. No engine references, events, window ownership or clocks. |
| macOS environment | `Sources/Spriglet/Environment` | Convert real display measurements and lifecycle signals into core values. Observe outside clicks without reading clicked content. |
| Desktop host | `Sources/Spriglet/Desktop` | Transparent nonactivating panel, actual-frame coordinate compensation, hit testing and accessible character actions. |
| Runtime | `Sources/Spriglet/Runtime` | Wire the three boundaries together and own the single screen-bound animation clock. |
| App | `Sources/Spriglet/App` | Launch, shutdown and generated shared text. |

`CompanionRuntime` is the composition root. It owns a `CompanionEngine`, `DesktopEnvironment`, `CompanionWindowHost` and `ScreenFrameClock`. Adapters report to the runtime; they never call one another. Core state is held in a session value and advances in 120 Hz simulation steps, independently of display cadence. The renderer receives a `CompanionSnapshot` and cannot mutate the model.

### Changing behavior

Add a semantic input or command in `CompanionInput.swift`. Interaction transitions belong in `InteractionState.swift` and `CompanionEngine.swift`; trajectories, contact and weight belong in `BodyPhysics.swift`; authored pose targets belong in `MotionAnimator.swift`. `PoseDynamics.swift` carries silhouette and limb velocity across target changes and derives width from height to conserve body area. `JumpTrajectory.swift` joins flight endpoints with matching velocities. Preserve the existing pose and momentum when a motion changes. Keep scene measurements and coordinate conversion outside behavior code.

Hands use one continuous attachment value in the snapshot. The renderer blends free and home hand positions and lets the home housing occlude them as they emerge; it has no reveal threshold or gesture-triggered arm switch.

Home retraction advances independently of the physics phase. Grabs transfer its visible position and velocity to the held body; catches start their retreat from the current offset instead of applying a hidden part of the peek all at once.

Free motion respects the scene ceiling, floor and side limits. Momentum continues until contact: vertical impacts produce a damped rebound, catch springs retain their corrected state, and return trajectories rejoin home from the contact position and remaining velocity. The ceiling keeps the body reachable while allowing a grab to begin at the visible resting peek.

### Changing the character

Edit `MallowRenderer.swift` and the pose contract. The app, preview and icon share the same vector source. Regenerate icons with `art/app-icon/export_icon_catalog.sh` and run the rendering tests. No spritesheet, frame decoder or separate character manifest is required.

### Future capabilities

A capability requests a `CompanionCommand` through `CompanionRuntime.perform(_:)`. It does not receive a window, renderer, input monitor or mutable engine. This is the extension boundary; a plugin loader, permissions model and assistant services belong in a separate capability layer when there is a concrete feature to build. There are no placeholder registries, service locators or dormant plugin implementations.

### Lifecycle and resources

The host renders deliberate motion at up to 60 fps and quiet peeking/grounded breathing at 30 fps. Low Power Mode caps cadence at 30 fps; Reduce Motion or serious thermal pressure cap it at 15 fps. Display sleep, inactive sessions and critical thermal pressure suspend the clock and hide the panel. Suspension cancels pointer capture; waking resumes without simulating the time spent asleep. Reduce Motion preserves blinking while limiting decorative movement and return flights.

Mallow only occupies a small transparent panel. Empty margins pass clicks through; a drag retains capture until release or cancellation. The floor clears macOS-reported reserved space. Other app windows and the exact Dock icon shelf are not inspected.

## Verification

`./scripts/test.sh` checks dependency boundaries, core interactions, trajectory/contact behavior, pose continuity, lifecycle policy, coordinate compensation and native rendered pixels. Debug and Release Xcode builds use Swift 6 with strict concurrency and warnings as errors.

The PR workflow retains owner approval before runner allocation and its security checks. It runs the same new tests, renders a production preview, checks shared content, validates both app builds and rehearses unsigned packaging. CI compilation is separate from live interaction and visual acceptance.

```sh
python3 tools/SharedContent/sync.py --check
python3 tools/ReleaseNotes/release_notes.py check
python3 art/app-icon/verify_icon.py
python3 tools/AppStore/validate.py
python3 scripts/check-public-files.py --working-tree
```

App text, help, privacy and prepared website/store content are generated from `Configuration/Shared`. Edit those sources and run the synchronizer. Nothing in a normal build publishes the website or uploads the app.

See [CONTRIBUTING.md](CONTRIBUTING.md), [asset provenance](ASSETS.md), [privacy](PRIVACY.md), [release tooling](tools/ReleaseValidation/README.md) and [CI approval](tools/CI/README.md). Retired implementations and authored artwork remain recoverable in Git history rather than in the active codebase.

## Release process and next steps

The Mallow release replaces the previous character and interaction system. The bundle identifier remains `dev.spriglet.app`; old saved preferences are neither imported nor deleted. There is no login item registration in this preview. Quit an older running preview before opening Mallow.

A release goes through a PR, required security and Mac build checks, then a merge to `main`. Build and package that exact clean revision, mount and verify the DMG, create an immutable annotated tag and publish the matching changelog and checksummed downloads. The publisher refuses mismatched or dirty source. See [release instructions](tools/ReleaseNotes/README.md) and [packaging](tools/ReleaseValidation/README.md).

The next priorities are broader device acceptance (sleep/wake, multiple displays, VoiceOver and sustained energy use), more authored expressions and idle moments, and Developer ID signing/notarization. After that, add one useful capability through the typed command boundary before introducing a permissioned plugin loader. No assistant behavior, external-app awareness or 3D runtime is included in this release.
