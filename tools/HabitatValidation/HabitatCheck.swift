import AppKit
import Foundation
import SprigletCore

@main
@MainActor
struct HabitatCheck {
    static func main() async {
        do {
            let preview = CommandLine.arguments.contains("--preview")
            NSApplication.shared.setActivationPolicy(.accessory)
            let report = try await audit(preview: preview)
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        } catch {
            fputs("Habitat validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func audit(preview: Bool) async throws -> HabitatReport {
        let resources = try require(
            Bundle.main.resourceURL?.appendingPathComponent("HabitatAcorn", isDirectory: true),
            "Packaged habitat resources are unavailable"
        )
        let renderer = PetRenderView(frame: .zero, resourceDirectory: resources)
        try require(renderer.assetError == nil, renderer.assetError ?? "Renderer rejected the habitat package")
        let package = try require(renderer.characterPackage, "Character package did not load")
        let content = try require(
            package.habitatVisitContent,
            "The habitat package does not declare its visit roles"
        )
        let expectedInterruptionMarkers = Set(package.clips.flatMap { clipID, clip in
            guard clipID.hasPrefix("habitat.") else { return [MarkerIdentity]() }
            return clip.interruptionMarkers.map {
                MarkerIdentity(clipID: clipID, frameIndex: $0.frameIndex, id: $0.id)
            }
        })
        try require(!expectedInterruptionMarkers.isEmpty,
                    "The habitat package declares no interruption markers")
        let artGeometry = try require(
            HabitatPortalArtGeometry.acornStandard.scaled(
                toPortalWindowSize: renderer.displaySize
            ),
            "The renderer size cannot preserve the measured habitat geometry"
        )
        let provider = ScreenHabitatProvider(artGeometry: artGeometry)
        let topologyGate = TopologyGate()
        let recoveryAudit = try await auditCoordinatorFailures(
            package: package,
            content: content,
            topology: try require(provider.currentTopology(), "Current habitat topology is unavailable")
        )
        let desktop = PetWindowController(
            contentView: renderer,
            size: renderer.displaySize,
            habitatSafeVisibleFrame: { topologyGate.safeVisibleFrame(on: $0) },
            hitTest: { renderer.containsPet(at: $0) }
        )
        desktop.panel.alphaValue = preview ? 1 : 0
        desktop.setClickThrough(false)
        desktop.show()
        defer {
            renderer.setSuspended(true)
            desktop.panel.close()
        }

        let initialPlacement = try require(desktop.currentPlacement, "Initial floor placement is unavailable")
        desktop.restorePlacement(initialPlacement)
        let savedHome = try require(desktop.savedPlacement, "Saved-home fixture was not captured")
        let initialOrigin = desktop.effectiveOrigin
        var activeHabitat = "desktop"
        var markerCount = 0
        var hiddenEventCount = 0
        var ledgeWasMenuSafe = false
        var ledgeWasClickTransparent = false
        var focusStayedPassive = true
        var markerOutsideExpectedEndpoint = false
        var lastInvalidation = "none"
        var markerTrace: [String] = []
        var observedInterruptionMarkers = Set<MarkerIdentity>()
        var maximumBufferedFrames = renderer.bufferedFrameCount
        let resourceStart = ResourceSnapshot(renderer: renderer, desktop: desktop)

        var coordinator: PetHabitatCoordinator!
        coordinator = PetHabitatCoordinator(
            configuration: .init(content: content),
            desktop: desktop,
            currentTopology: { topologyGate.isAvailable ? provider.currentTopology() : nil },
            setPlaybackHabitat: { habitat, preservingPoseID in
                activeHabitat = habitat
                let context = CharacterPlaybackContext(
                    capabilityIDs: Set(package.capabilities),
                    habitatID: habitat,
                    orientationID: "upright"
                )
                if let preservingPoseID {
                    return renderer.setPlaybackContext(context, preservingPoseID: preservingPoseID)
                }
                renderer.setPlaybackContext(context)
                return true
            },
            previewIntent: { renderer.previewIntent($0) },
            performIntent: { renderer.playIntent($0, priority: .contextual) },
            resetScene: { renderer.resetPose() }
        )
        desktop.onHabitatVisitInvalidated = { reason in
            lastInvalidation = String(describing: reason)
            let cancellation: PetHabitatCoordinator.CancellationReason = switch reason {
            case .hidden: .hidden
            case .userInteraction: .userInteraction
            case .topologyChanged: .topologyChanged
            case .displaySizeChanged: .displaySizeChanged
            }
            coordinator.cancel(cancellation)
        }
        renderer.onPlaybackWillStart = { timeline in
            desktop.beginAuthoredMotion(timeline.rootOffsets)
        }
        renderer.onFrame = { snapshot in
            desktop.applyAuthoredFrame(snapshot)
        }
        renderer.onPlaybackStopped = { desktop.finishAuthoredMotion() }
        desktop.onImageOffsetChanged = { renderer.setImageOffset($0) }
        renderer.onPlaybackMarker = { marker in
            markerCount += 1
            markerTrace.append("\(marker.clipID.rawValue):\(marker.id):\(marker.poseID ?? "nil")")
            if marker.kind == .interruption, marker.clipID.rawValue.hasPrefix("habitat.") {
                observedInterruptionMarkers.insert(MarkerIdentity(
                    clipID: marker.clipID.rawValue,
                    frameIndex: marker.clipFrameIndex,
                    id: marker.id
                ))
            }
            if marker.kind == .semanticEvent, marker.id == content.fullyHiddenEventID {
                hiddenEventCount += 1
                if marker.poseID != content.hiddenPoseID { markerOutsideExpectedEndpoint = true }
            }
            coordinator.receive(marker)
        }

        try require(!coordinator.requestVisit(.automatic), "Automatic habitat visits must default to disabled")
        try require(coordinator.requestVisit(.explicitPreview), "Explicit habitat preview was rejected")
        let completionDeadline = ProcessInfo.processInfo.systemUptime + 20
        while coordinator.isActive {
            maximumBufferedFrames = max(maximumBufferedFrames, renderer.bufferedFrameCount)
            observeUpperPlacement(
                coordinator: coordinator,
                provider: provider,
                desktop: desktop,
                menuSafe: &ledgeWasMenuSafe,
                clickTransparent: &ledgeWasClickTransparent,
                focusPassive: &focusStayedPassive
            )
            try await waitStep(
                before: completionDeadline,
                detail: "phase=\(coordinator.phase) habitat=\(activeHabitat) markers=\(markerCount) invalidation=\(lastInvalidation) trace=\(markerTrace)"
            )
        }

        try require(
            coordinator.completedVisitCount == 1,
            "The finite visit did not complete exactly once; completed=\(coordinator.completedVisitCount) "
                + "relocations=\(coordinator.relocationCount) invalidation=\(lastInvalidation) "
                + "phase=\(coordinator.phase) trace=\(markerTrace)"
        )
        try require(desktop.effectiveOrigin.distance(to: initialOrigin) < 0.001,
                    "The visit did not restore the actual floor origin")
        try require(desktop.savedPlacement == savedHome, "The visit overwrote the user's saved home")
        try require(!desktop.panel.ignoresMouseEvents, "The prior click-through state was not restored")

        // A policy change after the second relocation must wait for the visible
        // ledge pose, use the authored exit, and return through the floor portal.
        let relocationsBeforeCancellation = coordinator.relocationCount
        var requestedCancellation = false
        try require(coordinator.requestVisit(.explicitPreview), "Cancellation fixture was rejected")
        let cancellationDeadline = ProcessInfo.processInfo.systemUptime + 20
        while coordinator.isActive {
            maximumBufferedFrames = max(maximumBufferedFrames, renderer.bufferedFrameCount)
            observeUpperPlacement(
                coordinator: coordinator,
                provider: provider,
                desktop: desktop,
                menuSafe: &ledgeWasMenuSafe,
                clickTransparent: &ledgeWasClickTransparent,
                focusPassive: &focusStayedPassive
            )
            if !requestedCancellation,
               coordinator.relocationCount > relocationsBeforeCancellation {
                requestedCancellation = true
                coordinator.reconcile(policyAllowsVisit: false, displaySize: renderer.displaySize)
            }
            try await waitStep(
                before: cancellationDeadline,
                detail: "phase=\(coordinator.phase) habitat=\(activeHabitat) markers=\(markerCount) invalidation=\(lastInvalidation) trace=\(markerTrace)"
            )
        }

        try require(requestedCancellation, "The cancellation fixture never reached the upper habitat")
        try require(coordinator.cancellationCount > 0, "Policy cancellation was not recorded")
        try require(desktop.effectiveOrigin.distance(to: initialOrigin) < 0.001,
                    "Cancellation did not restore the floor origin")
        try require(desktop.savedPlacement == savedHome, "Cancellation overwrote the saved home")
        try require(!desktop.panel.ignoresMouseEvents, "Cancellation did not restore click-through")
        try require(!renderer.hasActiveDisplayLink && !renderer.isAnimating,
                    "A completed habitat visit left active rendering work")
        try require(ledgeWasMenuSafe, "No upper placement was proven inside menu-safe geometry")
        try require(ledgeWasClickTransparent, "The visible upper visit was not mouse-transparent")
        try require(focusStayedPassive && !desktop.panel.isKeyWindow && !desktop.panel.isMainWindow,
                    "The habitat panel acquired application focus")
        try require(hiddenEventCount == 4 && !markerOutsideExpectedEndpoint,
                    "Cross-habitat movement used \(hiddenEventCount) semantic hidden endpoints; expected four: \(markerTrace)")
        try require(activeHabitat == "desktop", "Playback context was not restored to desktop")
        let crossHabitatHiddenEndpoints = hiddenEventCount
        try require(observedInterruptionMarkers == expectedInterruptionMarkers,
                    "Native playback did not deliver every declared habitat interruption marker; missing \(expectedInterruptionMarkers.subtracting(observedInterruptionMarkers).sortedDescriptions)")
        try require(maximumBufferedFrames <= package.resourceBudget.maxBufferedFrames,
                    "Habitat playback exceeded its decoded-frame buffer budget")

        // Cancelling while floorExit is still visible must let that authored
        // phrase reach hidden, reverse locally, and finish without moving the
        // host to an upper surface or leaving click-through latched on.
        let relocationsBeforeEarlyCancellation = coordinator.relocationCount
        let cancellationsBeforeEarlyCancellation = coordinator.cancellationCount
        try require(coordinator.requestVisit(.explicitPreview),
                    "Pre-relocation cancellation fixture was rejected")
        coordinator.reconcile(policyAllowsVisit: false, displaySize: renderer.displaySize)
        let earlyCancellationDeadline = ProcessInfo.processInfo.systemUptime + 10
        while coordinator.isActive {
            maximumBufferedFrames = max(maximumBufferedFrames, renderer.bufferedFrameCount)
            try await waitStep(
                before: earlyCancellationDeadline,
                detail: "early-cancel phase=\(coordinator.phase) habitat=\(activeHabitat) markers=\(markerCount) trace=\(markerTrace)"
            )
        }
        let earlyCancellationRelocationDelta = coordinator.relocationCount - relocationsBeforeEarlyCancellation
        let earlyCancellationHiddenEndpoints = hiddenEventCount - crossHabitatHiddenEndpoints
        try require(coordinator.cancellationCount == cancellationsBeforeEarlyCancellation + 1,
                    "Pre-relocation cancellation was not recorded exactly once")
        try require(earlyCancellationRelocationDelta == 0,
                    "Pre-relocation cancellation moved the host between habitats")
        try require(earlyCancellationHiddenEndpoints == 1 && !markerOutsideExpectedEndpoint,
                    "Pre-relocation cancellation did not reverse at the exact hidden floor endpoint")
        try require(desktop.effectiveOrigin.distance(to: initialOrigin) < 0.001,
                    "Pre-relocation cancellation changed the floor origin")
        try require(desktop.savedPlacement == savedHome,
                    "Pre-relocation cancellation overwrote the saved home")
        try require(!desktop.panel.ignoresMouseEvents,
                    "Pre-relocation cancellation left click-through enabled")
        try require(activeHabitat == "desktop" && !renderer.isAnimating && !renderer.hasActiveDisplayLink,
                    "Pre-relocation cancellation did not settle in the desktop context")

        // Model a visible safe-area shrink after the pet has settled above the
        // floor. The real host callbacks must still admit the stationary exit;
        // otherwise the renderer accepts a queued request that can never emit
        // its terminal marker and habitat mode remains latched forever.
        let relocationsBeforeTopologyChange = coordinator.relocationCount
        let cancellationsBeforeTopologyChange = coordinator.cancellationCount
        var visibleTopologyChangeInjected = false
        try require(coordinator.requestVisit(.explicitPreview),
                    "Visible topology-change fixture was rejected")
        let topologyChangeDeadline = ProcessInfo.processInfo.systemUptime + 20
        while coordinator.isActive {
            maximumBufferedFrames = max(maximumBufferedFrames, renderer.bufferedFrameCount)
            observeUpperPlacement(
                coordinator: coordinator,
                provider: provider,
                desktop: desktop,
                menuSafe: &ledgeWasMenuSafe,
                clickTransparent: &ledgeWasClickTransparent,
                focusPassive: &focusStayedPassive
            )
            if !visibleTopologyChangeInjected,
               case .edgeLook(cancelRequested: false) = coordinator.phase,
               let screen = desktop.panel.screen {
                let previousSafeFrame = try require(
                    topologyGate.safeVisibleFrame(on: screen),
                    "Topology-change fixture could not derive current safe geometry"
                )
                try require(previousSafeFrame.contains(desktop.panel.frame),
                            "Topology-change fixture did not begin in safe geometry")
                topologyGate.additionalTopInset = max(
                    1,
                    screen.frame.maxY - screen.safeAreaInsets.top
                        - desktop.panel.frame.maxY + 1
                )
                let changedSafeFrame = try require(
                    topologyGate.safeVisibleFrame(on: screen),
                    "Topology-change fixture could not derive changed safe geometry"
                )
                try require(!changedSafeFrame.contains(desktop.panel.frame),
                            "Topology-change fixture did not invalidate upper containment")
                visibleTopologyChangeInjected = true
                topologyGate.isAvailable = false
                coordinator.reconcile(policyAllowsVisit: true, displaySize: renderer.displaySize)
            }
            try await waitStep(
                before: topologyChangeDeadline,
                detail: "topology-change phase=\(coordinator.phase) habitat=\(activeHabitat) markers=\(markerCount) trace=\(markerTrace)"
            )
        }
        topologyGate.isAvailable = true
        try require(visibleTopologyChangeInjected,
                    "Visible topology-change fixture never reached a stable upper pose")
        try require(coordinator.relocationCount == relocationsBeforeTopologyChange + 2,
                    "Visible topology-change recovery did not make one round trip")
        try require(coordinator.cancellationCount == cancellationsBeforeTopologyChange + 1,
                    "Visible topology change was not recorded exactly once")
        try require(desktop.effectiveOrigin.distance(to: initialOrigin) < 0.001,
                    "Visible topology-change recovery did not restore the floor origin")
        try require(desktop.savedPlacement == savedHome,
                    "Visible topology-change recovery overwrote the saved home")
        try require(!desktop.panel.ignoresMouseEvents,
                    "Visible topology-change recovery left click-through enabled")
        try require(activeHabitat == "desktop" && !renderer.isAnimating && !renderer.hasActiveDisplayLink,
                    "Visible topology-change recovery did not settle in the desktop context")

        let quietBefore = ResourceSnapshot(renderer: renderer, desktop: desktop)
        try await Task.sleep(for: .seconds(1))
        let quietAfter = ResourceSnapshot(renderer: renderer, desktop: desktop)
        try require(quietAfter.stayedQuiet(since: quietBefore),
                    "A completed habitat visit continued submitting frames, receiving display-link callbacks, or moving the window")

        return HabitatReport(
            automaticGateDefaultedOff: true,
            completedVisits: Int(coordinator.completedVisitCount),
            cancellations: Int(coordinator.cancellationCount),
            relocations: Int(coordinator.relocationCount),
            semanticHiddenEndpoints: crossHabitatHiddenEndpoints,
            preRelocationCancellationCompleted: true,
            preRelocationCancellationRelocationDelta: Int(earlyCancellationRelocationDelta),
            preRelocationCancellationHiddenEndpoints: earlyCancellationHiddenEndpoints,
            visibleTopologyChangeRecovered: visibleTopologyChangeInjected,
            markerCount: markerCount,
            menuSafeUpperPlacement: ledgeWasMenuSafe,
            clickTransparentVisit: ledgeWasClickTransparent,
            focusStayedPassive: focusStayedPassive,
            actualFloorOriginRestored: desktop.effectiveOrigin.distance(to: initialOrigin) < 0.001,
            savedHomePreserved: desktop.savedPlacement == savedHome,
            clickThroughRestored: !desktop.panel.ignoresMouseEvents,
            frameClockStopped: !renderer.hasActiveDisplayLink,
            declaredInterruptionMarkers: expectedInterruptionMarkers.count,
            observedInterruptionMarkers: observedInterruptionMarkers.count,
            allDeclaredInterruptionMarkersObserved: observedInterruptionMarkers == expectedInterruptionMarkers,
            maximumBufferedFrames: maximumBufferedFrames,
            configuredFrameBufferLimit: package.resourceBudget.maxBufferedFrames,
            bufferUnderruns: renderer.bufferUnderrunCount - resourceStart.bufferUnderruns,
            injectedEffectFailureCases: recoveryAudit.effectFailureCases,
            allInjectedEffectFailuresRecovered: true,
            recoveryStopAborted: recoveryAudit.recoveryStopAborted,
            settledObservationSeconds: 1,
            settledSubmittedFrameDelta: quietAfter.submittedFrames - quietBefore.submittedFrames,
            settledDisplayLinkCallbackDelta: quietAfter.displayLinkCallbacks - quietBefore.displayLinkCallbacks,
            settledWindowMovementDelta: quietAfter.windowMovements - quietBefore.windowMovements,
            physicalHardwareMatrixComplete: false
        )
    }

    private static func auditCoordinatorFailures(
        package: CharacterPackage,
        content: HabitatVisitContent,
        topology: HabitatTopology
    ) async throws -> (effectFailureCases: Int, recoveryStopAborted: Bool) {
        for failure in InjectedHabitatFailure.allCases {
            let fixture = try CoordinatorFailureFixture(
                package: package, content: content, topology: topology, failure: failure
            )
            try await fixture.runToCompletion()
            try require(!fixture.coordinator.isActive && !fixture.host.isActive,
                        "Injected \(failure.rawValue) failure left habitat state active")
            try require(fixture.activityChanges == [true, false],
                        "Injected \(failure.rawValue) failure did not publish one balanced activity transition")
            try require(fixture.host.recoveryCount > 0 && fixture.host.finishCount == 1,
                        "Injected \(failure.rawValue) failure did not recover and finish exactly once")
            try require(fixture.playbackHabitat == "desktop",
                        "Injected \(failure.rawValue) failure did not restore desktop playback context")
        }

        let stopped = try CoordinatorFailureFixture(
            package: package, content: content, topology: topology, failure: .relocation
        )
        try stopped.start()
        try await stopped.deliverCurrentEndpoint()
        try require(stopped.coordinator.isActive && stopped.host.isActive,
                    "Recovery-stop fixture never entered floor recovery")
        stopped.host.isInvisible = true
        stopped.coordinator.cancel(.stopped)
        let recoveryStopAborted = !stopped.coordinator.isActive && !stopped.host.isActive
            && stopped.host.abortCount == 1 && stopped.activityChanges == [true, false]
        try require(recoveryStopAborted,
                    "Stopping during floor recovery did not use the invisible host abort")
        return (InjectedHabitatFailure.allCases.count, recoveryStopAborted)
    }

    private static func observeUpperPlacement(
        coordinator: PetHabitatCoordinator,
        provider: ScreenHabitatProvider,
        desktop: PetWindowController,
        menuSafe: inout Bool,
        clickTransparent: inout Bool,
        focusPassive: inout Bool
    ) {
        focusPassive = focusPassive && !desktop.panel.isKeyWindow && !desktop.panel.isMainWindow
        guard coordinator.relocationCount % 2 == 1,
              let topology = provider.currentTopology() else { return }
        let frame = desktop.panel.frame
        menuSafe = menuSafe || topology.surfaces.contains { surface in
            [.topShelf, .notchLeft, .notchRight].contains(surface.id.kind)
                && surface.safeVisualBounds.contains(frame)
                && topology.displays.first(where: { $0.displayID == surface.id.displayID })
                    .map { $0.safeVisibleFrame.contains(frame) } == true
        }
        clickTransparent = clickTransparent || desktop.panel.ignoresMouseEvents
    }

    private static func waitStep(before deadline: TimeInterval, detail: String) async throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw HabitatFailure("Timed out waiting for finite habitat playback: \(detail)")
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HabitatFailure(message) }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HabitatFailure(message) }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

private struct HabitatReport: Encodable {
    let automaticGateDefaultedOff: Bool
    let completedVisits: Int
    let cancellations: Int
    let relocations: Int
    let semanticHiddenEndpoints: Int
    let preRelocationCancellationCompleted: Bool
    let preRelocationCancellationRelocationDelta: Int
    let preRelocationCancellationHiddenEndpoints: Int
    let visibleTopologyChangeRecovered: Bool
    let markerCount: Int
    let menuSafeUpperPlacement: Bool
    let clickTransparentVisit: Bool
    let focusStayedPassive: Bool
    let actualFloorOriginRestored: Bool
    let savedHomePreserved: Bool
    let clickThroughRestored: Bool
    let frameClockStopped: Bool
    let declaredInterruptionMarkers: Int
    let observedInterruptionMarkers: Int
    let allDeclaredInterruptionMarkersObserved: Bool
    let maximumBufferedFrames: Int
    let configuredFrameBufferLimit: Int
    let bufferUnderruns: UInt64
    let injectedEffectFailureCases: Int
    let allInjectedEffectFailuresRecovered: Bool
    let recoveryStopAborted: Bool
    let settledObservationSeconds: Double
    let settledSubmittedFrameDelta: UInt64
    let settledDisplayLinkCallbackDelta: UInt64
    let settledWindowMovementDelta: UInt64
    let physicalHardwareMatrixComplete: Bool
}

private enum InjectedHabitatFailure: String, CaseIterable {
    case topology
    case relocation
    case upperContext
    case ledgeEntryPlayback
    case floorRestore
    case floorContext
    case floorReentryPlayback
}

@MainActor
private final class CoordinatorFailureFixture {
    let host: InjectedHabitatHost
    private let package: CharacterPackage
    private let content: HabitatVisitContent
    private let topology: HabitatTopology
    private let failure: InjectedHabitatFailure
    private var poseID: String
    private var lastIntentID: String?
    private var lastTimeline: CharacterTimeline?
    private var failureConsumed = false
    private var topologyAvailable = true
    private var floorContextCount = 0
    private(set) var playbackHabitat = "desktop"
    private(set) var activityChanges: [Bool] = []

