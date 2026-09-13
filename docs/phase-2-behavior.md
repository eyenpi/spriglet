# Phase 2: calm behavior and local choices

Prepared 13 September 2026. Spriglet now has six finite character clips, calm autonomous planning, interaction-aware scheduling, and five persistent settings. The artwork is still procedural. Autonomous activity changes the character's pose; the short desktop walk remains an explicit manual experiment.

## Behavior contracts

`PetAction` is a public String-backed, Codable, Sendable enum with `blink`, `lookAround`, `stretch`, `fallAsleep`, `wakeUp`, and `react`. `PlannedBehavior` contains an action and a delay. `PetBehaviorPlanner(seed:)` is a deterministic value that owns no task, clock, or storage; `next(isSleeping:)` describes the next suggestion from the renderer's settled state.

| Situation | Planned delay | Choice |
| --- | --- | --- |
| Awake and resting | 20–75 seconds | Mostly blinks/looks, less often a stretch, rarely sleep |
| Asleep | 60–180 seconds | Wake up |
| First awake plan after interaction | 45–75 seconds | A gentle blink |

Repeated non-blink awake choices become a blink. The planner never selects `react` autonomously. `resetAfterInteraction()` retains random progress and gives the next awake plan its longer cooldown; a sleeping wake plan preserves that cooldown until the next awake plan. Scheduling delays are not real-time guarantees: the runtime adds one second of tolerance, and system suspension can defer the next action.

The private seeded generator is based on Vigna's [public-domain SplitMix64 reference](https://prng.di.unimi.it/splitmix64.c). Its purpose is reproducible behavior tests; it is not a security primitive or a third-party runtime dependency.

## Rendering and input

The clips have explicit beginning, motion, and settling poses. Nominal authored durations are approximately 0.24 s for blink, 1.60 s for look around, 1.36 s for stretch, 1.05 s for falling asleep, 0.94 s for waking, and 0.78 s for reacting. An awake action requested during a nap includes the wake transition first. A redundant wake while already awake, or sleep while already asleep, does nothing.

The renderer retains at most one queued request. A different request waits for the current clip boundary; the latest wins. A repeated current action coalesces and clears an older queued request. Pause, hide, system suspension, or an explicit reset cancel active and queued clips. Suspension resumes into a neutral pose. `onAnimationStateChanged` observes the updated sleep state, including a static nap reset that changes sleep state without starting another animation.

Awake rest and closed-eye naps are static. `sceneUpdateCount` counts completed `didFinishUpdate()` callbacks; `viewRenderCallbackCount` counts render-delegate calls. Neither is a GPU presentation count. The current short probe verifies that these callbacks stop after settling.

## Scheduler and cancellation

