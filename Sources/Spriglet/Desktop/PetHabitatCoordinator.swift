import AppKit
import SprigletCore

/// The coordinator needs only this narrow host contract. Keeping NSWindow and
/// placement policy behind it makes hidden-endpoint recovery deterministic and
/// lets the failure boundaries be exercised without moving a real desktop.
@MainActor
protocol PetHabitatHosting: AnyObject {
    var habitatVisitWindowSize: CGSize { get }
    var habitatVisitSourceDisplayID: UUID? { get }
    func beginHabitatVisit() -> PetHabitatVisitToken?
    func relocateHabitatVisit(
        _ token: PetHabitatVisitToken,
        to surface: HabitatSurface,
        permit: PetHabitatRelocationPermit
    ) -> Bool
    func restoreHabitatVisitToFloor(
        _ token: PetHabitatVisitToken,
        permit: PetHabitatRelocationPermit
    ) -> Bool
    func recoverHabitatVisitToFloor(
        _ token: PetHabitatVisitToken,
        permit: PetHabitatRelocationPermit
    ) -> Bool
    func finishHabitatVisit(_ token: PetHabitatVisitToken) -> Bool
    func abortHabitatVisitWhileInvisible(_ token: PetHabitatVisitToken) -> Bool
}

/// Coordinates one finite, click-transparent portal visit. Geometry is rebuilt
/// on every start and reconciliation; no `NSScreen`, timer, or polling loop is
/// retained by this type.
@MainActor
final class PetHabitatCoordinator {
    enum Trigger: Equatable {
        case automatic
        case explicitPreview
    }

    struct Configuration: Equatable {
        var automaticVisitsEnabled: Bool
        let content: HabitatVisitContent
        let capabilities: Set<HabitatCapability>

        init(
            automaticVisitsEnabled: Bool = false,
            content: HabitatVisitContent,
            capabilities: Set<HabitatCapability> = [.ledgePortalTraversal]
        ) {
            self.automaticVisitsEnabled = automaticVisitsEnabled
            self.content = content
            self.capabilities = capabilities
        }
    }

    enum CancellationReason: Equatable {
        case hidden
        case userInteraction
        case topologyChanged
        case displaySizeChanged
        case policyChanged
        case stopped
    }

    private struct MarkerExpectation {
        let intentID: String
        let id: String
        let poseID: String
        let kind: CharacterPlaybackMarker.Kind
        let endpoint: CharacterTimelineSnapshot

        func matches(_ marker: CharacterPlaybackMarker) -> Bool {
            marker.kind == kind && marker.id == id && marker.poseID == poseID
                && marker.clipID == endpoint.clip
                && marker.clipFrameIndex == endpoint.clipFrameIndex
                && marker.timelineFrameIndex == endpoint.timelineFrameIndex
        }
    }

    private struct ActiveVisit {
        let generation: UInt64
        let topology: HabitatTopology
        let plan: HabitatVisitPlan
        let destination: HabitatSurface
        let hostToken: PetHabitatVisitToken
        var expectedMarker: MarkerExpectation?
        var recoveringAtFloor = false
        var cancellationRequested = false
    }

    private var configuration: Configuration
    private let desktop: any PetHabitatHosting
    private let currentTopology: @MainActor () -> HabitatTopology?
    private let setPlaybackHabitat: @MainActor (String, String?) -> Bool
    private let previewIntent: @MainActor (String) -> CharacterTimeline?
    private let performIntent: @MainActor (String) -> Bool
    private let resetScene: @MainActor () -> Void
    private let onActivityChanged: @MainActor (Bool) -> Void
    private var planner = HabitatVisitPlanner()
    private var active: ActiveVisit?
    private var generation: UInt64 = 0
    private var lastFinishedGeneration: UInt64?

    private(set) var completedVisitCount: UInt64 = 0
    private(set) var cancellationCount: UInt64 = 0
    private(set) var relocationCount: UInt64 = 0
    var isActive: Bool { active != nil }
    var phase: HabitatVisitPlanner.Phase { planner.phase }

    init(
        configuration: Configuration,
        desktop: any PetHabitatHosting,
        currentTopology: @escaping @MainActor () -> HabitatTopology? = {
            ScreenHabitatProvider().currentTopology()
        },
        setPlaybackHabitat: @escaping @MainActor (String, String?) -> Bool,
        previewIntent: @escaping @MainActor (String) -> CharacterTimeline?,
        performIntent: @escaping @MainActor (String) -> Bool,
        resetScene: @escaping @MainActor () -> Void,
        onActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.desktop = desktop
        self.currentTopology = currentTopology
        self.setPlaybackHabitat = setPlaybackHabitat
        self.previewIntent = previewIntent
        self.performIntent = performIntent
        self.resetScene = resetScene
        self.onActivityChanged = onActivityChanged
    }

