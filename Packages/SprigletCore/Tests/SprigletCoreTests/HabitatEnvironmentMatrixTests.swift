import CoreGraphics
import Foundation
import Testing
@testable import SprigletCore

@Suite("Habitat environment matrix")
struct HabitatEnvironmentMatrixTests {
    private let displayID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000601")!

    @Test("Every Dock edge and the hidden Dock preserve the usable rectangle")
    func dockEdges() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let fixtures: [(name: String, visible: CGRect, expected: HabitatInsets)] = [
            (
                "bottom",
                CGRect(x: 0, y: 80, width: 1_440, height: 796),
                HabitatInsets(top: 24, left: 0, bottom: 80, right: 0)!
            ),
            (
                "left",
                CGRect(x: 80, y: 0, width: 1_360, height: 876),
                HabitatInsets(top: 24, left: 80, bottom: 0, right: 0)!
            ),
            (
                "right",
                CGRect(x: 0, y: 0, width: 1_360, height: 876),
                HabitatInsets(top: 24, left: 0, bottom: 0, right: 80)!
            ),
            (
                "auto-hidden",
                CGRect(x: 0, y: 0, width: 1_440, height: 876),
                HabitatInsets(top: 24, left: 0, bottom: 0, right: 0)!
            )
        ]

        for fixture in fixtures {
            let display = try #require(snapshot(frame: frame, visibleFrame: fixture.visible))
            #expect(display.dockAndMenuInsets == fixture.expected, "Unexpected \(fixture.name) insets")
            let topology = try #require(HabitatTopology(displays: [display]))
            let floor = try #require(surface(.floor, in: topology))
            let shelf = try #require(surface(.topShelf, in: topology))
            #expect(floor.interval.fixedCoordinate == fixture.visible.minY)
            #expect(floor.interval.start == fixture.visible.minX)
            #expect(floor.interval.end == fixture.visible.maxX)
            #expect(shelf.interval.fixedCoordinate == fixture.visible.maxY)
            #expect(fixture.visible.contains(shelf.safeVisualBounds))
        }
    }

    @Test("Menu-bar visibility changes rebuild top geometry from the new snapshot")
    func menuBarVisibilityRebuild() throws {
        let frame = CGRect(x: -400, y: 100, width: 1_440, height: 900)
        let shown = try #require(snapshot(
            frame: frame,
            visibleFrame: CGRect(x: -400, y: 100, width: 1_440, height: 876)
        ))
        let hidden = try #require(snapshot(frame: frame, visibleFrame: frame))
        let shownTopology = try #require(HabitatTopology(displays: [shown]))
        let hiddenTopology = try #require(HabitatTopology(displays: [hidden]))
        let shownShelf = try #require(surface(.topShelf, in: shownTopology))
        let hiddenShelf = try #require(surface(.topShelf, in: hiddenTopology))

        #expect(shownShelf.safeVisualBounds.maxY == frame.maxY - 24)
        #expect(hiddenShelf.safeVisualBounds.maxY == frame.maxY)
        #expect(hiddenShelf.safeVisualBounds.minY - shownShelf.safeVisualBounds.minY == 24)
        #expect(shownTopology != hiddenTopology)
    }

    @Test("Notched and ordinary mixed-scale displays coexist without crossing protected bounds")
    func mixedNotchMatrix() throws {
        let notchedID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000602")!
        let ordinaryID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000603")!
        let leftAuxiliary = CGRect(x: 0, y: 956, width: 700, height: 44)
        let rightAuxiliary = CGRect(x: 812, y: 956, width: 700, height: 44)
        let notched = try #require(HabitatScreenSnapshot(
            displayID: notchedID,
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 956),
            safeAreaInsets: HabitatInsets(top: 44, left: 0, bottom: 0, right: 0)!,
            auxiliaryTopLeftArea: leftAuxiliary,
            auxiliaryTopRightArea: rightAuxiliary,
            backingScale: 2,
            isMain: true
        ))
        let ordinary = try #require(HabitatScreenSnapshot(
            displayID: ordinaryID,
            frame: CGRect(x: -1_920, y: -180, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: -1_920, y: -180, width: 1_920, height: 1_056),
            safeAreaInsets: HabitatInsets(top: 24, left: 0, bottom: 0, right: 0)!,
            backingScale: 1
        ))
        let topology = try #require(HabitatTopology(displays: [notched, ordinary]))

        #expect(topology.displays.map(\.backingScale) == [2, 1])
        #expect(topology.surfaces.filter { $0.id.displayID == notchedID && $0.id.kind == .notchLeft }.count == 1)
        #expect(topology.surfaces.filter { $0.id.displayID == notchedID && $0.id.kind == .notchRight }.count == 1)
        #expect(topology.surfaces.filter { $0.id.displayID == ordinaryID && $0.id.kind == .topShelf }.count == 1)
        #expect(topology.surfaces.filter { [.topShelf, .notchLeft, .notchRight].contains($0.id.kind) }
            .allSatisfy { surface in
                topology.displays.first(where: { $0.displayID == surface.id.displayID })
                    .map { $0.visibleFrame.contains(surface.safeVisualBounds) } == true
            })
    }

    private func snapshot(frame: CGRect, visibleFrame: CGRect) -> HabitatScreenSnapshot? {
        HabitatScreenSnapshot(
            displayID: displayID,
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaInsets: HabitatInsets(
                top: max(0, frame.maxY - visibleFrame.maxY),
                left: max(0, visibleFrame.minX - frame.minX),
                bottom: max(0, visibleFrame.minY - frame.minY),
                right: max(0, frame.maxX - visibleFrame.maxX)
            )!,
            backingScale: 2,
            isMain: true
        )
    }

    private func surface(_ kind: HabitatSurfaceKind, in topology: HabitatTopology) -> HabitatSurface? {
        topology.surfaces.first { $0.id.displayID == displayID && $0.id.kind == kind }
    }
}
