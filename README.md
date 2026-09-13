# Spriglet

A local macOS desktop companion. The **phase 3 desktop reliability prototype** remembers where you place it and occasionally blinks, looks around, stretches, or naps, with finite animations and quiet intervals between them. Your settings stay on this Mac. Some desktop and performance acceptance checks from phase 1 remain open.

The green character is procedural placeholder artwork. The user selected **A · Sprout** in the [character design review](docs/concepts/character-design-review-01.md). Its Blender model and production animation library are subsequent work. The [original researched plan](docs/app-plan-2026-09-13.md) is retained as historical planning context.

## Run it

Use an Apple silicon Mac running **macOS 26 or later** with full Xcode installed and selected as the developer toolchain. Development is verified with **Xcode 26.6 / Swift 6.3.3**, using macOS SDK 26.5 on macOS 26.6.2. There are no third-party app dependencies or remote Swift packages; `SprigletCore` is a local package. The probe script also uses `python3` to read its JSON result.

From the repository root:

```sh
./scripts/run.sh
```

This builds Debug and opens Spriglet. Look for the **leaf in the menu bar**; the app has no Dock icon. Choose **Prototype Controls…** to open the control window.

- Leave **Quiet Behavior** enabled for occasional activity, or turn it off for manual interaction only.
- Click the pet or use **Pet Spriglet** for a reaction. A sleeping pet wakes first; input during another clip waits for its boundary and repeated requests coalesce.
- Use **Take a Nap / Wake Spriglet**, or preview individual clips in Prototype Controls.
- Drag the body to move it. The settled position is remembered across launches and adapted to the display's current usable area. **Try a Short Walk** remains a manual movement experiment and does not change that saved position; autonomous roaming is not implemented.
- Use **Pause**, **Hide Pet**, and **Bring Pet Home** to control it.
- **Pass Clicks Through** makes the entire pet window ignore mouse events; the menu remains available.
- The controls window also exposes **Show on All Spaces**, **Next Display**, directional placement buttons, and diagnostics. Each arrow moves the pet by 48 points within the display's usable area.
- Choose **Quit Spriglet** from the menu to stop the app.

Awake activity is planned after 20–75 seconds of rest; a sleeping pet plans to wake after 60–180 seconds. The first awake moment after interaction gets a 45–75-second cooldown. A nap is a static pose with the renderer stopped. Pause, Hide Pet, Pass Clicks Through, Show on All Spaces, and Quiet Behavior are saved locally across launches. Current window configuration opts out of other apps' full-screen Spaces; all-Spaces and Stage Manager behavior still need the manual checks. Precise click-through around the painted character is unresolved; whole-window click-through is the explicit fallback.

## Open and build

Open the Xcode project and select the **Spriglet** scheme with **My Mac**:

```sh
open Spriglet.xcodeproj
```

Build without launching:

```sh
./scripts/build.sh Debug
./scripts/build.sh Release
```

Products are written to `.build/xcode/Build/Products/Debug/Spriglet.app` and `.build/xcode/Build/Products/Release/Spriglet.app`. For example, open the Release build with:

```sh
open .build/xcode/Build/Products/Release/Spriglet.app
```

For a fresh launch directly into the native controls, quit any existing instance and run the built Debug app with `--controls`. This preserves the saved pet flags, including hidden and paused:

```sh
.build/xcode/Build/Products/Debug/Spriglet.app/Contents/MacOS/Spriglet --controls
```

## Test and measure

Run the local package's Swift Testing suite:

```sh
./scripts/test.sh
```

There are 40 test functions expanding to 240 cases. They cover deterministic behavior and cooldowns, settings migration and invalid payloads, independent suspension causes, display selection, and screen-relative placement. The app scheme builds the application; the package test command runs these unit tests.

Quit any existing Spriglet instance before running the finite Release probe in an unlocked desktop session:

```sh
./scripts/probe.sh > /tmp/spriglet-probe.json
```

The script refuses to start if Spriglet is already running. Otherwise it builds Release, launches a temporary app instance for about one minute, writes JSON to stdout, and exits after the check. It checks clips, static naps, queued input, window movement, scheduler replacement/cancellation, and idle states. The command-line probe starts with default flags and does not save temporary preferences; normal autonomous planning is disabled except for its explicit short scheduler checks. Build output goes to stderr. Exit status is **0 passed**, **1 failed**, or **2 blocked by a running instance, visibility, or system policy**. It respects Reduce Motion and system suspension. Avoid interacting with the desktop during measurement; profiling and other applications can affect the results.

The same finite check is available through **Run Automatic Check** in Prototype Controls, with **Cancel Check** and **Copy Report**. Checks restore the starting position and saved choices on completion or cancellation. Diagnostics refresh on demand; they do not create a permanent sampling timer.

For a longer, opt-in check, quit Spriglet and run:

```sh
./scripts/soak.sh > /tmp/spriglet-soak.json
```

This runs 100 show/hide/reaction cycles and a final resting interval in about four minutes. **Run 100-Cycle Check** in Prototype Controls uses the same check and supports cancellation. Its JSON separates functional checks from CPU and memory observations; it does not establish a production memory budget or battery life.