    lazy var coordinator = PetHabitatCoordinator(
        configuration: .init(content: content),
        desktop: host,
        currentTopology: { [weak self] in
            guard let self, topologyAvailable else { return nil }
            return topology
        },
        setPlaybackHabitat: { [weak self] habitatID, preservingPoseID in
            self?.setPlaybackHabitat(habitatID, preserving: preservingPoseID) == true
        },
        previewIntent: { [weak self] intentID in self?.preview(intentID) },
        performIntent: { [weak self] intentID in self?.perform(intentID) == true },
        resetScene: {},
        onActivityChanged: { [weak self] active in self?.activityChanges.append(active) }
    )

    init(
        package: CharacterPackage,
        content: HabitatVisitContent,
        topology: HabitatTopology,
        failure: InjectedHabitatFailure
    ) throws {
        self.package = package
        self.content = content
        self.topology = topology
        self.failure = failure
        poseID = content.floorPoseID
        guard let source = topology.surfaces.first(where: { $0.id.kind == .floor }) else {
            throw HabitatFailure("Failure fixture has no floor surface")
        }
        host = InjectedHabitatHost(
            displayID: source.id.displayID,
            windowSize: topology.artGeometry.portalWindowSize,
            failure: failure
        )
    }

    func start() throws {
        guard coordinator.requestVisit(.explicitPreview) else {
            throw HabitatFailure("Injected \(failure.rawValue) fixture could not start")
        }
    }