    func setAutomaticVisitsEnabled(_ enabled: Bool) {
        guard configuration.automaticVisitsEnabled != enabled else { return }
        configuration.automaticVisitsEnabled = enabled
        if !enabled { cancel(.policyChanged) }
    }

    /// Returns true only after the host token and the first finite intent have
    /// both been accepted. Automatic production use is disabled by default.
    @discardableResult
    func requestVisit(_ trigger: Trigger) -> Bool {
        guard active == nil,
              trigger == .explicitPreview || configuration.automaticVisitsEnabled,
              configuration.capabilities.contains(.ledgePortalTraversal),
              let topology = currentTopology(),
              topology.artGeometry.portalWindowSize == desktop.habitatVisitWindowSize,
              let sourceDisplayID = desktop.habitatVisitSourceDisplayID,
              let route = makeRoute(in: topology, sourceDisplayID: sourceDisplayID),
              let token = desktop.beginHabitatVisit()
        else { return false }

        guard setPlaybackHabitat(HabitatSurfaceKind.floor.rawValue, nil) else {
            _ = desktop.finishHabitatVisit(token)
            return false
        }
        generation &+= 1
        active = ActiveVisit(
            generation: generation,
            topology: topology,
            plan: route.plan,
            destination: route.destination,
            hostToken: token
        )
        let effects = planner.begin(route.plan)
        guard execute(effects, permit: nil, generation: generation) else {
            planner.reset()
            active = nil
            _ = desktop.finishHabitatVisit(token)
            _ = setPlaybackHabitat("desktop", nil)
            return false
        }
        onActivityChanged(true)
        return true
    }

    /// Marker callbacks can synchronously start the next intent. Expectations
    /// are therefore installed before `performIntent`, and every continuation
    /// checks the visit generation after crossing that callback boundary.
    func receive(_ marker: CharacterPlaybackMarker) {
        guard var visit = active, let expectation = visit.expectedMarker,
              expectation.matches(marker) else { return }
        let expectedGeneration = visit.generation
        visit.expectedMarker = nil
        active = visit

        let permit: PetHabitatRelocationPermit?
        if marker.kind == .semanticEvent {
            let role: PetHabitatRelocationPermit.Role = expectation.intentID
                == visit.plan.content.floorExitIntentID ? .floorExit : .ledgeExit
            permit = PetHabitatRelocationPermit(
                marker: marker,
                expectedEndpoint: expectation.endpoint,
                fullyHiddenEventID: visit.plan.content.fullyHiddenEventID,
                hiddenPoseID: visit.plan.content.hiddenPoseID,
                role: role
            )
        } else {
            permit = nil
        }

        if visit.recoveringAtFloor {
            guard marker.id == visit.plan.content.settledMarkerID,
                  marker.poseID == visit.plan.content.floorPoseID else { return }
            complete(generation: expectedGeneration, counted: false)
            return
        }

        let fact = HabitatVisitMarkerFact(id: marker.id, poseID: marker.poseID ?? "")
        let previousPlanner = planner
        var proposedPlanner = planner
        let effects = proposedPlanner.receive(fact)
        guard active?.generation == expectedGeneration else { return }
        planner = proposedPlanner
        if !execute(effects, permit: permit, generation: expectedGeneration) {
            planner = previousPlanner
            recoverAfterFailure(from: fact, permit: permit, generation: expectedGeneration)
        }
    }

    /// Rebuilds the platform topology only in response to an existing lifecycle
    /// event. Any contract change requests an authored return; it never moves a
    /// visible pet directly.
    func reconcile(policyAllowsVisit: Bool, displaySize: CGSize) {
        guard let visit = active else { return }
        guard policyAllowsVisit else {
            cancel(.policyChanged)
            return
        }
        guard displaySize == visit.hostToken.windowSize else {
            cancel(.displaySizeChanged)
            return
        }
        guard currentTopology() == visit.topology else {
            cancel(.topologyChanged)
            return
        }
    }