See [phase 3 behavior and validation](docs/phase-3-desktop-reliability.md) for current results and the [disposable desktop fixture](tools/DesktopValidation/README.md) for repeatable input and renderer lifecycle checks. A pet launched with a saved pause now receives one initial still frame when shown; hidden and settled paused views keep their renderer stopped.

The current [Release probe](docs/results/phase-3/probe.json) passed all 21 checks. The [100-cycle run](docs/results/phase-3/soak.json) passed all 20 functional checks in 251.24 seconds. Its largest sampled footprint was 114.34 MiB, returning to 22.14 MiB after the final rest versus a 22.03 MiB warmed baseline. All final resting counters stayed unchanged. The allocation cause, production resource budget, and battery behavior remain unproven. [Native lifecycle checks](docs/results/phase-3/renderer-lifecycle.json) passed 12/12, and [UI observations](docs/results/phase-3/ui-observations.json) cover paused startup, saved positions, and diagnostic restoration.

Separate [paused](docs/results/phase-3/paused-metal-summary.json) and [active-control](docs/results/phase-3/active-control-metal-summary.json) Metal traces verified the Release process identity. The 5.91-second paused capture had no directly attributed submissions or GPU intervals; deliberate activity produced 197 submission rows and 392 GPU interval rows. Unattributed activity remains in both traces, so this does not establish zero GPU work or energy cost.

The [current environment and source/binary hashes](docs/results/phase-3/environment.json) identify these runs. [Phase 2 behavior contracts and results](docs/phase-2-behavior.md) remain historical evidence for their recorded source. [Phase 1 validation](docs/phase-1-validation.md) retains historical results and the pending physical desktop matrix. Instruments captures must attach to the verified Release process ID, following the [discarded profiling attempt](docs/results/profiling-attempt.json).

## Implementation

| Concern | Current implementation |
| --- | --- |
| Menu and controls | SwiftUI `MenuBarExtra`, native window scenes, Observation |
| Concurrency | Swift 6 language mode with the Swift 6.3.3 compiler, MainActor isolation, complete concurrency checking, warnings treated as errors |
| Desktop host | Transparent nonactivating AppKit `NSPanel`; local view hit testing and dragging |
| Character | SpriteKit in an `NSView` wrapper; six finite authored clips, one coalesced pending request, static awake/nap poses |
| Calm behavior | Seeded pure planner; one cancellable `Task.sleep(for:tolerance:)` deadline with a generation guard |
| Window movement | `NSView.displayLink(target:selector:)` with `CADisplayLink`, invalidated when movement finishes or is suspended |
| System state | macOS 26 typed notifications for screen/system sleep, session, accessibility, power, and thermal changes |
| Policy, planning, settings | Sendable `SprigletCore` values, versioned settings in `UserDefaults`, Swift Testing |
| Diagnostics | Completed scene updates, render callback and movement tick counters; own-process CPU and physical footprint sampling; `OSSignposter` phase markers |

The language-mode setting `SWIFT_VERSION = 6.0` selects Swift 6 semantics; the installed compiler is Swift **6.3.3**. AppKit, SpriteKit, and the display-link APIs are checked against the installed SDK. [Apple's view display-link API](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)), [Swift Testing](https://developer.apple.com/documentation/testing)

The source is split into `App`, `Desktop`, `Rendering`, and `Diagnostics` under `Sources/Spriglet`, with policy, geometry, behavior planning, and preferences in `Packages/SprigletCore`. Timing contracts are in [phase 2 behavior](docs/phase-2-behavior.md); current placement, lifecycle, and diagnostic references are in [phase 3 reliability](docs/phase-3-desktop-reliability.md).

## Local development and distribution

The Xcode project currently uses **local ad-hoc signing**. The inspected local signature has App Sandbox and the debugging entitlement `get-task-allow` enabled. The project requests Hardened Runtime, but Xcode disables it for these ad-hoc local builds. The checked-in entitlement file contains only App Sandbox; no developer team is configured.

A Release build here is still a local prototype. Public distribution needs the chosen signing/distribution configuration, packaging, and release validation. Direct Mac distribution uses Developer ID signing and notarization; the Mac App Store has its own signing and submission workflow. [Apple's macOS distribution guide](https://developer.apple.com/macos/distribution/)

## Privacy and current scope

The prototype has no accounts, social features, network calls, or analytics. It reads its own window input and process counters; it does not capture desktop images or inspect other apps' contents. It requests no Screen Recording, Accessibility, Input Monitoring, or Automation permission. **Copy Report** writes only when selected and includes diagnostic timing, counts, OS version, and process measurements. The longer check also includes the executable path, process ID, and build identity.

Five user settings and the chosen display-relative position are stored locally; the current pose, random sequence, and animation progress are not persisted. The display UUID is used only to restore this app's window and is never sent anywhere. The optional macOS privacy manifest records access to the app's own settings with reason `CA92.1`; it is not a submission-readiness claim. Production artwork, richer personality, sound, login-item support, and distribution are later work. Remaining acceptance checks include desktop transparency over known backgrounds, physical cross-application input/focus, transparent-pixel routing, Spaces/full-screen/Stage Manager, display changes, actual sleep/wake, accessibility settings, sustained GPU/compositor profiling, and longer performance/battery runs.
