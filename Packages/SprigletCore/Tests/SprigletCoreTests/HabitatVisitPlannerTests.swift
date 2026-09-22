import CoreGraphics
import Foundation
import Testing
@testable import SprigletCore

@Suite("Habitat visit planner")
struct HabitatVisitPlannerTests {
    @Test("A visit is finite and relocates only at authored hidden endpoints")
    func finiteRoundTrip() throws {
        let plan = try makePlan()
        var planner = HabitatVisitPlanner()

        #expect(planner.begin(plan) == [.playIntent("visit.floor-exit")])
        #expect(planner.receive(.init(id: "settled", poseID: "ready")) == [])
        #expect(planner.receive(.init(id: "fullyHidden", poseID: "wrong")) == [])
        #expect(planner.receive(.init(id: "fullyHidden", poseID: "hidden")) == [
            .relocateToDestination(plan.destination), .playIntent("visit.peek-in")
        ])
        #expect(planner.receive(.init(id: "settled", poseID: "peek")) == [
            .playIntent("visit.edge-look")
        ])
        #expect(planner.receive(.init(id: "settled", poseID: "peek")) == [
            .playIntent("visit.dangle")
        ])
        #expect(planner.receive(.init(id: "settled", poseID: "hang")) == [
            .playIntent("visit.pull-up")
        ])
        #expect(planner.receive(.init(id: "settled", poseID: "peek")) == [
            .playIntent("visit.ledge-exit")
        ])
        #expect(planner.receive(.init(id: "fullyHidden", poseID: "hidden")) == [
            .restoreFloor(plan.source), .playIntent("visit.floor-reentry")
        ])
        #expect(planner.receive(.init(id: "settled", poseID: "ready")) == [.completed])
        #expect(planner.phase == .idle)
        #expect(planner.plan == nil)
    }

    @Test("Cancellation during floor exit waits for hidden and never visits the ledge")
    func cancellationBeforeRelocation() throws {
        let plan = try makePlan()
        var planner = HabitatVisitPlanner()
        _ = planner.begin(plan)

        #expect(planner.cancel() == [])
        #expect(planner.phase == .leavingFloor(cancelRequested: true))
        #expect(planner.receive(.init(id: "fullyHidden", poseID: "hidden")) == [
            .restoreFloor(plan.source), .playIntent("visit.floor-reentry")
        ])
        #expect(planner.receive(.init(id: "settled", poseID: "ready")) == [.completed])
    }

    @Test("Cancellation on a visible ledge routes through the authored exit")
    func cancellationAtLedge() throws {
        let plan = try makePlan()
        var planner = HabitatVisitPlanner()
        _ = planner.begin(plan)
        _ = planner.receive(.init(id: "fullyHidden", poseID: "hidden"))
        _ = planner.receive(.init(id: "settled", poseID: "peek"))

        #expect(planner.cancel() == [])
        #expect(planner.cancel() == [])
        #expect(planner.receive(.init(id: "settled", poseID: "peek")) == [
            .playIntent("visit.ledge-exit")
        ])
        #expect(planner.receive(.init(id: "fullyHidden", poseID: "hidden")) == [
            .restoreFloor(plan.source), .playIntent("visit.floor-reentry")
        ])
    }

    @Test("Plans reject missing portal pairs, walls, and malformed content")
    func invalidPlans() throws {
        let topology = try #require(makeTopology())
        let floor = HabitatSurfaceIdentifier(displayID: displayID, kind: .floor)
        let shelf = HabitatSurfaceIdentifier(displayID: displayID, kind: .topShelf)
        let wall = HabitatSurfaceIdentifier(displayID: displayID, kind: .wallLeft)
        let content = try #require(makeContent())

        #expect(HabitatVisitPlan(
            topology: topology, source: floor, destination: shelf,
            sourceExitPortalID: "missing", destinationEntryPortalID: "topShelf.entry",
            destinationExitPortalID: "topShelf.exit", sourceEntryPortalID: "floor.entry",
            content: content
        ) == nil)
        #expect(HabitatVisitPlan(
            topology: topology, source: floor, destination: wall,
            sourceExitPortalID: "floor.exit", destinationEntryPortalID: "wallLeft.entry",
            destinationExitPortalID: "wallLeft.exit", sourceEntryPortalID: "floor.entry",
            content: content
        ) == nil)
        #expect(HabitatVisitContent(
            floorExitIntentID: "duplicate", ledgeEntryIntentID: "duplicate",
            edgeLookIntentID: "edge", dangleIntentID: "dangle", pullUpIntentID: "pull",
            ledgeExitIntentID: "exit", floorReentryIntentID: "entry",
            hiddenPoseID: "hidden", ledgePoseID: "peek", hangingPoseID: "hang",
            floorPoseID: "ready", fullyHiddenEventID: "hidden event", settledMarkerID: "settled"
        ) == nil)
    }

    @Test("Rejected local intents recover only through proven authored endpoints")
    func rejectedIntentRecovery() throws {
        let plan = try makePlan()
        var planner = HabitatVisitPlanner()
        _ = planner.begin(plan)
        _ = planner.receive(.init(id: "fullyHidden", poseID: "hidden"))
        _ = planner.receive(.init(id: "settled", poseID: "peek"))

        #expect(planner.recover(from: .init(id: "settled", poseID: "peek")) == [
            .playIntent("visit.ledge-exit")
        ])
        #expect(planner.phase == .leavingLedge)

        planner.reset()
        _ = planner.begin(plan)
        _ = planner.receive(.init(id: "fullyHidden", poseID: "hidden"))
        _ = planner.receive(.init(id: "settled", poseID: "peek"))
        _ = planner.receive(.init(id: "settled", poseID: "peek"))
        _ = planner.receive(.init(id: "settled", poseID: "hang"))
        #expect(planner.recover(from: .init(id: "settled", poseID: "hang")) == [
            .playIntent("visit.pull-up")
        ])
        #expect(planner.phase == .pullUp(cancelRequested: true))
        #expect(planner.recover(from: .init(id: "settled", poseID: "unknown")) == [])
    }

    private var displayID: UUID {
        UUID(uuidString: "D15A1A00-0000-4000-8000-000000000599")!
    }

    private func makePlan() throws -> HabitatVisitPlan {
        let topology = try #require(makeTopology())
        let content = try #require(makeContent())
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

    private func makeContent() -> HabitatVisitContent? {
        HabitatVisitContent(
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
        )
    }

    private func makeTopology() -> HabitatTopology? {
        let snapshot = HabitatScreenSnapshot(
            displayID: displayID,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 870),
            safeAreaInsets: HabitatInsets(top: 30, left: 0, bottom: 0, right: 0)!,
            backingScale: 2,
            isMain: true
        )!
        return HabitatTopology(displays: [snapshot])
    }
}
