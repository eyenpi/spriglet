# Native personality integration check

This disposable app uses the production runtime, desktop host, actual Sprout sample, and native display link. The only injected values are short planned-behavior deadlines/intentions and Low Power/Reduce Motion policy booleans, through runtime hooks compiled exclusively with `SPRIGLET_BEHAVIOR_VALIDATION`.

Build only, from the repository root:

```sh
bash tools/PersonalityValidation/build.sh
```

After source review, run it explicitly:

```sh
tools/PersonalityValidation/.build/PersonalityValidation.app/Contents/MacOS/PersonalityCheck \
  --output .build/personality-validation.json
```

Running displays one small nonactivating pet panel with Pass Clicks Through enabled, for approximately two minutes. Keep its display and Space available. The app never sends input, reads another app's contents, changes system settings, or sleeps the Mac. Quit/cancellation records an incomplete outcome and removes its temporary preferences domain. Individual waits are bounded to at most 15 seconds; ordinary phases use shorter asynchronous polling that observes playback without advancing it.

The check covers both directions of Explore and Firefly, stationary parked firefly play, fractional return placement and unchanged saved home, paired image/root samples, the twelve-frame decode buffer, finite completion versus cancellation, deadlines replaced or cancelled by runtime settings, Low Power and Reduce Motion branches, short settled intervals, isolated profile/memory persistence, and cancellation of the ordinary runtime diagnostic with subsequent-save isolation.

The build script compiles a private snapshot of each source file and copies the assets into its bundle. Build provenance records their SHA-256 hashes and toolchain information. The runtime report hashes the actual executable and every bundled sample file. It reports scalar observations and equality results without including the pet's name or serialized profile. Only the UUID test defaults domain is written, and it is removed before the report finishes.

Exit status is `0` for passed, `1` for a check/report/cleanup failure, and `2` when an unavailable desktop policy or cancellation prevents completion. Reported buffer maxima are observed samples, not an allocation high-water mark. The harness does not prove physical focus/click routing, GPU presentation, visual quality, full-screen/Spaces behavior, hardware reconnect, actual OS notification delivery, real sleep/wake, battery cost, or a long resource soak. Full probe completion and launch-time review-flag preference isolation remain separate checks.
