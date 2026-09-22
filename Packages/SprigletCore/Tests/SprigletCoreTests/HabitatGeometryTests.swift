import CoreGraphics
import Foundation
import Testing
@testable import SprigletCore

@Suite("Habitat geometry")
struct HabitatGeometryTests {
    private let primaryID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000501")!
    private let secondaryID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000502")!

    @Test("Non-notched screens produce floor, floating top shelf, and disabled walls")
    func basicSurfaces() throws {
        let display = try #require(snapshot())
        let topology = try #require(HabitatTopology(displays: [display]))
        let floor = try #require(surface(.floor, in: topology))
        let shelf = try #require(surface(.topShelf, in: topology))
        let wall = try #require(surface(.wallLeft, in: topology))

        #expect(floor.interval.axis == .horizontal)
        #expect(floor.interval.fixedCoordinate == display.visibleFrame.minY)
        #expect(floor.normal == .up)
        #expect(shelf.normal == .down)
        #expect(shelf.safeVisualBounds.maxY == display.visibleFrame.maxY)
        #expect(shelf.safeVisualBounds.minY == display.visibleFrame.maxY - 96)
        #expect(shelf.interval.start == display.visibleFrame.midX - 48)
        #expect(shelf.interval.end == display.visibleFrame.midX + 48)
        #expect(display.dockAndMenuInsets.top == 30)
        #expect(!shelf.isSelectable(using: []))
        #expect(shelf.isSelectable(using: [.ledgePortalTraversal]))
        #expect(!wall.isSelectable(using: [.wallTraversal]))
        #expect(wall.capabilityRequirements.allOf == [.wallTraversal])
    }

