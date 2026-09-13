# Phase 3: desktop reliability and repeated activity

Prepared 13 September 2026. This milestone adds saved desktop placement, a static first presentation for a pet launched paused, explicit interaction cancellation, and an opt-in repeated-activity check. The character and its six clips remain procedural; autonomous roaming is not added. The evidence below distinguishes app behavior, native harness checks, and the physical desktop work still required. Earlier [phase 1](phase-1-validation.md) and [phase 2](phase-2-behavior.md) results remain historical evidence for their recorded source versions.

## Saved placement

`PetSavedPlacement` stores a display UUID and normalized horizontal/vertical positions within the usable travel range of that display. It validates finite coordinates in `0...1`. Restore applies the current visible frame and pet size, so changed display geometry still constrains the pet to the available area. A missing preferred display uses an available fallback without overwriting the preferred display identity.

The host obtains the display ID through the typed macOS 26 `NSScreen.cgDirectDisplayID` API and converts it to a UUID with ColorSync. It resolves screens and visible frames from the current topology. UUID behavior across real hardware disconnects or reboots still needs observation. [Typed display ID](https://developer.apple.com/documentation/appkit/nsscreen/cgdirectdisplayid-8ph5i), [display UUID conversion](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:)), [visible frame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe), [current screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)

The desktop saves a settled user placement after dragging, a directional control, Bring Pet Home, or Next Display. Directional buttons move the pet by 48 points, clamp it to the visible area, and record one settled position; these native controls offer a keyboard-accessible positioning alternative without installing global shortcuts. The short scripted walk remains an experiment and does not become the saved home. Display changes stop movement and active interaction before restoring or constraining placement. The preferences payload is now version 2; version 1's five choices still load, and a malformed optional placement is discarded without resetting valid hidden/pause choices. Loading does not rewrite stored data.

An ordinary in-app diagnostic snapshots both the saved home and the actual panel placement. Cleanup restores the saved settings and the actual starting position separately, which matters when the saved display is currently absent or the panel moved during a manual walk. Shutdown prevents cleanup from re-showing the pet. These are implementation contracts; the results section records which paths have been exercised.

## Paused presentation and cancelled interaction

A newly constructed renderer starts paused. When its host first becomes visible, it permits one neutral scene update even if the user's Pause choice remains on, then stops again. A hidden host does not perform that initial update. Pausing an already presented pet still interrupts active/queued clips immediately; resuming presents neutral without restarting the cancelled action. The retained native-window harness and app UI checks below exercise these distinctions.

The interaction view now handles the macOS 26 `mouseCancelled(with:)` callback by clearing its press/drag state. Constructed-event tests show that a later mouse-up cannot turn a cancelled gesture into a click or committed drag. This verifies handler behavior; actual system delivery and physical dragging remain separate checks. [Apple's cancellation callback](https://developer.apple.com/documentation/appkit/nsresponder/mousecancelled(with:)), [desktop source review](../tools/DesktopValidation/research.md)

## Run the bounded soak

Quit any existing Spriglet instance, keep an unlocked desktop session available, then run from the repository root:

```sh
./scripts/soak.sh > /tmp/spriglet-soak.json
```

The script builds Release and directly starts its executable with `--soak`. It refuses an existing Spriglet process both before and after the build. Build/progress instructions go to stderr; the final JSON goes to stdout. Exit status is `0` for passing functional checks, `1` for failure or mismatched report identity, and `2` for a blocked or cancelled run without a report. The script verifies that the report names the requested Release executable and that a passing result includes all 100 cycles.

The controls also expose **Run 100-Cycle Check**, **Cancel Check**, and **Copy Report**. The same bounded workload runs inside the existing app; that workload includes the control window and should be measured separately from the isolated command-line run. `--controls` can open the native control window at launch while retaining saved hidden/pause choices.

The soak normally takes about four to five minutes. It has no polling loop or recurring production sampler. Every wait uses cancellable `Task.sleep(for:tolerance:)`; each individual wait is at most 15 seconds. Normal autonomous planning stays disabled for the diagnostic. Its temporary shown/unpaused/click-through/manual-only flags are not saved, and the command-line path starts from defaults instead of loading the user's saved choices. [Apple's current Task.sleep API](https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:))