    func runToCompletion() async throws {
        try start()
        var delivered = 0
        while coordinator.isActive, delivered < 12 {
            if failure == .topology, lastIntentID == content.floorExitIntentID {
                topologyAvailable = false
            }
            try await deliverCurrentEndpoint()
            delivered += 1
        }
        guard !coordinator.isActive else {
            throw HabitatFailure(
                "Injected \(failure.rawValue) fixture stalled after \(delivered) endpoints"
            )
        }
    }

    func deliverCurrentEndpoint() async throws {
        guard let intentID = lastIntentID, let timeline = lastTimeline,
              timeline.frameCount > 0 else {
            throw HabitatFailure("Injected \(failure.rawValue) fixture has no expected playback")
        }
        lastIntentID = nil
        lastTimeline = nil
        let markerID = [content.floorExitIntentID, content.ledgeExitIntentID].contains(intentID)
            ? content.fullyHiddenEventID : content.settledMarkerID
        let kind: CharacterPlaybackMarker.Kind = [content.floorExitIntentID, content.ledgeExitIntentID]
            .contains(intentID) ? .semanticEvent : .interruption
        let markers = timeline.markers(atFrame: timeline.frameCount - 1)
        guard let marker = markers.first(where: { $0.id == markerID && $0.kind == kind }),
              let markerPose = marker.poseID else {
            throw HabitatFailure("Injected \(failure.rawValue) fixture lacks its terminal marker")
        }
        poseID = markerPose
        coordinator.receive(marker)
        // Relocation/context handoffs deliberately defer their next playback to
        // the next main-actor turn; wait for that bounded continuation.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(1))
    }