    @Test("Notch shelves use auxiliary areas and the complete portal window remains below the strip")
    func notchSurfaces() throws {
        let frame = CGRect(x: -1_500, y: -200, width: 1_500, height: 1_000)
        let visible = CGRect(x: -1_500, y: -200, width: 1_500, height: 970)
        let left = CGRect(x: -1_500, y: 770, width: 620, height: 30)
        let right = CGRect(x: -620, y: 770, width: 620, height: 30)
        let display = try #require(snapshot(
            frame: frame, visible: visible, left: left, right: right
        ))
        let topology = try #require(HabitatTopology(displays: [display]))
        let leftShelf = try #require(surface(.notchLeft, in: topology))
        let rightShelf = try #require(surface(.notchRight, in: topology))

        #expect(surface(.topShelf, in: topology) == nil)
        #expect(leftShelf.interval.start == left.minX)
        #expect(leftShelf.interval.end == left.maxX)
        #expect(rightShelf.interval.start == right.minX)
        #expect(rightShelf.interval.end == right.maxX)
        #expect(leftShelf.safeVisualBounds.maxY == visible.maxY)
        #expect(rightShelf.safeVisualBounds.maxY == visible.maxY)
    }

    @Test("Art geometry scales at 72, 96, and 120 points while preserving head clearance")
    func artContractScales() throws {
        for scale in [CGFloat(0.75), 1, 1.25] {
            let contract = try #require(HabitatPortalArtGeometry.acorn(scale: scale))
            #expect(contract.portalWindowSize == CGSize(width: 96 * scale, height: 96 * scale))
            #expect(contract.gripOffsetFromWindowTop >= contract.requiredHeadClearance)
            #expect(contract.requiredHeadClearance == 46 * scale)
        }
        #expect(HabitatPortalArtGeometry.acorn(scale: 0) == nil)
    }

    @Test("A short visible frame keeps floor geometry but disables a portal candidate that cannot fit")
    func shortFrameOmitsPortal() throws {
        let display = try #require(snapshot(visible: CGRect(x: 0, y: 0, width: 800, height: 95)))
        let topology = try #require(HabitatTopology(displays: [display]))
        #expect(surface(.floor, in: topology) != nil)
        #expect(surface(.topShelf, in: topology) == nil)
        #expect(surface(.notchLeft, in: topology) == nil)
    }

    @Test("Negative origins, mixed scales, and disjoint nonrectangular layouts remain valid")
    func disjointTopology() throws {
        let primary = try #require(snapshot(
            frame: CGRect(x: -1_920, y: -980, width: 1_920, height: 1_080),
            visible: CGRect(x: -1_920, y: -980, width: 1_920, height: 1_040),
            backingScale: 2,
            isMain: true
        ))
        let secondary = try #require(snapshot(
            id: secondaryID,
            frame: CGRect(x: 0, y: 300, width: 1_280, height: 720),
            visible: CGRect(x: 0, y: 300, width: 1_280, height: 700),
            backingScale: 1
        ))
        let topology = try #require(HabitatTopology(displays: [primary, secondary]))
        #expect(topology.displays.map(\.displayID) == [primaryID, secondaryID])
        #expect(topology.surfaces.filter { $0.id.kind == .floor }.count == 2)
        #expect(topology.surfaces.filter { $0.availability == .selectable }.count > 0)
    }

    @Test("Duplicate UUIDs fail, while mirrored overlaps retain main-display geometry and block the duplicate")
    func duplicateAndMirroredTopology() throws {
        let main = try #require(snapshot(isMain: true))
        let duplicate = try #require(snapshot())
        #expect(HabitatTopology(displays: [main, duplicate]) == nil)

        let mirror = try #require(snapshot(id: secondaryID, isMain: false))
        let mirrored = try #require(HabitatTopology(displays: [main, mirror]))
        let mainFloor = try #require(mirrored.surfaces.first { $0.id == .init(displayID: primaryID, kind: .floor) })
        let mirrorFloor = try #require(mirrored.surfaces.first { $0.id == .init(displayID: secondaryID, kind: .floor) })
        #expect(mainFloor.availability == .selectable)
        #expect(mirrorFloor.availability == .unselectableOverlappingDisplay)
    }

    @Test("Partial overlaps remain in the snapshot but are conservatively unselectable")
    func partialOverlap() throws {
        let primary = try #require(snapshot(isMain: true))
        let overlapping = try #require(snapshot(
            id: secondaryID,
            frame: CGRect(x: 400, y: 0, width: 1_000, height: 900),
            visible: CGRect(x: 400, y: 0, width: 1_000, height: 850)
        ))
        let topology = try #require(HabitatTopology(displays: [primary, overlapping]))
        #expect(topology.surfaces.allSatisfy { $0.availability == .unselectableOverlappingDisplay })
    }

    @Test("Only explicit fully hidden zero-root portal pairs can relocate between habitats")
    func portalRelocation() throws {
        let topology = try #require(HabitatTopology(displays: [snapshot()!]))
        let floor = HabitatSurfaceIdentifier(displayID: primaryID, kind: .floor)
        let shelf = HabitatSurfaceIdentifier(displayID: primaryID, kind: .topShelf)
        #expect(topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: shelf, entryPortalID: "topShelf.entry"
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.entry", to: shelf, entryPortalID: "topShelf.entry"
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: shelf, entryPortalID: "missing"
        ))
        #expect(HabitatPortal(
            id: "bad", direction: .exit, localRootTranslation: CGPoint(x: 1, y: 0),
            connectedSurfaceKinds: [.floor]
        ) == nil)
    }

    @Test("Malformed screen input fails closed")
    func invalidInput() {
        let insets = HabitatInsets(top: 20, left: 0, bottom: 0, right: 0)!
        #expect(HabitatScreenSnapshot(
            displayID: primaryID,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 801, height: 600),
            safeAreaInsets: insets,
            backingScale: 2
        ) == nil)
        #expect(HabitatScreenSnapshot(
            displayID: primaryID,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 580),
            safeAreaInsets: insets,
            auxiliaryTopLeftArea: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            backingScale: 2
        ) == nil)
    }

    private func snapshot(
        id: UUID? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1_440, height: 900),
        visible: CGRect = CGRect(x: 0, y: 0, width: 1_440, height: 870),
        left: CGRect? = nil,
        right: CGRect? = nil,
        backingScale: CGFloat = 2,
        isMain: Bool = false
    ) -> HabitatScreenSnapshot? {
        HabitatScreenSnapshot(
            displayID: id ?? primaryID,
            frame: frame,
            visibleFrame: visible,
            safeAreaInsets: HabitatInsets(top: 30, left: 0, bottom: 0, right: 0)!,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right,
            backingScale: backingScale,
            isMain: isMain
        )
    }

    private func surface(_ kind: HabitatSurfaceKind, in topology: HabitatTopology) -> HabitatSurface? {
        topology.surfaces.first { $0.id.displayID == primaryID && $0.id.kind == kind }
    }
}
