import AppKit
import Foundation
import SprigletCore

@main
@MainActor
struct GeometryCheck {
    static func main() {
        do {
            NSApplication.shared.setActivationPolicy(.accessory)
            let report = try audit()
            let data = try JSONEncoder().encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Geometry validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func audit() throws -> GeometryAuditReport {
        let screens = NSScreen.screens
        let provider = ScreenHabitatProvider()
        let topology = try require(provider.topology(from: screens), "Current screens did not produce a stable geometry topology")
        try require(topology.displays.count == screens.count,
                    "Each current display must expose a stable UUID before it becomes selectable geometry")

        let raw = try screens.map(rawSnapshot)
        let valuesMatch = zip(raw, topology.displays).allSatisfy { source, value in
            source.frame == value.frame
                && source.visibleFrame == value.visibleFrame
                && source.safeInsets == value.safeAreaInsets
                && source.leftAuxiliary == value.auxiliaryTopLeftArea
                && source.rightAuxiliary == value.auxiliaryTopRightArea
                && source.backingScale == value.backingScale
        }
        try require(valuesMatch, "The provider must retain AppKit safe-area geometry exactly as values")

        let topBoundsStayVisible = topology.surfaces
            .filter { [.topShelf, .notchLeft, .notchRight].contains($0.id.kind) }
            .allSatisfy { surface in
                guard let display = topology.displays.first(where: { $0.displayID == surface.id.displayID }) else { return false }
                return surface.safeVisualBounds.maxY <= display.visibleFrame.maxY
                    && surface.safeVisualBounds.minY >= display.visibleFrame.minY
            }
        try require(topBoundsStayVisible, "A portal window must remain below the current visible-frame top")

        var counts: [String: Int] = [:]
        for surface in topology.surfaces {
            counts[surface.id.kind.rawValue, default: 0] += 1
        }
        return GeometryAuditReport(
            sourceScreenCount: screens.count,
            geometryDisplayCount: topology.displays.count,
            safeAreaGeometryMatches: valuesMatch,
            topPortalBoundsStayVisible: topBoundsStayVisible,
            surfaceCounts: counts,
            displayIdentifiersEmitted: false,
            safeAreaCompatibilityModeChanged: false
        )
    }

    private static func rawSnapshot(_ screen: NSScreen) throws -> RawScreenGeometry {
        let insets = try require(HabitatInsets(
            top: screen.safeAreaInsets.top,
            left: screen.safeAreaInsets.left,
            bottom: screen.safeAreaInsets.bottom,
            right: screen.safeAreaInsets.right
        ), "Current safe-area insets are malformed")
        return RawScreenGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeInsets: insets,
            leftAuxiliary: screen.auxiliaryTopLeftArea,
            rightAuxiliary: screen.auxiliaryTopRightArea,
            backingScale: screen.backingScaleFactor
        )
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw GeometryValidationFailure(message) }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw GeometryValidationFailure(message) }
    }
}

private struct RawScreenGeometry {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeInsets: HabitatInsets
    let leftAuxiliary: CGRect?
    let rightAuxiliary: CGRect?
    let backingScale: CGFloat
}

private struct GeometryAuditReport: Encodable {
    let sourceScreenCount: Int
    let geometryDisplayCount: Int
    let safeAreaGeometryMatches: Bool
    let topPortalBoundsStayVisible: Bool
    let surfaceCounts: [String: Int]
    let displayIdentifiersEmitted: Bool
    let safeAreaCompatibilityModeChanged: Bool
}

private struct GeometryValidationFailure: LocalizedError {
    let errorDescription: String?
    init(_ errorDescription: String) { self.errorDescription = errorDescription }
}