## Workload and report contract

| Phase | Work performed | Evidence collected |
| --- | --- | --- |
| Warm-up | Allow initial rendering, then run one finite reaction | Initial frame and reaction completion |
| Warmed baseline | Rest for 3 seconds | Quiet counters, process CPU, physical footprint |
| 100 cycles | Hide for 0.25 s, show and settle for 0.25 s, react and settle for 1.35 s | Per-cycle visibility, actual animation start/completion, hidden counters, unexpected movement/autonomy |
| Every 10 cycles | Sample hidden/shown/settled footprint; rest another 0.75 s | Footprint observations and a quiet counter interval |
| Final recovery | Rest for three consecutive 15-second intervals | Continued quiet counters and footprint recovery or retained difference |

Waits use 50 milliseconds of scheduling tolerance. Elapsed times in the report come from actual measurements, so their values may exceed the requested duration. A failed functional invariant or a blocked visibility/motion policy ends the workload early with the completed portion recorded; cancellation unwinds through the shared diagnostic cleanup.

A successful full run produces 100 cycle records, 20 functional checks, 15 interval measurements, and 45 footprint samples. `functionalChecks` determine the report's `outcome`. The separate `resourceObservations` object contains the warmed baseline, final settled footprint, maximum observed sample, final-minus-baseline difference, and sampling count. None of these resource values has an invented pass/fail budget. A nil/unavailable footprint remains unavailable.

The maximum observed sample is not a high-water mark: short peaks can occur between checkpoints. A final decrease distinguishes a transient allocation in this run from memory still held at the end of this workload. It does not identify the allocation's owner, prove an absence of leaks, or predict multi-hour behavior. Compare repeated runs under controlled conditions before setting a memory budget.

