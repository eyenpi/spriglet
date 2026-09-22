import CoreGraphics
import Foundation
import Testing
@testable import SprigletCore

@Suite("Habitat geometry")
struct HabitatGeometryTests {
    private let primaryID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000501")!
    private let secondaryID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000502")!

    @Test("Non-notched screens produce capability-gated surfaces inside the safe visible frame")
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
        #expect(!wall.isSelectable(using: [.ledgePortalTraversal]))
        #expect(wall.isSelectable(using: [.wallTraversal]))
        #expect(wall.normal == .right)
        #expect(wall.safeVisualBounds == CGRect(x: 0, y: 0, width: 96, height: 870))
        #expect(wall.capabilityRequirements.allOf == [.wallTraversal])
        #expect(wall.entryPortals.map(\.id) == ["wallLeft.entry"])
        #expect(wall.exitPortals.map(\.id) == ["wallLeft.exit"])
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

    @Test("A visible frame shorter or narrower than the portal keeps only safe floor geometry")
    func undersizedFrameOmitsPortal() throws {
        for visible in [
            CGRect(x: 0, y: 0, width: 800, height: 95),
            CGRect(x: 0, y: 0, width: 95, height: 800)
        ] {
            let display = try #require(snapshot(frame: visible, visible: visible))
            let topology = try #require(HabitatTopology(displays: [display]))
            #expect(surface(.floor, in: topology) != nil)
            #expect(surface(.topShelf, in: topology) == nil)
            #expect(surface(.notchLeft, in: topology) == nil)
            #expect(surface(.wallLeft, in: topology) == nil)
        }
    }

    @Test("Every Dock edge and an auto-hidden menu bar use the intersected safe visible frame")
    func dockAndAutoHideGeometry() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let cases: [(visible: CGRect, expected: CGRect)] = [
            (
                CGRect(x: 0, y: 80, width: 1_440, height: 790),
                CGRect(x: 0, y: 80, width: 1_440, height: 790)
            ),
            (
                CGRect(x: 100, y: 0, width: 1_340, height: 870),
                CGRect(x: 100, y: 0, width: 1_340, height: 870)
            ),
            (
                CGRect(x: 0, y: 0, width: 1_340, height: 870),
                CGRect(x: 0, y: 0, width: 1_340, height: 870)
            ),
            // Auto-hidden menu bar: visibleFrame expands, while safeAreaInsets
            // continue to protect the camera/menu strip.
            (frame, CGRect(x: 0, y: 0, width: 1_440, height: 870))
        ]

