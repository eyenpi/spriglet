# Desktop lifecycle acceptance

Run these checks on a logged-in Apple silicon Mac with the full Xcode toolchain:

```sh
./scripts/test.sh
./scripts/test-desktop.sh
./scripts/build.sh Debug
./scripts/build.sh Release
```

The native runner compiles the production app controls, environment, runtime, window host, view and display clock. It creates real nonactivating companion/Help panels and an ordinary native Settings window and advances real display links while supplying isolated notification centers, display measurements and mouse-button state. It does not lock the Mac, sleep its displays, broadcast synthetic lock events to other apps or change display settings. The ordinary app and its saved files are not used by the runner.

`./scripts/test-desktop.sh --app-only`, also included by `./scripts/test.sh`, runs registration, menus, accessible login Settings layout, isolated preference restoration and launch-lease checks without showing windows or creating a status item. Every app delegate fixture and all registration tests inject a fake service and never change macOS login items.

Checks cover native body picking, transparent-corner click-through and drag capture across empty pixels; ordered and repeated system/display sleep, lock and session transitions; suspension-time input; Spaces recovery; missed mouse-up; unchanged display notifications; disconnect, no-display, reconnect and resolution fallback; repeated reopen/start/stop; observer cleanup; exclusive launch lease release/error handling, eight simultaneous contenders and recovery after killing the owner; default-off startup, external login changes, approval, failed registration/removal and live Settings status; first-launch and malformed preferences; fresh-process persistence; saved home selection and live edits during drag/sleep; disconnected display fallback/reconnect across display-number changes; and accessible native Settings controls and close/reopen. Menu-bar checks cover synchronized labels and Settings, pause-time freeze and click-through, retained Hide/Pause across suspension and display loss, saved edits while hidden/paused, one keyboard-capable Settings window, nonkey Help, unclipped layout, accessible checkbox actions and status/window shutdown cleanup. Accessibility checks send Tab and Shift-Tab through native Settings controls, invoke app-menu key equivalents, exercise character state/action providers including stale and paused actions, and apply live Reduce Motion during interaction. Core tests cover every movement phase, deliberate grabs, imprecise release, blinking and restored full motion. Separate finite AppKit processes exercise the real menu-bar Quit target during rest, grab, fall, catch, pause, hide, introduction and Settings, then verify callback/window cleanup. Preferences use disposable suites, never the app’s production defaults. Synthetic secondary displays exercise negative global coordinates and both notched and unnotched homes. Unit tests also cover compact and ultrawide scene geometry, stale drag events, gesture/deformation cleanup and independent suspension reasons.

Quit, preference-restoration and launch-lease subprocesses have a five-second parent deadline. Quit is bounded independently of the child’s main-queue watchdog. On timeout the parent requests termination, then sends SIGKILL if the child remains running after 250 ms, and allows at most one further second for cleanup. A timeout fails validation. The runner also verifies normal subprocess exit and cleanup of a headless child that ignores SIGTERM.

To check those subprocess bounds without opening panels, creating a status item or starting AppKit:

```sh
./scripts/test-desktop.sh --test-quit-timeout
```

Preferences can also be validated headlessly, including a fresh process that restores saved choices from a disposable suite:

```sh
./scripts/test-desktop.sh --test-preferences
```

Cross-display runtime integration uses the Mac's connected display arrangement and an isolated preference suite:

```sh
./scripts/test-desktop.sh --test-multi-monitor
```

This requires at least two connected logical displays. It verifies production runtime dispatch, global/local conversion, continued native panel and view identity, capture across retargeting, save-on-success semantics, cancellation, unrelated preference preservation and reload. It injects pointer points through the production host callback; it does not claim physical mouse travel, seam stability, mirror transitions or hot-unplug acceptance. Those remain rows in the physical-device matrix below.

Introduction checks use an isolated preferences suite and cover first launch without activation, shared-clock playback, Next/Back/direct navigation, repeated selection of the current step in normal and reduced motion, unambiguous layout, live Reduce Motion changes, suspension and display loss, remembered dismissal, Help replay while hidden/paused, saved edits and recovery without resuming playback, Done/close/app-scoped Escape and shutdown cleanup. To run only introduction integration checks without activating the app or opening Settings:

```sh
./scripts/test-desktop.sh --test-introduction
```

This path creates nonactivating panels and a temporary status item. To review the actual introduction window without changing the ordinary app's preferences:

```sh
./scripts/test-desktop.sh --prepare-introduction
```

Open the resulting `.build/lifecycle-validation/IntroductionFixture.app`. It uses the production app delegate and runtime with an isolated preferences suite, which is removed on ordinary exit; the fixture exits after five minutes. For PNG frames of the animated input scripts, use `./scripts/preview.sh .build/preview/introduction --introduction`.

For an actual fullscreen Space transition, run:

```sh
./scripts/test-desktop.sh --prepare-fullscreen
```

Open the resulting `.build/lifecycle-validation/FullscreenFixture.app` in Finder and click its blank window within 30 seconds. It enters/leaves fullscreen and checks that the companion joins the active Space without becoming key, then restores the previous app. Its result is saved in `.build/lifecycle-validation/fullscreen-result.txt`. This separate local app uses the normal AppKit launch/run loop; the default runner remains finite, requesting focus only while exercising the explicit native Settings action. A failure to focus or enter fullscreen is reported as a failure, never as a passing simulated test.

## Bundled keyboard and daily-use fixture

```sh
./scripts/test-desktop.sh --prepare-daily-use
```