The report includes executable path, process ID, Debug/Release configuration, bundle/version/build fields, and embedded Xcode/SDK identifiers when available. Keep the matching source and binary hashes in the environment artifact when retaining a run. These identifiers support attaching Instruments to the actual process rather than resolving an older bundle by identifier. [Bundle.executableURL](https://developer.apple.com/documentation/foundation/bundle/executableurl), [ProcessInfo.processIdentifier](https://developer.apple.com/documentation/foundation/processinfo/processidentifier)

CPU samples cover Spriglet's process only. Scene counts represent completed `didFinishUpdate()` callbacks; render-delegate callbacks are also counted. Neither counter is a GPU submission count, and neither captures WindowServer cost or battery use. Motion eligibility is checked at phase boundaries, so temporary changes that clear between boundaries can be missed. The workload respects system motion policy rather than changing system preferences.

`OSSignposter` marks finite measurement intervals for a future Instruments capture. For memory attribution, use Allocations, VM Tracker, and Metal resource events against the verified process, then compare allocations around the repeated transitions and final rest. Apple's current guidance distinguishes allocations from footprint and notes that Allocations alone does not include private Metal resources. [OSSignposter](https://developer.apple.com/documentation/os/ossignposter), [analyzing Metal app memory](https://developer.apple.com/documentation/xcode/analyzing-the-memory-usage-of-your-metal-app)

## Verification status

Final Debug and Release builds passed with Xcode 26.6 / Swift 6.3.3 and macOS SDK 26.5, targeting macOS 26 on Apple silicon. The Release app passed strict signature verification and its bundled privacy manifest passed plist validation. These are local ad-hoc development builds. The full core suite passed **40 functions / 240 expanded cases in five suites**, including placement round trips, geometry limits, version migration, and invalid optional placement handling. [Apple's current Xcode requirements](https://developer.apple.com/xcode/system-requirements/)

The new soak source also passed isolated Swift 6 typechecking with complete concurrency checking, MainActor default isolation, and warnings treated as errors. The executable script passed zsh and embedded Python syntax checks; these checks do not constitute runtime or resource results.

The [native visible lifecycle harness](results/phase-3/renderer-lifecycle.json) passed **12/12 checks**. Its cold visible paused host completed one scene update and two render-delegate callbacks, then stayed unchanged; a hidden paused host stayed at zero until first shown. The same run exercised a real reaction interrupted by pause and a static neutral resume. Two cases directly invoke cancelled press/drag handlers. The separate [headless run](results/phase-3/renderer-headless.json) passed **4/4 checks**, covering those cancellation handlers and hidden paused behavior; it does not cover visible presentation. These runs use disposable native windows and do not prove GPU presentation or physical event routing.

The [quick Release probe](results/phase-3/probe.json) completed at **11:20:12 UTC**, passing **21/21 checks**. Its final 10.65-second settled interval recorded zero scene, render, movement, and automatic-action counters, approximately **0.0054% of one CPU core**, and **22.09 MiB** footprint. These remain short app-process observations.

The [100-cycle Release soak](results/phase-3/soak.json) completed at **11:25:15 UTC**. It passed **100/100 cycles and 20/20 functional checks** in **251.24 seconds**, with 45 footprint samples. The script verified Release process **92475** at the exact executable path recorded in its report. The [matching environment](results/phase-3/environment.json) retains 37 source/script hashes and both Debug/Release binary hashes.

The warmed baseline was **22.03 MiB**, the largest observed sample was **114.34 MiB**, and all three final resting samples were **22.14 MiB**. The final-minus-baseline difference was **0.109375 MiB (112 KiB)**. The large sample rise cleared before the final intervals in this run; its allocation cause remains unproven. Neither this recovery nor a passing functional outcome establishes a production memory budget or rules out growth during longer use.

| Soak interval | Measured duration | Scene / render / movement / automatic counters | CPU, one core | Footprint |
| --- | ---: | ---: | ---: | ---: |
| Warmed baseline | 3.02 s | 0 / 0 / 0 / 0 | 0.01482% | 22.03 MiB |
| Settled after 100 cycles | 0.77 s | 0 / 0 / 0 / 0 | 0.02317% | 24.47 MiB |
| Final rest 1 | 15.00 s | 0 / 0 / 0 / 0 | 0.00469% | 22.14 MiB |
| Final rest 2 | 15.01 s | 0 / 0 / 0 / 0 | 0.00184% | 22.14 MiB |
| Final rest 3 | 15.01 s | 0 / 0 / 0 / 0 | 0.00290% | 22.14 MiB |

This was an uninstrumented run on `Mac15,6`, macOS 26.6.2, one connected display, with controls closed and no debugger or profiler. A single power-status observation reported AC attached, battery 80%, not charging; it was not a battery-consumption measurement. Other desktop/system load was uncontrolled. App activity was false at each measured interval boundary. The separate GPU captures below must not be merged with these CPU and footprint values.

## Bounded GPU observations

Two separate Metal System Trace captures attached to verified Release process IDs. Both trace records identify the expected executable, and the retained summaries include its matching SHA-256. Process references in exported XML were resolved before attributing rows to Spriglet; selecting a single target does not make every captured GPU row belong to that target. [Apple's Metal performance guidance](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app)

| Capture | Conditions | Measured duration | Spriglet command-buffer submission rows | GPU interval rows directly attributed to Spriglet |
| --- | --- | ---: | ---: | ---: |
| [Paused](results/phase-3/paused-metal-summary.json), PID 92756 | Shown, paused, Quiet Behavior off, controls closed | 5.909226 s | 0 | 0 |
| [Active control](results/phase-3/active-control-metal-summary.json), PID 93035 | Shown, unpaused, Quiet Behavior off, controls visible; Look Around and Pet requested | 11.459583 s | 197 | 392 |

The active control confirms that this capture method observed GPU work from the app. Its SwiftUI controls were also visible, so those counts do not isolate character rendering. The paused and active captures contain 152 and 80 additional Active GPU intervals, respectively, without a resolved process owner or unique submission mapping. They cannot be excluded from Spriglet with certainty; the paused result therefore establishes no directly attributed work during this short capture, rather than absolute zero GPU work.

Both recorder logs reported completion without warning/error/loss indicators, and the exported XML had no dangling references or mismatched row widths. Those checks do not prove a loss-free recording. Hardware performance counters and shader timelines were disabled. Intervals may overlap or nest, and row counts are not GPU utilization, compositor cost, or energy measurements. Raw traces and all-process exports stay in the ignored local build directory; only sanitized summaries are tracked. Sustained normal-use, compositor, and battery measurements remain open.

## Scoped app UI observations

The [nine scoped UI scenarios](results/phase-3/ui-observations.json) include seven passing app scenarios and two observations that do not establish a physical-input result. The first eight used Debug; the final in-app soak cancellation used Release:

- A fresh shown+paused launch displayed the actual still pet, with one scene update and no deadline. A fresh hidden+paused launch stayed at zero updates until Show, then presented one while remaining paused.
- Left and Up moved the pet by 48 points each, from `(1308, 92)` to `(1260, 140)`. A new hidden+paused process retained the second origin and choices. Repeated Right/Down commands stopped at the current display's reachable edge.
- Cancelling a quick check after its scripted movement restored the original origin, Pause, click-through, and Quiet Behavior choices. Quitting during the 100-cycle check ended the process; a subsequent process still loaded the original hidden+paused home and choices.
- Cancelling the in-app 100-cycle check on Release after reaction activity restored the starting hidden+paused flags, Quiet Behavior off, click-through off, nondefault home, and no deadline.
- A coordinate click on the disposable dark target incremented its actual mouse-down counter, but a later window-stack prediction differed. App-targeted automation can change activation/order, so this is calibration evidence rather than a focus/routing result.
- The automation tool could inspect the nonactivating pet panel but returned `noWindowsAvailable` for dragging it. Directional controls validated placement persistence; the tool limitation does not show that physical dragging fails.

These UI observations used one display. They do not establish keyboard traversal/VoiceOver, real display changes or reboot behavior, host alpha over controlled backgrounds, physical cross-app focus, or system sleep/wake.

## Desktop acceptance matrix

These checks require an actual desktop session. Pure placement tests and app-targeted automation do not substitute for the physical input and system-transition rows.

| Check | Concrete procedure and expected result | Status |
| --- | --- | --- |
| Saved paused first presentation | Launch shown+paused, then separately hidden+paused and Show; present one static pose while preserving Pause | Native harness and scoped UI passed |
| Placement relaunch | Use directional controls to set a nondefault home, quit, relaunch, and compare placement; separately repeat with a physical drag near a screen edge | Directional controls passed on one display; physical drag pending |
| Diagnostic restoration | Begin with saved hidden/pause choices and a nondefault placement; cancel each diagnostic, then quit during another and relaunch; flags and home remain unchanged | Quick/soak cancellation and soak quit/relaunch passed through scoped UI checks |
| Click and typing focus | Type in a disposable document, physically click the pet body, and continue typing; the document keeps keyboard focus while the pet reacts | Pending |
| Transparent area and click-through | Place a disposable button/window behind the pet. Click a transparent corner with ordinary interaction, then body/corner with whole-window click-through enabled; record actual routing | Pending |
| Host compositing | Inspect the pet over known light and dark backgrounds; no opaque host rectangle or crop artifact should appear | Pending |
| Drag lifecycle | Hold and drag through a scheduled deadline, release, and inspect the next deadline; no autonomous clip should begin during the interaction | Direct cancellation handlers passed; physical path pending |
| Spaces and full-screen | Switch Spaces, enter another app's full-screen Space, and exercise Stage Manager with all-Spaces on and off; record visibility and focus | Pending |
| Display topology | Move to another display, disconnect/reconnect it, change resolution/scaling, and relaunch; the pet remains reachable and its preferred display identity is retained | Pending |
| Actual system state | Sleep/wake, lock/unlock, and change session state; hidden and manual pause must remain independent of those transitions | Pending |
| Accessibility and power | Toggle Reduce Motion and exercise Low Power Mode; observe stopping/resuming policy and reduced frame-rate hints | Pending |
| Long resource behavior | Repeat the soak, then observe a sustained normal-use session and natural nap/wake cycle; separately profile CPU/GPU/compositor and battery cost | Bounded 100-cycle run passed; short paused/active GPU captures retained; sustained-use, compositor, and energy gates pending |

The earlier [trace-target mismatch](results/profiling-attempt.json) remains historical evidence and a reason to verify the exact process ID before profiling. The new captures support only the bounded GPU observations above; energy, battery, compositor cost, and long-session behavior remain unmeasured.