        for (visible, expected) in cases {
            let display = try #require(snapshot(frame: frame, visible: visible))
            let topology = try #require(HabitatTopology(displays: [display]))
            let floor = try #require(surface(.floor, in: topology))
            let shelf = try #require(surface(.topShelf, in: topology))
            let leftWall = try #require(surface(.wallLeft, in: topology))
            let rightWall = try #require(surface(.wallRight, in: topology))

            #expect(display.safeVisibleFrame == expected)
            #expect(floor.interval.fixedCoordinate == expected.minY)
            #expect(floor.interval.start == expected.minX)
            #expect(floor.interval.end == expected.maxX)
            #expect(shelf.interval.fixedCoordinate == expected.maxY)
            #expect(shelf.safeVisualBounds.maxY == expected.maxY)
            #expect(leftWall.interval.fixedCoordinate == expected.minX)
            #expect(rightWall.interval.fixedCoordinate == expected.maxX)
            #expect(expected.contains(leftWall.safeVisualBounds))
            #expect(expected.contains(rightWall.safeVisualBounds))
        }
    }

    @Test("Safe-area insets constrain every edge independently of visible-frame insets")
    func safeAreaIntersection() throws {
        let frame = CGRect(x: -100, y: 50, width: 1_000, height: 700)
        let insets = try #require(HabitatInsets(top: 30, left: 12, bottom: 10, right: 18))
        let display = try #require(snapshot(
            frame: frame,
            visible: frame,
            safeInsets: insets
        ))
        let expected = CGRect(x: -88, y: 60, width: 970, height: 660)
        let topology = try #require(HabitatTopology(displays: [display]))

        #expect(display.safeVisibleFrame == expected)
        #expect(HabitatScreenSnapshot.deriveSafeVisibleFrame(
            frame: frame,
            visibleFrame: frame,
            safeAreaInsets: insets
        ) == expected)
        #expect(surface(.floor, in: topology)?.interval.fixedCoordinate == expected.minY)
        #expect(surface(.wallLeft, in: topology)?.interval.fixedCoordinate == expected.minX)
        #expect(surface(.wallRight, in: topology)?.interval.fixedCoordinate == expected.maxX)
        #expect(surface(.topShelf, in: topology)?.interval.fixedCoordinate == expected.maxY)
        #expect(topology.surfaces.allSatisfy { expected.contains($0.safeVisualBounds) })
    }

    @Test("Incomplete or contradictory notch geometry exposes no top portal")
    func malformedNotchGeometry() throws {
        let left = CGRect(x: 0, y: 870, width: 600, height: 30)
        let oneSided = try #require(snapshot(left: left))
        let oneSidedTopology = try #require(HabitatTopology(displays: [oneSided]))
        #expect(surface(.topShelf, in: oneSidedTopology) == nil)
        #expect(surface(.notchLeft, in: oneSidedTopology) == nil)
        #expect(surface(.notchRight, in: oneSidedTopology) == nil)

        let rightOverlapping = CGRect(x: 500, y: 870, width: 940, height: 30)
        let overlapping = try #require(snapshot(left: left, right: rightOverlapping))
        let overlappingTopology = try #require(HabitatTopology(displays: [overlapping]))
        #expect(surface(.topShelf, in: overlappingTopology) == nil)
        #expect(surface(.notchLeft, in: overlappingTopology) == nil)
        #expect(surface(.notchRight, in: overlappingTopology) == nil)
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
        #expect(!topology.permitsInterHabitatRelocation(
            from: .init(displayID: primaryID, kind: .floor),
            exitPortalID: "floor.exit",
            to: .init(displayID: primaryID, kind: .topShelf),
            entryPortalID: "topShelf.entry",
            using: [.ledgePortalTraversal]
        ))
    }

    @Test("Portals never infer a connection between displays")
    func crossDisplayPortal() throws {
        let primary = try #require(snapshot(isMain: true))
        let secondary = try #require(snapshot(
            id: secondaryID,
            frame: CGRect(x: 1_440, y: 200, width: 1_280, height: 720),
            visible: CGRect(x: 1_440, y: 200, width: 1_280, height: 690)
        ))
        let topology = try #require(HabitatTopology(displays: [primary, secondary]))
        #expect(!topology.permitsInterHabitatRelocation(
            from: .init(displayID: primaryID, kind: .floor),
            exitPortalID: "floor.exit",
            to: .init(displayID: secondaryID, kind: .topShelf),
            entryPortalID: "topShelf.entry",
            using: [.ledgePortalTraversal]
        ))
    }

    @Test("Only explicit fully hidden zero-root portal pairs can relocate between habitats")
    func portalRelocation() throws {
        let topology = try #require(HabitatTopology(displays: [snapshot()!]))
        let floor = HabitatSurfaceIdentifier(displayID: primaryID, kind: .floor)
        let shelf = HabitatSurfaceIdentifier(displayID: primaryID, kind: .topShelf)
        let wall = HabitatSurfaceIdentifier(displayID: primaryID, kind: .wallLeft)
        #expect(topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: shelf, entryPortalID: "topShelf.entry",
            using: [.ledgePortalTraversal]
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.entry", to: shelf, entryPortalID: "topShelf.entry",
            using: [.ledgePortalTraversal]
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: shelf, entryPortalID: "missing",
            using: [.ledgePortalTraversal]
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: shelf, entryPortalID: "topShelf.entry",
            using: []
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: wall, entryPortalID: "wallLeft.entry",
            using: [.ledgePortalTraversal]
        ))
        #expect(topology.permitsInterHabitatRelocation(
            from: floor, exitPortalID: "floor.exit", to: wall, entryPortalID: "wallLeft.entry",
            using: [.wallTraversal]
        ))
        #expect(!topology.permitsInterHabitatRelocation(
            from: wall, exitPortalID: "wallLeft.exit", to: floor, entryPortalID: "floor.entry",
            using: [.ledgePortalTraversal]
        ))
        #expect(topology.permitsInterHabitatRelocation(
            from: wall, exitPortalID: "wallLeft.exit", to: floor, entryPortalID: "floor.entry",
            using: [.wallTraversal]
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
            visibleFrame: CGRect(x: 0, y: 580, width: 800, height: 20),
            safeAreaInsets: HabitatInsets(top: 30, left: 0, bottom: 0, right: 0)!,
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
        isMain: Bool = false,
        safeInsets: HabitatInsets? = nil
    ) -> HabitatScreenSnapshot? {
        HabitatScreenSnapshot(
            displayID: id ?? primaryID,
            frame: frame,
            visibleFrame: visible,
            safeAreaInsets: safeInsets ?? HabitatInsets(top: 30, left: 0, bottom: 0, right: 0)!,
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
