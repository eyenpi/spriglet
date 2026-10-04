# Idle energy profiling

Use the full Xcode toolchain and a quiet desktop. Keep the same display, scale,
refresh rate, power source and thermal conditions for both revisions. Run native
profiles sequentially; do not run compilation or stress workloads alongside a
comparison. Results and traces belong under ignored `.build/energy/`.

```sh
mkdir -p .build/energy
./scripts/profile-energy.sh --native 120 > .build/energy/normal.csv
.build/energy/companion-energy --native 120 --low-power > .build/energy/low-power.csv
python3 tools/EnergyProfile/summarize.py .build/energy/normal.csv .build/energy/low-power.csv
```

The native session shows a temporary, click-through Mallow beside the app's home
and closes it when the duration ends. It uses the production `CompanionEngine`,
`MallowRenderer`, `CompanionWindowHost`, `CompanionView` and `ScreenFrameClock`.
Input is held outside the character so mouse activity cannot change the workload.
It does not replace the running app or change system power settings. The optional
draw callback only takes timestamps when profiling is enabled. Production draws
have no sampler, sample timer or collected frame history.

`--low-power` forces the existing core power policy in this isolated session; it
does not toggle macOS Low Power Mode. Also test the ordinary app with the real
system mode enabled and disabled, on battery, including hover, wave, swing, drag,
catch and return. Unit tests verify blink visibility, breathing range and matching
simulation poses/timing across cadences. Subjective feel and system notifications
still need device acceptance. Deliberate motion stays at 60 fps normally and
30 fps in Low Power Mode; resting peeks use 20 and 15 fps respectively. Grounded
walking remains at 30 fps. Reduce Motion and serious heat cap all of these at
15 fps; sleep, inactive sessions and critical heat suspend the production runtime.

CSV columns distinguish simulation updates (`frames`) from actual AppKit draws
(`draws`). CPU is process user plus system time as a percentage of one core. Draw
duration measures the view's transform and vector drawing, excluding compositor
and WindowServer work. Memory includes current resident bytes, physical footprint,
and live allocator bytes/blocks summed across zones. Live allocation counts are
not cumulative allocation churn. Sampling uses constant-size counters and flushes
output every interval, so the tool does not build a history in memory.

## Capture a baseline before renderer edits

Build the tool on the original revision, copy its executable under `.build/energy/`,
and preserve a native CSV and a production preview. This freezes the measured
implementation while later builds update the working executable. Use a fixed
`--rate 30` for a comparison that isolates renderer cost from the cadence change.

```sh
./scripts/profile-energy.sh --workload 1800 --rate 30 > .build/energy/before-workload.csv
cp .build/energy/companion-energy .build/energy/before
.build/energy/before --native 120 > .build/energy/before-native.csv
./scripts/preview.sh .build/energy/before-preview

xcrun xctrace record --template 'Time Profiler' --attach APP_PID --time-limit 30s --output .build/energy/cpu.trace
xcrun xctrace record --template Allocations --attach APP_PID --time-limit 30s --output .build/energy/allocations.trace
```

Replace `APP_PID` with the target app's PID, and inspect the traces in Instruments.
Time Profiler shows where drawing and simulation spend CPU. Allocations provides
transient allocation churn and stacks. If that instrument cannot record on the
installed OS/toolchain, report that limitation; live allocator statistics cannot
establish cumulative churn. An optional `MallocStackLogging=1` native run with
`malloc_history PID -callTree -noContent` can identify retained allocation stacks.
Do not use instrumented runs for CPU or steady-memory comparisons, because the
profiler retains its own allocation history.

## Memory soak

```sh
.build/energy/companion-energy --native 10800 > .build/energy/native-three-hours.csv
python3 tools/EnergyProfile/summarize.py --warm-up 600 .build/energy/native-three-hours.csv

.build/energy/companion-energy --workload 21600 --rate 30 > .build/energy/workload-six-hours.csv
.build/energy/companion-energy --workload 21600 --low-power > .build/energy/workload-low-power-six-hours.csv
python3 tools/EnergyProfile/summarize.py --warm-up 5 .build/energy/workload-six-hours.csv .build/energy/workload-low-power-six-hours.csv
```

`--native` measures elapsed wall time with a continuous monotonic clock, a real
panel and display link. Machine sleep counts toward that duration. Display
sleep and machine sleep may interrupt drawing; verify both simulation time and
draw counts before describing a run as continuous idle rendering. The isolated
session does not exercise `DesktopEnvironment` lifecycle/input observations.

`--workload` advances the requested simulated duration as fast as possible while
rendering every frame on one reused 2x panel-sized bitmap. Each frame drains an
autorelease pool. This catches retained rendering/simulation resources over hours
of frame workload without encoding PNGs. It is an accelerated stress test, not
hours of native elapsed time or a battery/power measurement. Use footprint and
live-heap medians/trends after warm-up; RSS alone can change with memory pressure.
Small bounded cache changes are expected. A sustained upward trend needs a
longer run and retained-allocation inspection before claiming steady memory.

After renderer changes, repeat the baseline workload, native run and preview.
Compare decoded pixels or PNG bytes across the whole preview sequence, and run
`./scripts/test.sh`, both app build configurations and the public-file check.
Store machine-specific findings locally; do not turn a single device result into
a general energy guarantee.

## Complete controls profile

```sh
./scripts/profile-energy.sh --native 180 --controls > .build/energy/controls.csv
```

This finite run uses the complete production app delegate, runtime, environment, clock, menu bar, Settings and character with disposable preferences. Its six 30-second phases are idle, Settings open, paused, hidden, recovered, and 20 repeated Settings open/close and pause/hide/recover cycles. It restores the previous app after shutdown and removes its preferences. Login registration is read but never changed. Expect Settings to request activation during its explicit phase; use a quiet desktop and avoid other interactions during measurement. Keep actual system Reduce Motion and Low Power settings in the recorded device conditions. `--controls` cannot be combined with forced `--low-power` or `--rate`.

CSV still distinguishes clock callbacks from actual character draws. Paused and hidden phases should have zero ongoing callbacks/draws after their transition frame. Inspect those rows directly: `summarize.py` deliberately excludes intervals without draws, so its overall CPU summary does not describe suspension. Compare idle, Settings and recovered phase intervals, and the retained footprint/heap after repeated controls. This short native check is neither sustained battery acceptance nor cumulative allocation-churn evidence. Store results separately from notification-injection regressions and physical acceptance.