Open the printed `Daily-UseFixture.app`. It runs the production app delegate, runtime, menus, Settings and character with disposable preferences and fake login registration, skips the introduction, and quits after five minutes. It can coexist with the ordinary app without editing its preferences. Its app menu is named “Mallow Lifecycle Fixture”; its leaf uses the ordinary “Spriglet controls” accessibility label. Quit the fixture when finished.

Use Control-F8 (or Fn-Control-F8), arrows and Return to choose a menu action. Open Settings with the menu or Command-comma; Tab and Shift-Tab traverse all enabled controls, popup arrows choose values, and Space operates buttons. Repeat with macOS keyboard navigation off and on. Verify Command-Shift-H/P/M and Command-W with a real focused Settings window. The unbundled regression runner can be denied activation by WindowServer: it reports this explicitly and exercises the native close target directly instead of claiming responder-chain Command-W acceptance.

First-launch nonactivation and passive recovery focus are tested separately from explicit introduction-button navigation, which may acquire keyboard focus. Character, Help, visibility, pause and recovery actions preserve the existing focus. Settings explicitly requests activation.

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
| Repeated launches | Open the same build repeatedly from Finder, then launch its executable concurrently. Finder reopen returns home without requesting focus; overlapping executable launches exit without a second companion. Quit from Mallow's right-click menu and relaunch. Force-quit once and relaunch to verify kernel lock release. Quit an older pre-lock preview before testing. |
| Character picking and catch | Click each transparent corner and the area behind home; clicks reach the app underneath and cannot grab Mallow. Grab the visible outline, feet and palms, then drag beyond the silhouette without losing capture. Move slowly into and out of catch range: the upward look/reach appears near home, fades away outside, and normal-motion release catches only in range. With Reduce Motion, the upward gaze is still and every release returns directly home. Repeat on both notched and unnotched displays. |
| Settings and restoration | Open Settings from the leaf menu, character menu, Command-comma or VoiceOver. Verify one window after repeated opens; change every size, intensity, display and location; quit/relaunch and check restoration. Unplug the chosen display with Settings open, edit size/location, then reconnect. Repeat with Reduce Motion, sleep and mirrored displays. The saved display remains selected while absent and closing Settings leaves Mallow running. |
| Menu-bar controls | Use Show/Hide and Pause/Resume in the leaf menu and Settings; labels and checkboxes stay synchronized. Hide through sleep, lock, Space switches and display reconnect, then recover with Show, Bring Home and Finder reopen. Pause while dragging releases capture. Open and close Settings/Help repeatedly; Settings takes keyboard focus explicitly, while Help and recovery leave it unchanged. The leaf stays available when Mallow is hidden. |
| VoiceOver | Navigate to the leaf and character. Speak each state, use Invite, Bring Home, Pause/Resume, Hide, Settings, Meet Mallow and Help, and recover hidden Mallow from the leaf. Verify paused actions and catch readiness, meaningful labels/values, popup selections and speech after changes. Provider invocation in the runner does not verify speech, discovery or rotor behavior. |
| Reduce Motion | Enable before launch and during hover, invitation, reaction, grab, catch, fall, hop, walk and return. Check still reveal/state changes, no decorative body/gait motion, retained blinking, responsive dragging and immediate home on any release. All five introduction demos remain still; Hide/Pause/Bring Home, Settings changes and lifecycle recovery respect the policy. Disable it and verify cancelled movement does not restart. |
| Quit and focus | Right-click Mallow, dismiss its transient menu, then type in the previous app. Choose Quit Spriglet from both menus and verify the panel disappears and the next launch succeeds. |
| Introduction | With a fresh local preference domain, launch and check that Meet Mallow appears without taking focus. Browse all five demos, dismiss with Skip, Done, Escape and close, then relaunch and check it stays dismissed. Replay from Meet Mallow in the leaf menu or Mallow's right-click menu, the native Help menu and the Help panel. Repeat with Reduce Motion, VoiceOver, fullscreen and display unplug/replug; check all controls and text remain reachable and the everyday character stays free of instructions. |

Use [device-results-template.md](device-results-template.md) to record hardware, macOS version, display arrangement, Reduce Motion/Low Power Mode and observed results in ignored `.build/` or `docs/`, not in the public source tree. Physical display removal, actual lock/unlock, sleep/wake, third-party fullscreen behavior and sustained energy use require device acceptance even when all regression checks pass.

## Platform details

Home selection uses measured geometry rather than `NSScreen.main`, which follows keyboard focus. Automatic display selection keeps the initial primary display for the running session. An explicit home display is saved by macOS display UUID so changes to session display numbers do not lose the choice. Missing saved displays fall back to the available primary without changing preferences. No display inventory means no host or clock. Recovery refreshes measurements before restoring visibility and reconstructs the display link, even when its display ID/cadence are unchanged.

Screen lock uses loginwindow's `com.apple.screenIsLocked`/`com.apple.screenIsUnlocked` distributed broadcasts with immediate delivery for an inactive accessory app. These names are a macOS convention, not a documented AppKit lock API; verify their delivery on supported macOS versions. Public workspace session/display/system-sleep notifications remain independent suspension sources. There is no private framework call or global keyboard monitor. Launching an executable after the Mac is already locked cannot replay an earlier lock broadcast; actual launch-while-locked acceptance remains necessary.

An advisory lock in the app's Application Support directory admits one executable at a time within its container. The file is not unlinked: closing its descriptor or process exit releases the kernel lock, including after a crash. Startup also exits beside an already-launched older Spriglet that predates the lease. Unfinished current contenders are ignored while the lease admits one owner; a concurrently starting older binary without the lease cannot participate in that election.
