# Geometry validation

Run `./tools/GeometryValidation/run.sh` on macOS 26 or later with full Xcode
selected. The signed native checker reads the current `NSScreen` values once,
builds a fresh `ScreenHabitatProvider` topology, and verifies that the value
snapshot exactly preserves `frame`, `visibleFrame`, safe-area insets, auxiliary
top areas, backing scale, and the derived intersection of the safe area and
`visibleFrame`. Its JSON report omits display names and UUIDs.

It also verifies that each generated top portal window ends at or below
the current safe-visible ceiling and that ordinary ledge capabilities cannot
select a wall route. The report includes anonymized, array-indexed frame,
safe-visible frame, reserved insets, backing scale, notch classification, and
habitat kinds for each current display. `currentDeviceCoverage` says exactly
whether this run establishes notched, ordinary, multi-display, and mixed-scale
coverage.

The checker never creates a pet window, polls screen state, changes Dock or
menu-bar settings, posts a system notification, or changes
`NSPrefersDisplaySafeAreaCompatibilityMode`. Physical notch and auto-hiding
menu-bar behavior still need a human audit on the relevant hardware; use the
matrix workflow in `tools/HabitatValidation/README.md` to record that evidence.

Apple documents [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe),
[`safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets),
and [`auxiliaryTopLeftArea`](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc).
The installed macOS 27 SDK exposes those properties, `backingScaleFactor`, and
the current `cgDirectDisplayID`; the provider turns the CoreGraphics display ID
into a stable UUID without exposing either identifier in this audit output.
