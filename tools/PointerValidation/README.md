# Pointer-source validation

Run `./tools/PointerValidation/run.sh` on macOS 26 or later with full Xcode selected.

For physical acceptance, run `./tools/PointerValidation/run.sh --live`. A
nonactivating 420×180 panel remains visible for 30 seconds while AppKit's real
run loop is active. Drag that panel to exercise the local monitor, then drag a
window from another app to exercise the global monitor. The panel and final
JSON show separate local/global counts and never display or record coordinates.

The tool builds an ad-hoc signed sandbox app. It uses a production-shaped
`AppKitPointerSource` for one bounded observation window, then reports only
event and delivery counts. It never prints, stores, or writes pointer
coordinates, and it never creates or posts an input event.

The report compares two intentionally separate paths:

- a synthetic high-rate event feed through the production latest-value
  coalescer at 15 Hz; and
- a harness-only ten-read, 10 Hz `NSEvent.mouseLocation` sampler.

The production source has no sampler or permanent timer. It registers only
`mouseMoved`, `leftMouseDragged`, `rightMouseDragged`, and `otherMouseDragged`
with local and global monitors. The source keeps at most one point while a
single cancellable one-shot delivery is pending; stop removes both monitors,
cancels that wake, and clears the point.

`PetAwarenessCoordinator` is an injected lifecycle seam above this source. It
starts observation only while the companion is awake, visible, unpaused,
unconstrained, not directly interacted with, and not suspended. A pet-bounds
change clears the retained pointer perception before a new sample arrives, so
moving the companion cannot create a false approach. Suspension, hiding,
pausing, sleeping, direct interaction, and teardown stop the source, cancel the
pointer deadlines, and clear the retained sample. Workspace lifecycle
observation remains active separately so a wake can enable pointer work later.

Stationary dwell and departure holds use `DeadlineScheduler`: one shared,
cancellable earliest one-shot task serves semantic slots for autonomous
behavior, pointer dwell/departure, context refresh, and future user-idle work.
There is no second timer or polling loop. The coordinator emits an in-process
update containing one ephemeral perception sample and a coordinate-free
attention state; it never reaches a renderer directly and does not log either.
When deadlines become due together, context and user-idle work run before
autonomous behavior; cancellation from an earlier callback prevents the later
callback from running. Repeated source starts preserve lifetime diagnostic
counts so a pause/resume inside a measurement cannot make a count delta wrap.

The physical-monitor fields are evidence only. A report of
`"hardware-movement-needed"` means no physical mouse or trackpad event reached
the signed sandbox process during the one-second window. It is not evidence that
monitor delivery works; repeat the tool while moving a pointer over another app
and while interacting with Spriglet before promoting this source to production.

The native check also uses an injected fake pointer source, monotonic clock, and
deadline scheduler to verify source gating, stationary dwell maturation,
departure reset, bounds-change history clearing, and deadline replacement/
cancellation, and the full coordinator → world → intent → production-renderer
path without posting system input.

Apple documents [screen-coordinate mouse location](https://developer.apple.com/documentation/appkit/nsevent/mouselocation), [global event monitors](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29), [local event monitors](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents%28matching%3Ahandler%3A%29), and [system uptime](https://developer.apple.com/documentation/foundation/processinfo/systemuptime). The architecture rationale is summarized in the [SprigletCore README](../../Packages/SprigletCore/README.md).
