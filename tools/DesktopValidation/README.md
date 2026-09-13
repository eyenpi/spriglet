# Desktop validation fixture

This disposable native AppKit app provides known backgrounds and actual event receivers beneath Spriglet. It uses macOS 26 APIs and Swift 6, has no package dependencies, and is separate from the application target. It has no network, input monitor, event tap, screen capture, or saved test content. Its window and restoration snapshots are disabled; typing and counters remain in memory.

## Build and launch

From the repository root:

```sh
tools/DesktopValidation/build.sh
```

This only builds and ad-hoc signs `.build/DesktopValidation.app` within this directory. Launch the exact executable when ready to test:

```sh
tools/DesktopValidation/.build/DesktopValidation.app/Contents/MacOS/DesktopValidation
```

Close its window or use **Quit Desktop Validation** to end the test. It never opens a document. The build was checked with Xcode 26.6 (17F113), Swift 6.3.3, and macOS SDK 26.5 on Apple silicon. The build uses complete concurrency checking and warnings as errors.

## What the fixture measures

- **Light and dark targets:** opaque, fixed sRGB backgrounds and a 48-point grid reveal unexpected rectangular fills, fringes, or scene margins. Read-only labels do not intercept target clicks.
- **Blank mouse-downs:** actual `mouseDown(with:)` calls delivered to that target. Clicking marks a crosshair for an optional routing prediction. Both targets explicitly accept the first mouse-down in an inactive window.
- **Button actions:** native AppKit button actions are counted separately. These buttons also explicitly accept the first mouse-down. A blank-area click does not increment the button counter.
- **Scroll events:** actual `scrollWheel(with:)` calls, with the latest deltas, precise/coarse units, and momentum phase. These are event counts, not physical gesture counts or a claim about scroll distance.
- **Inspect marked point:** one call to `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`, at the target's marked local point converted to its current screen position. It shows the predicted mouse-down window number and the fixture's window number. There is no polling. The result is a snapshot; inspect again after moving a window. The marked point follows its target when the fixture is resized.
- **Focus:** app activation/deactivation and key-window gain/loss totals expose state changes, including incidental activation by automation. The typing field reports whether its editor is the active key-window first responder, plus text-change and character counts. Reset clears target counters and test text; focus totals continue for the process lifetime.

The numerical prediction supplements received-event counts. A predicted fixture window does not demonstrate that a particular click was delivered. An accessibility button action also does not establish physical first-click routing.

## Suggested controlled checks

1. Click each target and button without the pet above them, and perform a fresh scroll gesture. Establish that every counter changes as intended. Record focus totals as the baseline.
2. Disable Spriglet's Quiet Behavior during boundary checks so the painted outline remains stationary. Keep the pet shown and unpaused; test paused presentation separately with the character validation harness linked below.
3. Move the pet over the light target and then the dark target. Inspect clear corners, the sprout outline, and the ground shadow. A scene-texture PNG is not evidence of window compositing; observe the actual desktop host.
4. Click a blank target to mark a point, then move the pet so a clear corner covers the crosshair. Use **Inspect marked point** and record both window numbers. Click the marked screen point once and check the received mouse-down count. Repeat for all corners, immediately outside the outline, and the translucent shadow.
5. Position a transparent margin over a native button and click once. Repeat with a fresh scroll gesture over a blank target. Finish any previous momentum before changing the test position, because macOS can keep momentum events attached to their initial receiver.
6. Focus the disposable typing field and enter a short test phrase. Record activation/key-window totals. Click the visible pet body once, then type more without selecting the field again. Check Spriglet's reaction, unchanged underlying click counts, focus totals, and the resulting text. Repeat a quick pointer-entry-and-click gesture.
7. Enable Spriglet's whole-window **Pass Clicks Through** setting and click directly over its body. The underlying receiver should handle the first click. Restore the setting from Spriglet's menu.

Record OS, build, display/scale, input method, and whether a person or app-targeted automation performed the actions. Automation may activate its target application; compare the focus-change totals and limit the conclusion accordingly. These checks do not cover another macOS release, another display, real sleep/lock, Spaces, Stage Manager, full-screen behavior, energy, or all physical input devices.

## Current character lifecycle check

Renderer validation moved to [CharacterSampleValidation](../CharacterSampleValidation/README.md) when the procedural character was replaced by the authored Sprout sample. That harness compiles the current renderer and desktop controller, checks image/offset synchronization and interruption, and measures stopped callbacks. Follow its asset-report and native-run instructions; a finished sample export is required.

The old build command remains a migration wrapper:

```sh
tools/DesktopValidation/build-lifecycle-check.sh
```

It prints a migration notice and invokes the new **build-only** script. It creates `tools/CharacterSampleValidation/.build/native/NativeSampleCheck` and launches nothing. It does not rebuild the old `.build/lifecycle/RendererLifecycleCheck` executable; any retained binary at that path is historical. The old `--headless` interface and scene-update assertions do not apply to the current renderer. The independent `DesktopValidation.app` background/input fixture above is unchanged.

## Historical phase 3 lifecycle evidence

The retired procedural SpriteKit check passed **4 of 4 hidden/handler checks** on 13 September 2026. It created hidden own-app windows and directly invoked constructed-event press/drag cancellation paths, without posting events to the operating system. The [retained headless results](../../docs/results/phase-3/renderer-headless.json) do not include visible rendering.

The historical visible run passed **12 of 12 checks**, including those four cases. Its [retained results](../../docs/results/phase-3/renderer-lifecycle.json) show one initial scene update for a visible paused host and unchanged callbacks after settling. It also covered a previously hidden paused first show, an active reaction interrupted by pause, and neutral static resume. These scene/delegate counters describe the retired renderer, not the current CALayer frame submissions or GPU presentations.

Separate [phase 3 app UI observations](../../docs/results/phase-3/ui-observations.json) confirmed the actual procedural still pet on a fresh paused launch. Disposable fixture calibration confirmed a received blank mouse-down, but subsequent app-targeted window inspection was inconclusive for cross-app focus/routing. The constructed-event cancellation cases verified handler cleanup, not operating-system cancellation delivery or physical input routing. Physical drag, transparency boundaries, and focus checks remain independent review items for the rendered character.

See [the source-backed desktop review](research.md) for API guarantees, renderer migration, and the preserved historical paused-startup findings.
