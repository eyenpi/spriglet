import CoreGraphics
import Foundation
import Testing
@testable import SprigletCore

@Suite("Habitat cancellation matrix")
struct HabitatCancellationMatrixTests {
    private enum CancellationPoint: CaseIterable {
        case leavingFloor
        case enteringLedge
        case edgeLook
        case dangle
        case pullUp
    }

    @Test("Every interruptible visit phase follows an authored route home")
    func everyInterruptiblePhaseReturnsHome() throws {
        for point in CancellationPoint.allCases {
            let plan = try makePlan()
            var planner = HabitatVisitPlanner()
            _ = planner.begin(plan)
            advance(&planner, to: point)

            #expect(planner.cancel().isEmpty, "Cancellation at \(point) must wait for an authored endpoint")
            #expect(planner.cancel().isEmpty, "Repeated cancellation at \(point) must be idempotent")
            let effects = finishAfterCancellation(&planner, from: point, plan: plan)

            if point == .leavingFloor {
                #expect(!effects.contains(.restoreFloor(plan.source)),
                        "Cancellation before relocation must not request a host restore")
            } else {
                #expect(effects.contains(.restoreFloor(plan.source)),
                        "Cancellation at \(point) never restored the relocated floor host")
            }
            #expect(effects.contains(.playIntent(plan.content.floorReentryIntentID)),
                    "Cancellation at \(point) skipped the authored floor re-entry")
            #expect(effects.last == .completed, "Cancellation at \(point) did not finish exactly at the floor endpoint")
            #expect(planner.phase == .idle)
            #expect(planner.plan == nil)
        }
    }

    @Test("Already returning phases ignore cancellation and still finish")
    func returningPhasesAreIdempotent() throws {
        let plan = try makePlan()
        var planner = HabitatVisitPlanner()
        _ = planner.begin(plan)
        _ = planner.receive(hidden(plan))
        _ = planner.receive(ledge(plan))
        _ = planner.receive(ledge(plan))
        _ = planner.receive(hanging(plan))
        _ = planner.receive(ledge(plan))
        #expect(planner.phase == .leavingLedge)
        #expect(planner.cancel().isEmpty)

        let restore = planner.receive(hidden(plan))
        #expect(restore == [.restoreFloor(plan.source), .playIntent(plan.content.floorReentryIntentID)])
        #expect(planner.phase == .enteringFloor)
        #expect(planner.cancel().isEmpty)
        #expect(planner.receive(floor(plan)) == [.completed])
        #expect(planner.phase == .idle)
    }

    private func advance(_ planner: inout HabitatVisitPlanner, to point: CancellationPoint) {
        guard point != .leavingFloor, let plan = planner.plan else { return }
        _ = planner.receive(hidden(plan))
        guard point != .enteringLedge else { return }
        _ = planner.receive(ledge(plan))
        guard point != .edgeLook else { return }
        _ = planner.receive(ledge(plan))
        guard point != .dangle else { return }
        _ = planner.receive(hanging(plan))
    }

    private func finishAfterCancellation(
        _ planner: inout HabitatVisitPlanner,
        from point: CancellationPoint,
        plan: HabitatVisitPlan
    ) -> [HabitatVisitEffect] {
        var effects: [HabitatVisitEffect] = []
        switch point {
        case .leavingFloor:
            effects += planner.receive(hidden(plan))
        case .enteringLedge, .edgeLook:
            effects += planner.receive(ledge(plan))
            effects += planner.receive(hidden(plan))
        case .dangle:
            effects += planner.receive(hanging(plan))
            effects += planner.receive(ledge(plan))
            effects += planner.receive(hidden(plan))
        case .pullUp:
            effects += planner.receive(ledge(plan))
            effects += planner.receive(hidden(plan))
        }
        effects += planner.receive(floor(plan))
        return effects
    }

    private func hidden(_ plan: HabitatVisitPlan) -> HabitatVisitMarkerFact {
        .init(id: plan.content.fullyHiddenEventID, poseID: plan.content.hiddenPoseID)
    }

    private func ledge(_ plan: HabitatVisitPlan) -> HabitatVisitMarkerFact {
        .init(id: plan.content.settledMarkerID, poseID: plan.content.ledgePoseID)
    }

    private func hanging(_ plan: HabitatVisitPlan) -> HabitatVisitMarkerFact {
        .init(id: plan.content.settledMarkerID, poseID: plan.content.hangingPoseID)
    }

    private func floor(_ plan: HabitatVisitPlan) -> HabitatVisitMarkerFact {
        .init(id: plan.content.settledMarkerID, poseID: plan.content.floorPoseID)
    }

    private func makePlan() throws -> HabitatVisitPlan {
        let displayID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000699")!
        let snapshot = try #require(HabitatScreenSnapshot(
            displayID: displayID,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 876),
            safeAreaInsets: HabitatInsets(top: 24, left: 0, bottom: 0, right: 0)!,
            backingScale: 2,
            isMain: true
        ))
        let topology = try #require(HabitatTopology(displays: [snapshot]))
        let content = try #require(HabitatVisitContent(
            floorExitIntentID: "visit.floor-exit",
            ledgeEntryIntentID: "visit.peek-in",
            edgeLookIntentID: "visit.edge-look",
            dangleIntentID: "visit.dangle",
            pullUpIntentID: "visit.pull-up",
            ledgeExitIntentID: "visit.ledge-exit",
            floorReentryIntentID: "visit.floor-reentry",
            hiddenPoseID: "hidden",
            ledgePoseID: "peek",
            hangingPoseID: "hang",
            floorPoseID: "ready",
            fullyHiddenEventID: "fullyHidden",
            settledMarkerID: "settled"
        ))
        return try #require(HabitatVisitPlan(
            topology: topology,
            source: .init(displayID: displayID, kind: .floor),
            destination: .init(displayID: displayID, kind: .topShelf),
            sourceExitPortalID: "floor.exit",
            destinationEntryPortalID: "topShelf.entry",
            destinationExitPortalID: "topShelf.exit",
            sourceEntryPortalID: "floor.entry",
            content: content
        ))
    }
}