    private func setPlaybackHabitat(_ habitatID: String, preserving pose: String?) -> Bool {
        if habitatID == HabitatSurfaceKind.floor.rawValue {
            floorContextCount += 1
            if failure == .floorContext, floorContextCount > 1, !failureConsumed {
                failureConsumed = true
                return false
            }
        } else if habitatID != "desktop", failure == .upperContext, !failureConsumed {
            failureConsumed = true
            return false
        }
        playbackHabitat = habitatID
        if let pose { poseID = pose }
        return true
    }

    private func preview(_ intentID: String) -> CharacterTimeline? {
        let context = CharacterPlaybackContext(
            capabilityIDs: Set(package.capabilities),
            habitatID: playbackHabitat,
            orientationID: "upright"
        )
        guard let plan = try? package.plan(for: intentID, from: poseID, context: context),
              let timeline = try? CharacterTimeline(package: package, plan: plan) else { return nil }
        lastTimeline = timeline
        return timeline
    }

    private func perform(_ intentID: String) -> Bool {
        if failure == .ledgeEntryPlayback, intentID == content.ledgeEntryIntentID,
           !failureConsumed {
            failureConsumed = true
            return false
        }
        if failure == .floorReentryPlayback, intentID == content.floorReentryIntentID {
            return false
        }
        lastIntentID = intentID
        return true
    }
}

@MainActor
private final class InjectedHabitatHost: PetHabitatHosting {
    let habitatVisitWindowSize: CGSize
    let habitatVisitSourceDisplayID: UUID?
    private let failure: InjectedHabitatFailure
    private var failureConsumed = false
    private var tokenGeneration: UInt64 = 0
    private var relocated = false
    private var restored = false
    private(set) var isActive = false
    private(set) var recoveryCount = 0
    private(set) var finishCount = 0
    private(set) var abortCount = 0
    var isInvisible = false

