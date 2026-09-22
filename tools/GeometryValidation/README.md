# Geometry validation

Run `./tools/GeometryValidation/run.sh` on macOS 26 or later with full Xcode
selected. The signed native checker reads the current `NSScreen` values once,
builds a fresh `ScreenHabitatProvider` topology, and verifies that the value
snapshot exactly preserves `frame`, `visibleFrame`, safe-area insets, auxiliary
top areas, and backing scale. Its JSON report omits display names and UUIDs.

It also verifies that each generated top portal window ends at or below
`visibleFrame.maxY`. It never creates a pet window, polls screen state, changes
Dock or menu-bar settings, posts a system notification, or changes
`NSPrefersDisplaySafeAreaCompatibilityMode`. Physical notch and auto-hiding
menu-bar behavior still need a human audit on the relevant hardware.

Apple documents [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe),
[`safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets),
and [`auxiliaryTopLeftArea`](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc).
The installed macOS 27 SDK exposes those properties, `backingScaleFactor`, and
the current `cgDirectDisplayID`; the provider turns the CoreGraphics display ID
into a stable UUID without exposing either identifier in this audit output.
