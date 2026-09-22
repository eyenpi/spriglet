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
                && source.safeVisibleFrame == value.safeVisibleFrame
                && source.leftAuxiliary == value.auxiliaryTopLeftArea
                && source.rightAuxiliary == value.auxiliaryTopRightArea
                && source.backingScale == value.backingScale
        }
        try require(valuesMatch, "The provider must retain AppKit safe-area geometry exactly as values")

        let topBoundsStayVisible = topology.surfaces
            .filter { [.topShelf, .notchLeft, .notchRight].contains($0.id.kind) }
            .allSatisfy { surface in
                guard let display = topology.displays.first(where: { $0.displayID == surface.id.displayID }) else { return false }
                return display.safeVisibleFrame.contains(surface.safeVisualBounds)
            }
        try require(topBoundsStayVisible, "A portal window must remain inside the current safe visible frame")

        let ledgeCapabilitiesCannotSelectWalls = topology.displays.allSatisfy { display in
            let floorID = HabitatSurfaceIdentifier(displayID: display.displayID, kind: .floor)
            return topology.surfaces
                .filter { $0.id.displayID == display.displayID && [.wallLeft, .wallRight].contains($0.id.kind) }
                .allSatisfy { wall in
                    !wall.isSelectable(using: [.ledgePortalTraversal])
                        && !topology.permitsInterHabitatRelocation(
                            from: floorID,
                            exitPortalID: "floor.exit",
                            to: wall.id,
                            entryPortalID: "\(wall.id.kind.rawValue).entry",
                            using: [.ledgePortalTraversal]
                        )
                }
        }
        try require(ledgeCapabilitiesCannotSelectWalls,
                    "Ordinary ledge capabilities must not activate wall routes")

        var counts: [String: Int] = [:]
        for surface in topology.surfaces {
            counts[surface.id.kind.rawValue, default: 0] += 1
        }
        let displays = zip(screens.indices, zip(screens, topology.displays)).map { index, pair in
            let (screen, display) = pair
            let kinds = topology.surfaces
                .filter { $0.id.displayID == display.displayID }
                .map(\.id.kind.rawValue)
                .sorted()
            let classification = switch (
                display.auxiliaryTopLeftArea,
                display.auxiliaryTopRightArea
            ) {
            case (_?, _?): "notched"
            case (nil, nil): "ordinary"
            default: "indeterminate"
            }
            return DisplayAudit(
                index: index,
                isMain: display.isMain,
                frame: RectAudit(screen.frame),
                visibleFrame: RectAudit(screen.visibleFrame),
                safeVisibleFrame: RectAudit(display.safeVisibleFrame),
                safeAreaInsets: InsetsAudit(display.safeAreaInsets),
                inferredReservedInsets: InsetsAudit(display.dockAndMenuInsets),
                backingScale: display.backingScale,
                classification: classification,
                habitatKinds: kinds
            )
        }
        let classifications = Set(displays.map(\.classification))
        let scales = Set(displays.map(\.backingScale))
        return GeometryAuditReport(
            sourceScreenCount: screens.count,
            geometryDisplayCount: topology.displays.count,
            safeAreaGeometryMatches: valuesMatch,
            topPortalBoundsStayVisible: topBoundsStayVisible,
            ledgeCapabilitiesCannotSelectWalls: ledgeCapabilitiesCannotSelectWalls,
            surfaceCounts: counts,
            displays: displays,
            currentDeviceCoverage: CurrentDeviceCoverage(
                hasNotchedDisplay: classifications.contains("notched"),
                hasOrdinaryDisplay: classifications.contains("ordinary"),
                hasMultipleDisplays: displays.count > 1,
                hasMixedBackingScale: scales.count > 1
            ),
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
            safeVisibleFrame: try require(HabitatScreenSnapshot.deriveSafeVisibleFrame(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                safeAreaInsets: insets
            ), "Current safe visible frame is empty"),
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
    let safeVisibleFrame: CGRect
    let leftAuxiliary: CGRect?
    let rightAuxiliary: CGRect?
    let backingScale: CGFloat
}

private struct GeometryAuditReport: Encodable {
    let sourceScreenCount: Int
    let geometryDisplayCount: Int
    let safeAreaGeometryMatches: Bool
    let topPortalBoundsStayVisible: Bool
    let ledgeCapabilitiesCannotSelectWalls: Bool
    let surfaceCounts: [String: Int]
    let displays: [DisplayAudit]
    let currentDeviceCoverage: CurrentDeviceCoverage
    let displayIdentifiersEmitted: Bool
    let safeAreaCompatibilityModeChanged: Bool
}

private struct DisplayAudit: Encodable {
    let index: Int
    let isMain: Bool
    let frame: RectAudit
    let visibleFrame: RectAudit
    let safeVisibleFrame: RectAudit
    let safeAreaInsets: InsetsAudit
    let inferredReservedInsets: InsetsAudit
    let backingScale: CGFloat
    let classification: String
    let habitatKinds: [String]
}

private struct CurrentDeviceCoverage: Encodable {
    let hasNotchedDisplay: Bool
    let hasOrdinaryDisplay: Bool
    let hasMultipleDisplays: Bool
    let hasMixedBackingScale: Bool
}

private struct RectAudit: Encodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }
}

private struct InsetsAudit: Encodable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    init(_ insets: HabitatInsets) {
        top = insets.top
        left = insets.left
        bottom = insets.bottom
        right = insets.right
    }
}

private struct GeometryValidationFailure: LocalizedError {
    let errorDescription: String?
    init(_ errorDescription: String) { self.errorDescription = errorDescription }
}