    init(displayID: UUID, windowSize: CGSize, failure: InjectedHabitatFailure) {
        habitatVisitSourceDisplayID = displayID
        habitatVisitWindowSize = windowSize
        self.failure = failure
    }

    func beginHabitatVisit() -> PetHabitatVisitToken? {
        guard !isActive, let displayID = habitatVisitSourceDisplayID else { return nil }
        tokenGeneration &+= 1
        isActive = true
        relocated = false
        restored = false
        return PetHabitatVisitToken(
            generation: tokenGeneration,
            sourceDisplayID: displayID,
            windowSize: habitatVisitWindowSize
        )
    }

    func relocateHabitatVisit(
        _ token: PetHabitatVisitToken,
        to surface: HabitatSurface,
        permit: PetHabitatRelocationPermit
    ) -> Bool {
        guard isActive else { return false }
        if failure == .relocation, !failureConsumed {
            failureConsumed = true
            return false
        }
        relocated = true
        return true
    }

    func restoreHabitatVisitToFloor(
        _ token: PetHabitatVisitToken,
        permit: PetHabitatRelocationPermit
    ) -> Bool {
        guard isActive, relocated else { return false }
        if failure == .floorRestore, !failureConsumed {
            failureConsumed = true
            return false
        }
        restored = true
        return true
    }

