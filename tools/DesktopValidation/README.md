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

Close its window or use **Quit Desktop Validation** to end the test. It never opens a document. The build was checked with Xcode 26.6 (17F113), Swift 6.3.3, and macOS SDK 26.5 on Apple silicon. Both build scripts use complete concurrency checking and warnings as errors.

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
2. Disable Spriglet's Quiet Behavior during boundary checks so the painted outline remains stationary. Keep the pet shown and unpaused; test saved paused launch separately with the lifecycle check below.
3. Move the pet over the light target and then the dark target. Inspect clear corners, the sprout outline, and the ground shadow. A scene-texture PNG is not evidence of window compositing; observe the actual desktop host.
4. Click a blank target to mark a point, then move the pet so a clear corner covers the crosshair. Use **Inspect marked point** and record both window numbers. Click the marked screen point once and check the received mouse-down count. Repeat for all corners, immediately outside the outline, and the translucent shadow.
5. Position a transparent margin over a native button and click once. Repeat with a fresh scroll gesture over a blank target. Finish any previous momentum before changing the test position, because macOS can keep momentum events attached to their initial receiver.
6. Focus the disposable typing field and enter a short test phrase. Record activation/key-window totals. Click the visible pet body once, then type more without selecting the field again. Check Spriglet's reaction, unchanged underlying click counts, focus totals, and the resulting text. Repeat a quick pointer-entry-and-click gesture.
7. Enable Spriglet's whole-window **Pass Clicks Through** setting and click directly over its body. The underlying receiver should handle the first click. Restore the setting from Spriglet's menu.

Record OS, build, display/scale, input method, and whether a person or app-targeted automation performed the actions. Automation may activate its target application; compare the focus-change totals and limit the conclusion accordingly. These checks do not cover another macOS release, another display, real sleep/lock, Spaces, Stage Manager, full-screen behavior, energy, or all physical input devices.

## Renderer lifecycle regression check

The retained check compiles the real renderer and interaction view with a private local copy of SprigletCore. It does not change Xcode or SwiftPM build products:

```sh
tools/DesktopValidation/build-lifecycle-check.sh
tools/DesktopValidation/.build/lifecycle/RendererLifecycleCheck --headless
```

`--headless` uses a prohibited activation policy, creates only hidden own-app windows, and never orders one onscreen. It checks hidden paused callback quiescence and directly invokes constructed-event press/drag cancellation paths. It posts no event to the operating system. **Four of four checks passed** on 13 September 2026; the [retained headless results](../../docs/results/phase-3/renderer-headless.json) do not include visible rendering.

The default mode deliberately shows disposable, nonactivating, whole-window click-through panels for roughly eight seconds:

```sh
tools/DesktopValidation/.build/lifecycle/RendererLifecycleCheck
```

It adds checks for a cold paused first presentation, a previously hidden paused first show, settled callbacks, a real reaction interrupted by pause, and a neutral static resume. It writes JSON to standard output and exits nonzero on failure. The pause checks require a nonzero initial scene update; zero callbacks cannot hide a renderer that never began. A scene update is still not proof of a GPU presentation, so inspect the initial visible pet separately.

The native visible run passed **12 of 12 checks**, including the four hidden/handler cases, on 13 September 2026. The [retained results](../../docs/results/phase-3/renderer-lifecycle.json) show one initial scene update for a visible paused host and unchanged callbacks after settling. Separate [app UI observations](../../docs/results/phase-3/ui-observations.json) confirmed the actual still pet image on a fresh paused launch. Disposable fixture calibration confirmed a received blank mouse-down, but subsequent app-targeted window inspection was inconclusive for cross-app focus/routing. Physical drag, transparency boundaries, and focus checks remain open.

The direct cancellation cases pass a constructed `NSEvent` to `mouseDown`, `mouseDragged`, `mouseCancelled`, and `mouseUp`. They verify Spriglet's handler cleanup, not when macOS delivers cancellation or how WindowServer routes physical input.

See [the source-backed desktop review](research.md) for API guarantees, open boundary risks, and the paused-startup fix.
