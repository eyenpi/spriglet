import AppKit
import CoreGraphics
import Foundation
import SprigletCore

/// Rebuilds value-only habitat topology from the current AppKit screens. It
/// holds no screen, window, observer, or timer, so changing Dock, menu-bar, or
/// display geometry is picked up only when the host explicitly reconciles.
@MainActor
struct ScreenHabitatProvider {
    let artGeometry: HabitatPortalArtGeometry

    init(artGeometry: HabitatPortalArtGeometry = .acornStandard) {
        self.artGeometry = artGeometry
    }

    /// Uses a fresh `NSScreen.screens` snapshot. Stable CoreGraphics UUIDs,
    /// rather than a screen-array index or localized name, identify displays.
    func currentTopology() -> HabitatTopology? {
        topology(from: NSScreen.screens)
    }

    /// Injection seam for an explicit current screen snapshot. It does not
    /// retain the AppKit objects after this call returns.
    func topology(from screens: [NSScreen]) -> HabitatTopology? {
        let mainDisplayID = NSScreen.main?.cgDirectDisplayID
        let displays = screens.compactMap { screen in
            snapshot(for: screen, isMain: screen.cgDirectDisplayID == mainDisplayID)
        }
        return HabitatTopology(displays: displays, artGeometry: artGeometry)
    }

    private func snapshot(for screen: NSScreen, isMain: Bool) -> HabitatScreenSnapshot? {
        guard let displayID = stableDisplayUUID(for: screen),
              let safeInsets = HabitatInsets(
                top: screen.safeAreaInsets.top,
                left: screen.safeAreaInsets.left,
                bottom: screen.safeAreaInsets.bottom,
                right: screen.safeAreaInsets.right
              )
        else { return nil }
        return HabitatScreenSnapshot(
            displayID: displayID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: safeInsets,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            backingScale: screen.backingScaleFactor,
            isMain: isMain
        )
    }

    private func stableDisplayUUID(for screen: NSScreen) -> UUID? {
        guard let displayID = screen.cgDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)
    }
}