    func recoverHabitatVisitToFloor(
        _ token: PetHabitatVisitToken,
        permit: PetHabitatRelocationPermit
    ) -> Bool {
        guard isActive else { return false }
        recoveryCount += 1
        restored = true
        return true
    }

    func finishHabitatVisit(_ token: PetHabitatVisitToken) -> Bool {
        guard isActive, !relocated || restored else { return false }
        isActive = false
        finishCount += 1
        return true
    }

    func abortHabitatVisitWhileInvisible(_ token: PetHabitatVisitToken) -> Bool {
        guard isActive, isInvisible else { return false }
        isActive = false
        abortCount += 1
        return true
    }
}

private struct MarkerIdentity: Hashable {
    let clipID: String
    let frameIndex: Int
    let id: String

    var description: String { "\(clipID)#\(frameIndex)#\(id)" }
}

private extension Set where Element == MarkerIdentity {
    var sortedDescriptions: [String] { map(\.description).sorted() }
}

private struct ResourceSnapshot {
    let submittedFrames: UInt64
    let displayLinkCallbacks: UInt64
    let bufferUnderruns: UInt64
    let windowMovements: UInt64
    let animating: Bool
    let displayLinkActive: Bool

    @MainActor
    init(renderer: PetRenderView, desktop: PetWindowController) {
        submittedFrames = renderer.submittedFrameCount
        displayLinkCallbacks = renderer.displayLinkCallbackCount
        bufferUnderruns = renderer.bufferUnderrunCount
        windowMovements = desktop.movementTickCount
        animating = renderer.isAnimating
        displayLinkActive = renderer.hasActiveDisplayLink
    }

    func stayedQuiet(since earlier: Self) -> Bool {
        submittedFrames == earlier.submittedFrames
            && displayLinkCallbacks == earlier.displayLinkCallbacks
            && windowMovements == earlier.windowMovements
            && !animating
            && !displayLinkActive
    }
}

private struct HabitatFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
private final class TopologyGate {
    var isAvailable = true
    var additionalTopInset: CGFloat = 0

    func safeVisibleFrame(on screen: NSScreen) -> CGRect? {
        guard let insets = HabitatInsets(
            top: screen.safeAreaInsets.top + additionalTopInset,
            left: screen.safeAreaInsets.left,
            bottom: screen.safeAreaInsets.bottom,
            right: screen.safeAreaInsets.right
        ) else { return nil }
        return HabitatScreenSnapshot.deriveSafeVisibleFrame(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: insets
        )
    }
}
