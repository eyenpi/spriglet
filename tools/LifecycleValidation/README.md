# Desktop lifecycle acceptance

Run these checks on a logged-in Apple silicon Mac with the full Xcode toolchain:

```sh
./scripts/test.sh
./scripts/test-desktop.sh
./scripts/build.sh Debug
./scripts/build.sh Release
```

The native runner compiles the production app controls, environment, runtime, window host, view and display clock. `./scripts/test-desktop.sh --app-only` runs registration/menu and process-lock checks without creating windows or requiring a display; `./scripts/test.sh` includes that mode. Registration tests inject a fake service, so neither mode changes the user’s macOS login items. It creates real nonactivating panels and advances real display links while supplying isolated notification centers, display measurements and mouse-button state. It does not lock the Mac, sleep its displays, broadcast synthetic lock events to other apps or change display settings. The ordinary app and its saved files are not used by the runner.

Checks cover native body picking, transparent-corner click-through and drag capture across empty pixels; ordered and repeated system/display sleep, lock and session transitions; suspension-time input; Spaces recovery; missed mouse-up; unchanged display notifications; disconnect, no-display, reconnect and resolution fallback; repeated reopen/start/stop; observer cleanup; exclusive launch lease release/error handling, eight simultaneous contenders and recovery after killing the owner; and default-off, read-only startup, external registration changes, approval, unavailable states, failed changes, retries and native menu actions. Synthetic secondary displays exercise negative global coordinates and both notched and unnotched homes. Unit tests also cover compact and ultrawide scene geometry, stale drag events, gesture/deformation cleanup and independent suspension reasons.

For an actual fullscreen Space transition, run:

```sh
./scripts/test-desktop.sh --prepare-fullscreen
```

Open the resulting `.build/lifecycle-validation/FullscreenFixture.app` in Finder and click its blank window within 30 seconds. It enters/leaves fullscreen and checks that the companion joins the active Space without becoming key, then restores the previous app. Its result is saved in `.build/lifecycle-validation/fullscreen-result.txt`. This separate local app uses the normal AppKit launch/run loop; the default runner remains a finite process that never requests focus. A failure to focus or enter fullscreen is reported as a failure, never as a passing simulated test.

## Physical-device matrix

Automated notification injection verifies recovery logic, not delivery by macOS during a real hardware transition. Before release, repeat each relevant row while Mallow is resting, invited, falling and being dragged. After interruption, release the mouse, click an unrelated window, then drag Mallow again. Check that the unrelated app retains keyboard focus, transparent margins pass clicks through, only one Mallow is visible, its home is on an available display and its face continues blinking.

| Scenario | Procedure and expected result |
| --- | --- |
| System sleep/wake | Sleep from the Apple menu and wake. Mallow hides during suspension and returns to its resting home with no catch-up flight or retained grab. Repeat several cycles. |
| Display sleep/wake | Let displays sleep without system sleep, then wake. Repeat with an external display and with the lid closed/open. Home and animation recover. |
| Lock/unlock | Lock with Control-Command-Q, unlock and repeat. Mallow resumes only after lock, display and session suspension reasons have cleared. |
| Fullscreen apps | Enter and leave Safari/TextEdit fullscreen; type before/after transitions and reopen Spriglet while fullscreen. The other app remains focused, and Mallow stays at an available home. Test video and presentation fullscreen separately because apps can use different window levels. |
| Spaces/Stage Manager | Switch between desktop and fullscreen Spaces while dragging; release over the destination Space. No stuck capture, accidental click or jump to the focused app's display. Repeat with Stage Manager enabled. |
| Display unplug/replug | Start on the primary display, unplug it while dragging and while asleep, reconnect it and repeat. Home falls back to the available primary display, then returns to the original display when it is available. Test mirrored and extended layouts and Separate Spaces on/off. |
| Resolution/scaling/arrangement | Change scaled resolution, main display, arrangement, menu-bar and Dock placement. Mallow recomputes its measured home/floor; unrelated unchanged-screen notifications preserve interaction. |
| Launch at login | On a new install, verify the option is off and no startup registration is made. Enable it from the right-click menu, compare the displayed state to System Settings, complete any approval, then sign out/in and verify exactly one Mallow appears. Reopen from Finder and overlap direct executable launches while it is running. Disable the option and verify Mallow stays running and no app is launched at the next login. Revoke consent or remove the item in System Settings and reopen the menu: its state must change without re-registering. Test approval cancellation and any signature/registration failure on the distributed build. Quitting must preserve the chosen registration. |
| Repeated launches | Open the same build repeatedly from Finder, then launch its executable concurrently. Finder reopen returns home without requesting focus; overlapping executable launches exit without a second companion. Quit from Mallow's right-click menu and relaunch. Force-quit once and relaunch to verify kernel lock release. Leave an older preview running once: the new build must exit without a second companion, even if the older preview predates the lock. |
| Character picking and catch | Click each transparent corner and the area behind home; clicks reach the app underneath and cannot grab Mallow. Grab the visible outline, feet and palms, then drag beyond the silhouette without losing capture. Move slowly into and out of catch range: the upward look/reach appears near home, fades away outside, and release catches only in range. Repeat with Reduce Motion and both notched and unnotched displays. |
| Quit and focus | Right-click Mallow, dismiss its transient menu, then type in the previous app. Choose Quit Spriglet and verify the panel disappears and the next launch succeeds. |

Record hardware, macOS version, display arrangement, Reduce Motion/Low Power Mode and observed results in ignored `.build/` or `docs/`, not in the public source tree. Physical display removal, actual lock/unlock, sleep/wake, third-party fullscreen behavior and sustained energy use require device acceptance even when all regression checks pass.

## Platform details

Home selection uses display IDs and measured geometry rather than `NSScreen.main`, which follows keyboard focus. The preferred display is remembered only for the running session. No display inventory means no host or clock. Recovery refreshes measurements before restoring visibility and reconstructs the display link, even when its display ID/cadence are unchanged.

Screen lock uses loginwindow's `com.apple.screenIsLocked`/`com.apple.screenIsUnlocked` distributed broadcasts with immediate delivery for an inactive accessory app. These names are a macOS convention, not a documented AppKit lock API; verify their delivery on supported macOS versions. Public workspace session/display/system-sleep notifications remain independent suspension sources. There is no private framework call or global keyboard monitor. Launching an executable after the Mac is already locked cannot replay an earlier lock broadcast; actual launch-while-locked acceptance remains necessary.

An advisory lock in the app's Application Support directory admits one executable at a time within its container. The file is not unlinked: closing its descriptor or process exit releases the kernel lock, including after a crash. After acquiring the lease, startup also checks macOS’s running applications and exits if another Spriglet has finished launching, including a preview predating the lock. Unfinished contenders are ignored so the lease owner can start. The lease covers modern copies using the same app container; a concurrently starting older binary that lacks the lock cannot participate in that election.
