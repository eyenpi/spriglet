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
        let content = try require(habitatContent(), "Habitat content identifiers are malformed")
        let scale = renderer.displaySize.width / 96
        let artGeometry = try require(HabitatPortalArtGeometry.acorn(scale: scale), "Invalid display scale")
        let provider = ScreenHabitatProvider(artGeometry: artGeometry)
        let desktop = PetWindowController(
            contentView: renderer,
            size: renderer.displaySize,
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

        var coordinator: PetHabitatCoordinator!
        coordinator = PetHabitatCoordinator(
            configuration: .init(content: content),
            desktop: desktop,
            currentTopology: { provider.currentTopology() },
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
            timeline.rootOffsets.allSatisfy { $0 == .zero }
        }
        renderer.onFrame = { snapshot in
            guard snapshot.rootOffsetPoints == .zero else { return false }
            renderer.setImageOffset(.zero)
            return true
        }
        renderer.onPlaybackMarker = { marker in
            markerCount += 1
            markerTrace.append("\(marker.clipID.rawValue):\(marker.id):\(marker.poseID ?? "nil")")
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

        try require(coordinator.completedVisitCount == 1, "The finite visit did not complete exactly once")
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

        return HabitatReport(
            automaticGateDefaultedOff: true,
            completedVisits: Int(coordinator.completedVisitCount),
            cancellations: Int(coordinator.cancellationCount),
            relocations: Int(coordinator.relocationCount),
            semanticHiddenEndpoints: hiddenEventCount,
            markerCount: markerCount,
            menuSafeUpperPlacement: ledgeWasMenuSafe,
            clickTransparentVisit: ledgeWasClickTransparent,
            focusStayedPassive: focusStayedPassive,
            actualFloorOriginRestored: desktop.effectiveOrigin.distance(to: initialOrigin) < 0.001,
            savedHomePreserved: desktop.savedPlacement == savedHome,
            clickThroughRestored: !desktop.panel.ignoresMouseEvents,
            frameClockStopped: !renderer.hasActiveDisplayLink,
            physicalHardwareMatrixComplete: false
        )
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
                    .map { frame.maxY <= $0.visibleFrame.maxY } == true
        }
        clickTransparent = clickTransparent || desktop.panel.ignoresMouseEvents
    }

    private static func habitatContent() -> HabitatVisitContent? {
        HabitatVisitContent(
            floorExitIntentID: "habitat.floorExit",
            ledgeEntryIntentID: "habitat.peekIn",
            edgeLookIntentID: "habitat.edgeLook",
            dangleIntentID: "habitat.dangle",
            pullUpIntentID: "habitat.pullUp",
            ledgeExitIntentID: "habitat.ledgeExit",
            floorReentryIntentID: "habitat.floorReentry",
            hiddenPoseID: "portal.hidden",
            ledgePoseID: "ledge.peek",
            hangingPoseID: "ledge.hang",
            floorPoseID: "ready",
            fullyHiddenEventID: "fullyHidden",
            settledMarkerID: "settled"
        )
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
    let markerCount: Int
    let menuSafeUpperPlacement: Bool
    let clickTransparentVisit: Bool
    let focusStayedPassive: Bool
    let actualFloorOriginRestored: Bool
    let savedHomePreserved: Bool
    let clickThroughRestored: Bool
    let frameClockStopped: Bool
    let physicalHardwareMatrixComplete: Bool
}

private struct HabitatFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
