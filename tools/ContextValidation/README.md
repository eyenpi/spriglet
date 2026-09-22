# Context and input-idle validation

Run `./tools/ContextValidation/run.sh` on macOS 26 or later with full Xcode
selected. The tool compiles the production environment boundaries in a signed,
sandboxed native app and prints only generic event names and scalar read counts.
It never prints an application name, bundle identifier, title, input location,
or input-idle duration.

It verifies that:

- input inactivity is read once only on an explicit refresh while the source is
  running, and never through a polling loop or input subscription;
- the pure policy separates recent user input, ordinary idle time, and a
  configurable nap threshold, with a single next-boundary deadline;
- repeated foreground-application activation messages produce one generic
  `appChanged` fact, coalesced with generic Space and display facts through the
  shared `DeadlineScheduler.contextRefresh` slot;
- stopping removes the typed activation observer, cancels its deadline, and
  clears the private identity used only for deduplication;
- isolated typed workspace notifications from the existing lifecycle source
  independently map Space, display wake, and session activation to generic
  context facts for the deferred environment-source patch;
- the context coordinator stops every demand source and its one idle deadline
  when paused or hidden; it emits one semantic nap decision at a true aggregate
  idle boundary, gates app glances by cooldown, and allows a sleep-only movement
  wake even when Automatic Moments is off;
- the injected sleep-wake source stops before its single generic movement signal
  asks the aggregate input-idle source whether a wake is appropriate. A stale
  aggregate value rearms one later one-shot movement observation without a
  timer or polling loop, and Automatic Moments toggles do not disable waking.
  No fake ever reads or carries a pointer coordinate;
- replaced or canceled input-idle deadline closures are rejected by a monotonic
  coordinator revision even if a hostile scheduler delivers them late.

The checker uses private `NotificationCenter` instances and posts only to those
instances. It does not post any event to macOS, change settings, install event
taps, or simulate physical keyboard/mouse activity. Physical local/global wake
monitor delivery, hardware wake, and unlock delivery remain human verification
because the operating system controls them.

The production input query is
[`CGEventSource.secondsSinceLastEventType`](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype%28_%3Aeventtype%3A%29)
with [`.combinedSessionState`](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid/combinedsessionstate)
and `kCGAnyInputEventType`, which Apple defines as aggregate keyboard, mouse,
and tablet input inactivity. Typed activation and workspace lifecycle messages
are documented in [Notification center messages](https://developer.apple.com/documentation/foundation/notification-center-messages)
and [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace).
