# Spriglet

A local macOS desktop companion. **Sprout's first playable character sample** uses a soft, pre-rendered 3D character: idle → short walk → petting reaction → settle. It remembers where you place it, supports quiet activity and static naps, and keeps your settings on this Mac.

The app displays rendered frames from the [editable Sprout model and rig](art/sprout/README.md). The [sample and asset pipeline](docs/character-sample.md) document its animation, grounded walking, light/dark review, and validation. The [character study](docs/concepts/character-design-review-01.md) and [original researched plan](docs/app-plan-2026-09-13.md) remain historical context. The full animation library and broader desktop/distribution acceptance are later work.

## Run it

Use an Apple silicon Mac running **macOS 26 or later** with full Xcode installed and selected as the developer toolchain. Development is verified with **Xcode 26.6 / Swift 6.3.3**, using macOS SDK 26.5 on macOS 26.6.2. There are no third-party app dependencies or remote Swift packages; `SprigletCore` is a local package. The probe script also uses `python3` to read its JSON result.

From the repository root:

```sh
./scripts/run.sh
```

This builds Debug and opens Spriglet. Look for the **leaf in the menu bar**; the app has no Dock icon. Choose **Prototype Controls…** to open the control window.

- Choose **Play Character Sample** for the complete 5.63-second sequence. The app chooses a walking direction with enough room.
- Click the pet or use **Pet Spriglet** for the happy reaction and settle. Input during another sequence waits for its boundary; repeated requests coalesce.
- Use **Idle**, **Walk Left**, and **Walk Right** in Prototype Controls to inspect the authored clips. A direction without enough room is rejected before movement begins.
- Leave **Quiet Behavior** enabled for occasional idle moments and naps, or turn it off for manual interaction only. **Take a Nap / Wake Spriglet** selects a static pose; this sample has no separate animated sleep/wake clips.
- Drag the body to move it. The settled position is remembered across launches and adapted to the display's current usable area. Authored walks do not change that saved home; autonomous roaming is not implemented.
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

For an isolated design review, launch with `--sample-review`. It opens controls, plays the complete sample, disables automatic behavior, and uses temporary preferences without changing your saved choices:

```sh
.build/xcode/Build/Products/Debug/Spriglet.app/Contents/MacOS/Spriglet --sample-review
```

## Test and measure

Run the local package's Swift Testing suite:

```sh
./scripts/test.sh
```

The Swift Testing suite covers behavior and cooldowns, settings migration, suspension causes, display placement, asset-manifest validation, frame boundaries, cumulative root motion, and whole-trajectory fitting. The app scheme builds the application; the package test command runs these unit tests.

Quit any existing Spriglet instance before running the finite Release probe in an unlocked desktop session:

```sh
./scripts/probe.sh > /tmp/spriglet-probe.json
```

The script refuses to start if Spriglet is already running. Otherwise it builds Release, launches a temporary app instance for about one minute, writes JSON to stdout, and exits after the check. It checks the full character sample, petting, static naps, queued input, authored window movement, scheduler cancellation, and quiet rest. It does not save temporary preferences; ordinary automatic behavior is disabled except for explicit scheduler checks. Build output goes to stderr. Exit status is **0 passed**, **1 failed**, or **2 blocked by a running instance, visibility, or system policy**. It respects Reduce Motion and system suspension. Avoid interacting with the desktop during measurement.

The same finite check is available through **Run Automatic Check** in Prototype Controls, with **Cancel Check** and **Copy Report**. Checks restore the starting position and saved choices on completion or cancellation. Diagnostics refresh on demand; they do not create a permanent sampling timer.

For a longer, opt-in check, quit Spriglet and run:

```sh
./scripts/soak.sh > /tmp/spriglet-soak.json
```

This runs 100 show/hide/reaction cycles and a final resting interval in about 6–7 minutes. **Run 100-Cycle Check** in Prototype Controls uses the same check and supports cancellation. Its JSON separates functional checks from CPU and memory observations; it does not establish a production memory budget or battery life.

Use the [character sample validation tools](tools/CharacterSampleValidation/README.md) for native playback and exported PNG/contact checks. [Current sample evidence](docs/character-sample.md) identifies the tested assets and app source. A paused launch has a static image; hidden, paused, and settled states keep the frame clock stopped.