The runtime keeps one pending `Task.sleep(for:tolerance:)`, with a one-second tolerance for normal plans and zero tolerance for short probe deadlines. Cancellation interrupts the sleep without blocking a thread. A generation value rejects stale completions before they can clear a replacement task. The task holds the runtime weakly while waiting. [Apple's current Task.sleep API](https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:))

Scheduling requires the app to be running, Quiet Behavior enabled, motion permitted, no probe in progress, and no active clip, scripted movement, or user interaction. Click/hold/drag/accessibility interaction begins by cancelling the deadline and applying the interaction cooldown; scheduling reconciles after interaction ends. Manual previews and movement also reset the cooldown.

Hidden, paused, occluded, system-asleep, display-asleep, inactive-session, and thermal-pressure causes remain independent. Reduce Motion separately prevents animation. None of these temporary system conditions is persisted as a user choice. Cancelling or replacing a deadline cannot revive its old plan. Startup applies saved hidden/pause before showing the panel or scheduling behavior.

## Local preferences and privacy

`PetPreferencesStore` saves one versioned payload under `dev.spriglet.preferences` in the app's standard defaults domain. The current payload version is 1.

| Saved setting | Initial value |
| --- | --- |
| Hide Pet | Off |
| Pause | Off |
| Pass Clicks Through | Off |
| Show on All Spaces | On |
| Quiet Behavior | On |

The current pose, location, random seed/state, and queued actions are not saved. Invalid, unsupported, or incomplete payloads fall back to initial choices without overwriting the original data during loading. Settings are saved on user changes, without a flush timer or `synchronize()`. Apple documents immediate cache updates and asynchronous persistence for `UserDefaults`, and says `synchronize()` is unnecessary. [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults), [synchronize](https://developer.apple.com/documentation/foundation/userdefaults/synchronize())

The app has no networking, accounts, analytics, global input monitor, or screen capture. `PrivacyInfo.xcprivacy` declares no tracking or collected data and records own-app UserDefaults access under `CA92.1`. Apple's definition limits that reason to information accessible to the app itself. This is an optional declaration for the native macOS prototype; the required-reason submission statement in Apple's current guidance lists the other Apple app platforms. The declaration is not a claim of distribution readiness. [UserDefaults reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype), [required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

During a probe, ordinary scheduling and preference writes are disabled. The command-line probe starts with default choices instead of loading saved choices. An in-app probe temporarily changes flags, then restores the user's prior settings while writes are still disabled. Cleanup checks that the runtime is still running before restoring UI, so shutdown does not re-show the pet.

## Verified results

Debug and Release builds passed with the installed Xcode 26.6 / Swift 6.3.3 toolchain, macOS SDK 26.5, and macOS 26 deployment target on Apple silicon. The stack remains SwiftUI, Observation, AppKit, SpriteKit, Swift concurrency APIs, and a local Swift package, with no remote package dependencies. The bundled privacy manifest passed plist validation.

The full core suite passed **27 test functions / 210 expanded cases in four suites**. The inspected local log is `.build/logs/phase-2-tests.log`. Coverage includes all 128 suspension combinations, screen placement, deterministic/calm behavior invariants, sleep/cooldown rules, all 32 preference combinations, corrupt payloads, unsupported versions, and preservation of unrelated defaults.

The final integrated Release probe completed at **10:40:07 UTC**, passing **all 21 checks** in about one minute. Its [raw results](results/phase-2/probe.json) and [environment with 28 source hashes](results/phase-2/environment.json) are retained. It exercises initial rendering, finite clips, static naps, wake-and-react, coalesced input, finite movement, one replaced deadline firing exactly once, cancellation by pause, hiding, or Quiet Behavior being disabled, and a final ten-second rest. The short explicit scheduler tests exercise the same implementation as the normal long delays; they do not prove a multi-hour natural cadence.

| State | Interval | Scene / render / movement callbacks | Automatic actions | CPU, one core | Physical footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| Static visible | 3.18 s | 0 / 0 / 0 | 0 | 0.025% | 21.02 MiB |
| Reaction | 3.12 s | 95 / 96 / 0 | 0 | 3.197% | 22.20 MiB |
| Settled visible | 3.12 s | 0 / 0 / 0 | 0 | 0.025% | 21.92 MiB |
| Manual window movement | 3.63 s | 0 / 0 / 359 | 0 | 6.972% | 21.95 MiB |
| Paused | 3.14 s | 0 / 0 / 0 | 0 | 0.054% | 21.95 MiB |
| Hidden | 3.01 s | 0 / 0 / 0 | 0 | 0.064% | 21.99 MiB |
| Static nap | 1.06 s | 0 / 0 / 0 | 0 | 0.011% | 22.11 MiB |
| Replaced deadline → blink | 2.06 s | 30 / 31 / 0 | 1 | 1.380% | 24.39 MiB |
| Cancelled by hiding | 0.71 s | 0 / 0 / 0 | 0 | 0.219% | 114.28 MiB |
| Cancelled by preference | 0.75 s | 0 / 0 / 0 | 0 | 0.058% | 114.28 MiB |
| Final settled | 10.36 s | 0 / 0 / 0 | 0 | 0.005% | 22.13 MiB |

These are brief app-process samples on `Mac15,6`, one display, without the controls window or debugger. Power source, scaling, and other system load were not controlled. App activity was false at each phase boundary, but changes between samples may be missed. CPU excludes WindowServer and GPU cost, and clip phases include some time after animation settles. The footprint increase to 114.28 MiB was transient in this run: the final 10.36-second rest returned to 22.13 MiB at approximately 0.0054% of one CPU core, with all counters unchanged. The allocation cause remains unproven; recovery in one run does not establish a memory budget or rule out longer-term growth. The phase 1 control-window snapshot of 129.7 MiB is a different historical workload.

The earlier 20-check run and its matching environment are archived as [initial probe](results/phase-2/probe-initial.json) and [initial environment](results/phase-2/environment-initial.json). The earlier [phase 1 validation and results](phase-1-validation.md) remain historical and are not overwritten by this phase.

## Observed UI and relaunch behavior

Native UI automation against Debug builds recorded these [observations](results/phase-2/ui-observations.json):

- A normal autonomous blink incremented Quiet moments from 0 to 1 and scheduled the next ordinary deadline.
- Turning Quiet Behavior off, Pause on, and Hide Pet on removed the deadline. Those choices survived quitting and relaunching, alongside click-through off and all-Spaces on.
- Starting a diagnostic temporarily showed and unpaused the pet and enabled click-through. Cancelling restored the original choices and no deadline.
- Quitting during another diagnostic ended the process. A subsequent process still loaded the original hidden/paused/quiet-off choices, demonstrating that the temporary probe flags had not overwritten them.
- Nap settled into Napping with one deadline; Wake settled into Resting with the next deadline. Default choices were restored after testing.

When all pet windows were hidden and the controls scene was suppressed, the automation's initial-window lookup timed out despite the process having launched. The optional `--controls` argument now presents the native controls at launch while preserving saved pet choices. It is useful for inspecting a hidden pet without changing its settings.

App-targeted UI automation may activate the app; these observations do not establish physical cross-application click/focus behavior. A separate read-only `vmmap -summary` snapshot of a Debug process with controls open reported 39.5 MiB current footprint and 134.0 MiB peak. That different workload does not explain the Release probe's spike or set a memory budget.

## Remaining acceptance work

The original physical desktop checks remain open: transparent host compositing over known backgrounds, first-click routing through transparent pixels, typing focus in another application, Spaces/full-screen/Stage Manager, multiple displays, actual sleep/lock/session changes, and system accessibility toggles. Scene alpha and window configuration alone do not prove those behaviors.

Observe a full natural nap/wake cycle and a sustained work session with ordinary Quiet Behavior enabled. Check cancellation during an actual drag and the deferred deadline after release. Investigate the transient footprint increase with repeatable conditions and Allocations. GPU/compositor cost and long battery use still require profiling; attach Instruments to the exact verified Release process ID, following the [historical trace-target mismatch](results/profiling-attempt.json). Production artwork and a longer animation library remain future work.