    func cancel(_ reason: CancellationReason) {
        guard var visit = active else { return }
        // A graceful return requested while visible can later become an
        // immediate safe abort when AppKit hides or fully occludes the panel.
        // Check that stronger proof before recovery/idempotence guards: stop or
        // hide can otherwise strand a suspended recovery with no marker source.
        if [.hidden, .stopped].contains(reason),
           desktop.abortHabitatVisitWhileInvisible(visit.hostToken) {
            cancellationCount &+= 1
            finishAbortedVisit(generation: visit.generation)
            return
        }
        guard !visit.recoveringAtFloor else { return }
        guard !visit.cancellationRequested else { return }
        visit.cancellationRequested = true
        active = visit
        cancellationCount &+= 1
        let effects = planner.cancel()
        guard !effects.isEmpty else { return }
        if !execute(effects, permit: nil, generation: visit.generation) {
            // The visible pose remains click-transparent and stationary. A
            // later lifecycle reconcile can retry without an unsafe move.
            active?.expectedMarker = nil
        }
    }

    private func makeRoute(
        in topology: HabitatTopology,
        sourceDisplayID: UUID
    ) -> (plan: HabitatVisitPlan, destination: HabitatSurface)? {
        let sourceID = HabitatSurfaceIdentifier(displayID: sourceDisplayID, kind: .floor)
        guard let source = topology.surfaces.first(where: { $0.id == sourceID }),
              source.isSelectable(using: configuration.capabilities) else { return nil }

        let kindOrder: [HabitatSurfaceKind: Int] = [.notchLeft: 0, .notchRight: 1, .topShelf: 2]
        let candidates = topology.surfaces.filter {
            $0.id.displayID == sourceDisplayID
                && kindOrder[$0.id.kind] != nil
                && $0.isSelectable(using: configuration.capabilities)
        }.sorted {
            (kindOrder[$0.id.kind] ?? .max, $0.interval.start)
                < (kindOrder[$1.id.kind] ?? .max, $1.interval.start)
        }

        for destination in candidates {
            guard let sourceExit = source.exitPortals.first(where: {
                $0.connectedSurfaceKinds.contains(destination.id.kind)
            }), let destinationEntry = destination.entryPortals.first(where: {
                $0.connectedSurfaceKinds.contains(source.id.kind)
            }), let destinationExit = destination.exitPortals.first(where: {
                $0.connectedSurfaceKinds.contains(source.id.kind)
            }), let sourceEntry = source.entryPortals.first(where: {
                $0.connectedSurfaceKinds.contains(destination.id.kind)
            }), let plan = HabitatVisitPlan(
                topology: topology,
                source: source.id,
                destination: destination.id,
                sourceExitPortalID: sourceExit.id,
                destinationEntryPortalID: destinationEntry.id,
                destinationExitPortalID: destinationExit.id,
                sourceEntryPortalID: sourceEntry.id,
                content: configuration.content
            ) else { continue }
            return (plan, destination)
        }
        return nil
    }

    private func execute(
        _ effects: [HabitatVisitEffect],
        permit: PetHabitatRelocationPermit?,
        generation expectedGeneration: UInt64
    ) -> Bool {
        var deferPlaybackUntilContextSettles = false
        for effect in effects {
            guard let visit = active, visit.generation == expectedGeneration else { return false }
            switch effect {
            case let .playIntent(intentID):
                if deferPlaybackUntilContextSettles {
                    Task { @MainActor [weak self] in
                        guard let self, active?.generation == expectedGeneration else { return }
                        if !play(intentID, generation: expectedGeneration) {
                            active?.expectedMarker = nil
                            if let permit {
                                _ = recoverHiddenTransition(
                                    permit: permit,
                                    generation: expectedGeneration
                                )
                            }
                        }
                    }
                    continue
                }
                guard play(intentID, generation: expectedGeneration) else { return false }

            case .relocateToDestination:
                guard let permit,
                      currentTopology() == visit.topology,
                      desktop.relocateHabitatVisit(
                        visit.hostToken, to: visit.destination, permit: permit
                      ) else { return false }
                relocationCount &+= 1
                guard setPlaybackHabitat(
                    visit.destination.id.kind.rawValue, visit.plan.content.hiddenPoseID
                ) else { return false }
                deferPlaybackUntilContextSettles = true

            case .restoreFloor:
                guard let permit,
                      desktop.restoreHabitatVisitToFloor(visit.hostToken, permit: permit)
                else { return false }
                relocationCount &+= 1
                guard setPlaybackHabitat(
                    HabitatSurfaceKind.floor.rawValue, visit.plan.content.hiddenPoseID
                ) else { return false }
                deferPlaybackUntilContextSettles = true

            case .completed:
                complete(generation: expectedGeneration, counted: true)
            }
        }
        return true
    }

