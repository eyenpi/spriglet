# Environment lifecycle validation

Run `./tools/EnvironmentValidation/run.sh` on macOS 26 or later with full Xcode selected.

The checker compiles the production `AppKitEnvironmentSource` with strict Swift
6 concurrency and exercises its lifecycle without starting Spriglet or changing
any user setting. It verifies that:

- repeated `start()` calls retain a single typed observer;
- `NSWorkspace` synchronous and asynchronous typed messages reach the source;
- a typed ProcessInfo power message produces a current immutable policy snapshot;
- `stop()` prevents both synchronous callbacks and queued asynchronous callbacks;
- a later `start()` accepts only the current lifecycle generation.

The tool injects two private `NotificationCenter` instances. It posts messages
only to those centers, never to `NSWorkspace.shared.notificationCenter` or
`NotificationCenter.default`; no system lifecycle, display, session, thermal, or
power state is changed.

The production default still uses `NSWorkspace.shared.notificationCenter`, as
Apple requires for workspace wake notifications. Apple documents the typed
message lifecycle in [Notification center messages](https://developer.apple.com/documentation/foundation/notification-center-messages), the required workspace notification center for [wake notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification), and the current [Low Power Mode](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled), [thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property), and [Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion) APIs.