[Phase 3 results](docs/phase-3-desktop-reliability.md), including the old 21-check probe, 100-cycle run, and Metal traces, measured the previous procedural renderer. They do not establish the new asset renderer's memory, GPU, or battery cost. [Phase 2](docs/phase-2-behavior.md) and [phase 1](docs/phase-1-validation.md) also remain historical. The broader physical desktop matrix and sustained performance work remain open.

## Implementation

| Concern | Current implementation |
| --- | --- |
| Menu and controls | SwiftUI `MenuBarExtra`, native window scenes, Observation |
| Concurrency | Swift 6 language mode with the Swift 6.3.3 compiler, MainActor isolation, complete concurrency checking, warnings treated as errors |
| Desktop host | Transparent nonactivating AppKit `NSPanel`; local view hit testing and dragging |
| Character | A child `CALayer` displays 448 × 448 transparent PNGs at 224 × 224 points; editable Blender source, five finite clips and static awake/nap poses |
| Image decoding | ImageIO with immediate decoding on `@concurrent` work; at most 12 buffered animation frames plus static/current images |
| Calm behavior | Seeded pure planner; one cancellable `Task.sleep(for:tolerance:)` deadline with a generation guard |
| Pose and window movement | One `NSView.displayLink(target:selector:)` selects the same authored frame and root offset; both hold on a decoder underrun; no independent movement easing |
| System state | macOS 26 typed notifications for screen/system sleep, session, accessibility, power, and thermal changes |
| Policy, planning, settings | Sendable `SprigletCore` values, versioned settings in `UserDefaults`, Swift Testing |
| Diagnostics | Layer assignments, display-link callbacks, applied movement frames, buffer underruns; own-process CPU/footprint sampling and `OSSignposter` markers |

The language-mode setting `SWIFT_VERSION = 6.0` selects Swift 6 semantics; the installed compiler is Swift **6.3.3**. Current official documentation and the installed SDK support the [view display link](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)), [child layer image contents](https://developer.apple.com/documentation/quartzcore/calayer/contents), [ImageIO eager decoding](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately), and [explicit concurrent work](https://www.swift.org/blog/swift-6.2-released/). New code builds with warnings treated as errors and uses no deprecated display-link or animation APIs.

The source is split into `App`, `Desktop`, `Rendering`, and `Diagnostics` under `Sources/Spriglet`, with policy, geometry, behavior planning, preferences, manifest validation, and sample timing in `Packages/SprigletCore`. The current asset/timing contract is in [character sample](docs/character-sample.md).

## Local development and distribution

The Xcode project currently uses **local ad-hoc signing**. The inspected local signature has App Sandbox and the debugging entitlement `get-task-allow` enabled. The project requests Hardened Runtime, but Xcode disables it for these ad-hoc local builds. The checked-in entitlement file contains only App Sandbox; no developer team is configured.

A Release build here is still a local prototype. Public distribution needs the chosen signing/distribution configuration, packaging, and release validation. Direct Mac distribution uses Developer ID signing and notarization; the Mac App Store has its own signing and submission workflow. [Apple's macOS distribution guide](https://developer.apple.com/macos/distribution/)

## Privacy and current scope

The prototype has no accounts, social features, network calls, or analytics. It reads its own window input and process counters; it does not capture desktop images or inspect other apps' contents. It requests no Screen Recording, Accessibility, Input Monitoring, or Automation permission. **Copy Report** writes only when selected and includes diagnostic timing, counts, OS version, and process measurements. The longer check also includes the executable path, process ID, and build identity.

Five user settings and the chosen display-relative position are stored locally; the current pose, random sequence, and animation progress are not persisted. The display UUID is used only to restore this app's window and is never sent anywhere. The optional macOS privacy manifest records access to the app's own settings with reason `CA92.1`; it is not a submission-readiness claim. The full animation library, richer personality, sound, login-item support, and distribution are later work. Remaining acceptance includes physical cross-application input/focus, transparent-pixel routing, Spaces/full-screen/Stage Manager, display changes, actual sleep/wake, accessibility settings, sustained compositor profiling, and longer performance/battery runs. The sample's light/dark review has the specific scope recorded in its evidence.