    private func play(_ intentID: String, generation expectedGeneration: UInt64) -> Bool {
        guard var visit = active, visit.generation == expectedGeneration,
              let timeline = previewIntent(intentID),
              timeline.rootOffsets.allSatisfy({ $0 == .zero }),
              let expectation = expectation(for: intentID, timeline: timeline, content: visit.plan.content)
        else { return false }
        visit.expectedMarker = expectation
        active = visit
        guard performIntent(intentID) else {
            if active?.generation == expectedGeneration { active?.expectedMarker = nil }
            return false
        }
        return active?.generation == expectedGeneration
            || lastFinishedGeneration == expectedGeneration
    }

    private func expectation(
        for intentID: String,
        timeline: CharacterTimeline,
        content: HabitatVisitContent
    ) -> MarkerExpectation? {
        let contract: (id: String, pose: String, kind: CharacterPlaybackMarker.Kind)
        switch intentID {
        case content.floorExitIntentID, content.ledgeExitIntentID:
            contract = (content.fullyHiddenEventID, content.hiddenPoseID, .semanticEvent)
        case content.ledgeEntryIntentID, content.edgeLookIntentID, content.pullUpIntentID:
            contract = (content.settledMarkerID, content.ledgePoseID, .interruption)
        case content.dangleIntentID:
            contract = (content.settledMarkerID, content.hangingPoseID, .interruption)
        case content.floorReentryIntentID:
            contract = (content.settledMarkerID, content.floorPoseID, .interruption)
        default:
            return nil
        }
        guard timeline.endPoseID == contract.pose, timeline.frameCount > 0 else { return nil }
        let endpoint = timeline.snapshot(atFrame: timeline.frameCount - 1)
        guard timeline.markers(atFrame: timeline.frameCount - 1).contains(where: {
            $0.kind == contract.kind && $0.id == contract.id && $0.poseID == contract.pose
                && $0.clipID == endpoint.clip && $0.clipFrameIndex == endpoint.clipFrameIndex
        }) else { return nil }
        return MarkerExpectation(
            intentID: intentID, id: contract.id, poseID: contract.pose,
            kind: contract.kind, endpoint: endpoint
        )
    }

    private func recoverAfterFailure(
        from fact: HabitatVisitMarkerFact,
        permit: PetHabitatRelocationPermit?,
        generation expectedGeneration: UInt64
    ) {
        guard let visit = active, visit.generation == expectedGeneration else { return }
        if let permit, recoverHiddenTransition(permit: permit, generation: expectedGeneration) {
            return
        }
        let recovery = planner.recover(from: fact)
        if !recovery.isEmpty,
           execute(recovery, permit: nil, generation: expectedGeneration) { return }
        let effects = planner.cancel()
        if !effects.isEmpty, execute(effects, permit: nil, generation: expectedGeneration) { return }
    }

    /// Completes a partially applied hidden-endpoint transaction on the floor.
    /// The host accepts the floor-exit permit only before any upper frame was
    /// presented, and accepts the ledge-exit permit for an idempotent restore.
    @discardableResult
    private func recoverHiddenTransition(
        permit: PetHabitatRelocationPermit,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard var visit = active, visit.generation == expectedGeneration,
              desktop.recoverHabitatVisitToFloor(visit.hostToken, permit: permit)
        else { return false }

        planner.reset()
        visit.recoveringAtFloor = true
        visit.cancellationRequested = true
        visit.expectedMarker = nil
        active = visit

        let floorContextAccepted = setPlaybackHabitat(
            HabitatSurfaceKind.floor.rawValue,
            visit.plan.content.hiddenPoseID
        )
        if floorContextAccepted,
           play(visit.plan.content.floorReentryIntentID, generation: expectedGeneration) {
            return true
        }

        // The host is already back at a proven floor endpoint. If renderer
        // recovery is unavailable, reveal only the ordinary stable pose there.
        resetScene()
        complete(generation: expectedGeneration, counted: false)
        return active == nil
    }

    private func complete(generation expectedGeneration: UInt64, counted: Bool) {
        guard let visit = active, visit.generation == expectedGeneration else { return }
        let previousPlanner = planner
        active = nil
        planner.reset()
        guard desktop.finishHabitatVisit(visit.hostToken) else {
            active = visit
            planner = previousPlanner
            return
        }
        generation &+= 1
        lastFinishedGeneration = expectedGeneration
        if counted { completedVisitCount &+= 1 }
        _ = setPlaybackHabitat("desktop", nil)
        onActivityChanged(false)
    }

    private func finishAbortedVisit(generation expectedGeneration: UInt64) {
        guard active?.generation == expectedGeneration else { return }
        active = nil
        planner.reset()
        generation &+= 1
        lastFinishedGeneration = expectedGeneration
        resetScene()
        _ = setPlaybackHabitat("desktop", nil)
        onActivityChanged(false)
    }
}
