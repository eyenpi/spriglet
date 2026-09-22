import AppKit
import Foundation
import SprigletCore

@main
@MainActor
final class ReactiveCheck: NSObject, NSApplicationDelegate {
    private var task: Task<Void, Never>?
    private var exitCode: Int32 = 0

    static func main() {
        let application = NSApplication.shared
        let delegate = ReactiveCheck()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        exit(delegate.exitCode)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        task = Task {
            do {
                let report = try await Self.runChecks()
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                self.exitCode = 1
                fputs("Reactive validation failed: \(error.localizedDescription)\n", stderr)
            }
            NSApp.terminate(nil)
        }
    }

    private static func runChecks() async throws -> ReactiveReport {
        guard let resources = Bundle.main.resourceURL else {
            throw ReactiveFailure("Validation bundle resources are missing")
        }
        let candidate = resources.appendingPathComponent("ReactiveAcorn")
        let legacy = resources.appendingPathComponent("LegacyAcorn")
        let coordinator = try verifyCoordinator(resources: candidate)
        let stableBoundary = try await verifyStableBoundaryRedirect(resources: candidate)
        let coldHold = try await verifyColdHold(resources: candidate)
        let alert = try await verifyAlertRedirectAndHeldInput(resources: candidate)
        let directed = try await verifyDirectedRedirect(resources: candidate)
        let airborne = try await verifyAirborneRedirect(resources: candidate)
        let legacyFrames = try await verifyLegacyFallback(resources: legacy)
        return ReactiveReport(
            coordinator: coordinator,
            stableBoundaryFrames: stableBoundary,
            coldHoldFrames: coldHold,
            alertFrames: alert.frames,
            alertMarkers: alert.markers,
            directedFrames: directed.frames,
            directedMarkers: directed.markers,
            airborneFrames: airborne.frames,
            airborneMarkers: airborne.markers,
            legacyFrames: legacyFrames
        )
    }

    private static func verifyCoordinator(resources: URL) throws -> CoordinatorReport {
        let package = try CharacterPackage.decode(Data(contentsOf:
            resources.appendingPathComponent("character.json")))
        let policy = try ReactiveBehaviorPolicy.decode(Data(contentsOf:
            resources.appendingPathComponent("reactive/behavior.json")))
        guard policy.characterIdentifier == package.identifier,
              package.capabilities.contains("reactiveDodge") else {
            throw ReactiveFailure("Shipping reaction policy does not match the character package")
        }

        let alertProbe = try CoordinatorProbe(package: package, policy: policy, entropy: .max)
        guard let alert = alertProbe.coordinator.receive(world: reactionWorld(at: 1)),
              alert.intentID == "reactive.alert" else {
            throw ReactiveFailure("Deterministic common reaction did not select the local alert")
        }

        let dodgeProbe = try CoordinatorProbe(package: package, policy: policy, entropy: 0)
        guard let dodge = dodgeProbe.coordinator.receive(world: reactionWorld(at: 1)),
              dodge.intentID == "dodge.right" else {
            throw ReactiveFailure("Deterministic rare reaction did not choose the safe away route")
        }

        let constrainedProbe = try CoordinatorProbe(package: package, policy: policy, entropy: 0)
        constrainedProbe.canFit = false
        guard let constrained = constrainedProbe.coordinator.receive(world: reactionWorld(at: 1)),
              constrained.intentID == "reactive.alert" else {
            throw ReactiveFailure("Insufficient root-motion space did not fall back to alert")
        }

        let budgetProbe = try CoordinatorProbe(package: package, policy: policy, entropy: 0)
        guard budgetProbe.coordinator.receive(world: reactionWorld(at: 1))?.intentID == "dodge.right" else {
            throw ReactiveFailure("Accepted dodge did not start")
        }
        _ = budgetProbe.coordinator.receive(world: departureWorld(at: 1.1))
        guard let budgetFallback = budgetProbe.coordinator.receive(world: reactionWorld(at: 1.2)),
              budgetFallback.intentID == "reactive.alert" else {
            throw ReactiveFailure("Accepted execution did not consume its reaction token and cooldown")
        }
        _ = budgetProbe.coordinator.receive(world: departureWorld(at: 30.9))
        guard let cooldownFallback = budgetProbe.coordinator.receive(world: reactionWorld(at: 31)),
              cooldownFallback.intentID == "reactive.alert" else {
            throw ReactiveFailure("Dodge cooldown did not outlive its replenished reaction token")
        }
        _ = budgetProbe.coordinator.receive(world: departureWorld(at: 35.9))
        guard let cooldownRecovery = budgetProbe.coordinator.receive(world: reactionWorld(at: 36)),
              cooldownRecovery.intentID == "dodge.right" else {
            throw ReactiveFailure("Dodge did not recover after its cooldown and token interval")
        }

        let rejectedProbe = try CoordinatorProbe(package: package, policy: policy, entropy: 0)
        rejectedProbe.accepts = false
        guard rejectedProbe.coordinator.receive(world: reactionWorld(at: 1)) == nil else {
            throw ReactiveFailure("A rejected renderer request was reported as executed")
        }
        _ = rejectedProbe.coordinator.receive(world: departureWorld(at: 1.1))
        rejectedProbe.accepts = true
        guard let retry = rejectedProbe.coordinator.receive(world: reactionWorld(at: 1.2)),
              retry.intentID == "dodge.right" else {
            throw ReactiveFailure("A rejected execution consumed reaction budget")
        }

        let suppressionProbe = try CoordinatorProbe(package: package, policy: policy, entropy: 0)
        suppressionProbe.accepts = false
        _ = suppressionProbe.coordinator.receive(world: reactionWorld(at: 1))
        let attemptsBeforeSuppression = suppressionProbe.attemptedIntents.count
        suppressionProbe.coordinator.suppressCurrentApproach()
        suppressionProbe.accepts = true
        let resurfaced = suppressionProbe.coordinator.receive(world: reactionWorld(at: 1.1))
        guard resurfaced == nil,
              suppressionProbe.attemptedIntents.count == attemptsBeforeSuppression else {
            throw ReactiveFailure("A direct-interaction suppression allowed the current approach to resurface")
        }

        return CoordinatorReport(
            policyMatched: true,
            commonIntent: alert.intentID,
            rareIntent: dodge.intentID,
            constrainedIntent: constrained.intentID,
            budgetFallbackIntent: budgetFallback.intentID,
            cooldownFallbackIntent: cooldownFallback.intentID,
            cooldownRecoveryIntent: cooldownRecovery.intentID,
            rejectedRetryIntent: retry.intentID,
            suppressedAttemptCount: suppressionProbe.attemptedIntents.count
        )
    }

    private static func reactionWorld(at seconds: TimeInterval) -> PetWorldSnapshot {
        pointerWorld(at: seconds, radialVelocity: 500, projectedDistance: 30, proximity: .near)
    }

    private static func departureWorld(at seconds: TimeInterval) -> PetWorldSnapshot {
        pointerWorld(at: seconds, radialVelocity: -100, projectedDistance: 90, proximity: .far)
    }

    private static func pointerWorld(
        at seconds: TimeInterval,
        radialVelocity: Double,
        projectedDistance: Double,
        proximity: PointerProximity
    ) -> PetWorldSnapshot {
        let timestamp = MonotonicTimestamp(seconds: seconds)!
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let sample = PointerSample(
            timestamp: timestamp,
            location: PointerPoint(x: bounds.minX, y: bounds.midY)!
        )
        let pointer = PointerPerception(
            latestSample: sample,
            velocity: PointerVector(dx: abs(radialVelocity), dy: 0),
            distanceToTarget: 60,
            radialVelocity: radialVelocity,
            approachSpeed: max(0, radialVelocity),
            projectedDistanceToTarget: projectedDistance,
            proximity: proximity
        )
        return PetWorldSnapshot(timestamp: timestamp, petBounds: bounds, pointer: pointer)
    }

    private static func verifyStableBoundaryRedirect(resources: URL) async throws -> Int {
        let host = try RenderHost(resources: resources)
        defer { host.close() }
        guard host.renderer.playIntent("dodge.left"), host.renderer.play(.react) else {
            throw ReactiveFailure("Direct petting was not accepted at the retained start pose")
        }
        try await waitUntil(label: "stable-boundary redirect", timeout: 12) {
            !host.renderer.isAnimating
        }
        try host.requireSettled(label: "stable-boundary redirect")
        guard !host.clips.contains(where: { $0.hasPrefix("reactive.") }),
              host.animationStates == [true, false], host.playbackStopCount == 2 else {
            throw ReactiveFailure("Stable-boundary redirect exposed a contextual frame or animation gap")
        }
        return host.frames.count
    }

    private static func verifyColdHold(resources: URL) async throws -> Int {
        let host = try RenderHost(resources: resources)
        defer { host.close() }
        guard host.renderer.playIntent("dodge.left") else {
            throw ReactiveFailure("The packaged dodge was rejected before the cold hold")
        }
        host.renderer.setInteractionHeld(true)
        try await Task.sleep(for: .milliseconds(150))
        guard host.frames.isEmpty, host.renderer.currentSnapshot == nil,
              !host.renderer.hasActiveDisplayLink else {
            throw ReactiveFailure("A cold interaction hold advanced the image/root pair")
        }
        host.renderer.setInteractionHeld(false)
        try await waitUntil(label: "cold interaction hold", timeout: 12) {
            !host.renderer.isAnimating
        }
        try host.requireSettled(label: "cold interaction hold")
        guard !host.frames.isEmpty else {
            throw ReactiveFailure("Cold-held playback did not resume from its first frame")
        }
        return host.frames.count
    }

    private static func verifyDirectedRedirect(resources: URL) async throws -> ScenarioReport {
        let host = try RenderHost(resources: resources)
        defer { host.close() }
        var requestedPet = false
        host.renderer.onPlaybackMarker = { marker in
            host.record(marker)
            guard marker.kind == .interruption, marker.id == "safeToRedirect",
                  marker.poseID == "directed.left", !requestedPet else { return }
            requestedPet = true
            if !host.renderer.play(.react) {
                host.failure = "Direct petting was not accepted at the directed boundary"
            }
        }
        guard host.renderer.playIntent("dodge.left") else {
            throw ReactiveFailure("The packaged directed dodge was rejected")
        }
        try await waitUntil(label: "directed-boundary redirect", timeout: 12) {
            host.failure != nil || (requestedPet && !host.renderer.isAnimating)
        }
        if let failure = host.failure { throw ReactiveFailure(failure) }
        guard requestedPet,
              host.clips.contains("reactive.turn.left"),
              host.clips.contains("reactive.abort.left"),
              !host.clips.contains("reactive.hop.left") else {
            throw ReactiveFailure("Directed-boundary petting did not use its authored abort route")
        }
        try host.requireSettled(label: "directed redirect")
        guard host.animationStates == [true, false], host.playbackStopCount == 2 else {
            throw ReactiveFailure("Directed redirect exposed an animation gap or stale playback")
        }
        return host.report
    }

    private static func verifyAlertRedirectAndHeldInput(resources: URL) async throws -> ScenarioReport {
        let host = try RenderHost(resources: resources)
        defer { host.close() }
        var requestedPet = false
        var heldSnapshot: SampleTimelineSnapshot?
        host.renderer.onPlaybackMarker = { marker in
            host.record(marker)
            guard marker.kind == .interruption, marker.id == "safeToRedirect",
                  marker.poseID == "alert", !requestedPet else { return }
            requestedPet = true
            heldSnapshot = host.renderer.currentSnapshot
            host.renderer.setInteractionHeld(true)
            guard host.renderer.play(.react) else {
                host.failure = "Direct petting was not accepted at the alert boundary"
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard host.renderer.currentSnapshot == heldSnapshot,
                      !host.renderer.hasActiveDisplayLink else {
                    host.failure = "Interaction hold did not freeze the exact alert image/root pair"
                    host.renderer.setInteractionHeld(false)
                    return
                }
                host.renderer.setInteractionHeld(false)
            }
        }

        guard host.renderer.playIntent("dodge.left") else {
            throw ReactiveFailure("The packaged dodge.left intent was rejected")
        }
        try await waitUntil(label: "alert-boundary redirect", timeout: 12) {
            host.failure != nil || (requestedPet && !host.renderer.isAnimating)
        }
        if let failure = host.failure { throw ReactiveFailure(failure) }
        guard requestedPet,
              host.clips.contains("reactive.alert"),
              host.clips.contains("reactive.dismiss"),
              !host.clips.contains("reactive.turn.left"),
              !host.clips.contains("reactive.hop.left") else {
            throw ReactiveFailure("Alert-boundary petting launched a later dodge phase")
        }
        try host.requireSettled(label: "alert redirect")
        guard host.animationStates == [true, false], host.playbackStopCount == 2 else {
            throw ReactiveFailure("Alert redirect exposed an animation gap or incorrect playback ownership")
        }
        return host.report
    }

    private static func verifyAirborneRedirect(resources: URL) async throws -> ScenarioReport {
        let host = try RenderHost(resources: resources)
        defer { host.close() }
        var requestedPet = false
        var requestFramePosition = 0
        host.renderer.onFrame = { snapshot in
            host.record(snapshot)
            if snapshot.clip.rawValue == "reactive.hop.left",
               (8...16).contains(snapshot.clipFrameIndex), !requestedPet {
                requestedPet = true
                requestFramePosition = host.clips.count
                guard host.renderer.play(.react) else {
                    host.failure = "Direct petting was not accepted during the hop"
                    return false
                }
                if host.renderer.playIntent("dodge.right", priority: .contextual) {
                    host.failure = "A contextual request displaced pending direct petting"
                    return false
                }
            }
            host.renderer.setImageOffset(CGPoint(
                x: snapshot.rootOffsetPoints.x, y: snapshot.rootOffsetPoints.y
            ))
            return true
        }
        host.renderer.onPlaybackMarker = { host.record($0) }

        guard host.renderer.playIntent("dodge.left") else {
            throw ReactiveFailure("The packaged airborne dodge was rejected")
        }
        do {
            try await waitUntil(label: "airborne redirect", timeout: 15) {
                host.failure != nil || (requestedPet && !host.renderer.isAnimating)
            }
        } catch {
            throw ReactiveFailure(
                "\(error.localizedDescription); requested=\(requestedPet), \(host.playbackDiagnostic)"
            )
        }
        if let failure = host.failure { throw ReactiveFailure(failure) }
        let framesAfterRequest = Array(host.frames.dropFirst(requestFramePosition))
        guard requestedPet,
              framesAfterRequest.contains(where: {
                  $0.clip.rawValue == "reactive.hop.left" && $0.clipFrameIndex == 25
              }),
              framesAfterRequest.contains(where: { $0.clip.rawValue == "reactive.brake.left" }),
              host.markers.contains(where: {
                  $0.id == "safeToRedirect" && $0.poseID == "landed.left"
              }) else {
            throw ReactiveFailure("Airborne petting redirected before the authored landing boundary")
        }
        guard Set(host.markerKeys).count == host.markerKeys.count else {
            throw ReactiveFailure("An authored marker was delivered more than once")
        }
        guard host.markers.filter({ $0.id == "safeToRedirect" }).allSatisfy({ $0.poseID != nil }) else {
            throw ReactiveFailure("A non-endpoint frame was treated as safe to redirect")
        }
        try host.requireSettled(label: "airborne redirect")
        guard host.animationStates == [true, false], host.playbackStopCount == 2 else {
            throw ReactiveFailure("Airborne redirect exposed an animation gap or stale playback")
        }
        return host.report
    }

    private static func verifyLegacyFallback(resources: URL) async throws -> Int {
        let host = try RenderHost(resources: resources)
        defer { host.close() }
        guard host.renderer.characterPackage != nil, host.renderer.manifest != nil,
              host.renderer.play(.react) else {
            throw ReactiveFailure("The schema-1/2 in-memory fallback was not playable")
        }
        try await waitUntil(label: "legacy fallback", timeout: 12) {
            !host.renderer.isAnimating
        }
        try host.requireSettled(label: "legacy fallback")
        guard host.frames.count > 0 else { throw ReactiveFailure("Legacy fallback submitted no frames") }
        return host.frames.count
    }

    private static func waitUntil(
        label: String,
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ReactiveFailure("Timed out waiting for \(label)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class RenderHost {
    let renderer: PetRenderView
    private let panel: NSPanel
    var frames: [SampleTimelineSnapshot] = []
    var markers: [CharacterPlaybackMarker] = []
    var animationStates: [Bool] = []
    var playbackStopCount = 0
    var failure: String?
    var clips: [String] { frames.map(\.clip.rawValue) }
    var markerKeys: [String] {
        markers.map { "\($0.kind.rawValue):\($0.clipID.rawValue):\($0.clipFrameIndex):\($0.id)" }
    }
    var playbackDiagnostic: String {
        let frame = renderer.currentSnapshot.map {
            "\($0.clip.rawValue):\($0.clipFrameIndex)"
        } ?? "none"
        return "frame=\(frame), animating=\(renderer.isAnimating), link=\(renderer.hasActiveDisplayLink), buffered=\(renderer.bufferedFrameCount)"
    }
    var report: ScenarioReport { .init(frames: frames.count, markers: markers.count) }

    init(resources: URL) throws {
        renderer = PetRenderView(frame: .zero, resourceDirectory: resources)
        guard renderer.assetError == nil, renderer.characterPackage != nil else {
            throw ReactiveFailure("Renderer rejected \(resources.lastPathComponent): \(renderer.assetError ?? "unknown error")")
        }
        let size = renderer.displaySize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = renderer
        panel.orderFrontRegardless()
        renderer.onPlaybackWillStart = { _ in true }
        renderer.onFrame = { [weak self] snapshot in
            guard let self else { return false }
            record(snapshot)
            renderer.setImageOffset(CGPoint(
                x: snapshot.rootOffsetPoints.x, y: snapshot.rootOffsetPoints.y
            ))
            return true
        }
        renderer.onAnimationStateChanged = { [weak self] in self?.animationStates.append($0) }
        renderer.onPlaybackStopped = { [weak self] in self?.playbackStopCount += 1 }
    }

    func record(_ snapshot: SampleTimelineSnapshot) { frames.append(snapshot) }
    func record(_ marker: CharacterPlaybackMarker) { markers.append(marker) }

    func requireSettled(label: String) throws {
        guard !renderer.isAnimating, !renderer.hasActiveDisplayLink,
              renderer.bufferedFrameCount == 0, renderer.activeRigAnimationCount == 0,
              renderer.currentPoseID == "ready" else {
            throw ReactiveFailure("\(label) left a frame clock, buffer, rig animation, or non-ready pose")
        }
    }

    func close() {
        renderer.setSuspended(true)
        panel.close()
    }
}

private struct ScenarioReport: Sendable {
    let frames: Int
    let markers: Int
}

private struct ReactiveReport: Encodable {
    let coordinator: CoordinatorReport
    let stableBoundaryFrames: Int
    let coldHoldFrames: Int
    let alertFrames: Int
    let alertMarkers: Int
    let directedFrames: Int
    let directedMarkers: Int
    let airborneFrames: Int
    let airborneMarkers: Int
    let legacyFrames: Int
}

private struct CoordinatorReport: Encodable {
    let policyMatched: Bool
    let commonIntent: String
    let rareIntent: String
    let constrainedIntent: String
    let budgetFallbackIntent: String
    let cooldownFallbackIntent: String
    let cooldownRecoveryIntent: String
    let rejectedRetryIntent: String
    let suppressedAttemptCount: Int
}

@MainActor
private final class CoordinatorProbe {
    private let state: CoordinatorProbeState
    let coordinator: ReactiveBehaviorCoordinator

    var canFit: Bool {
        get { state.canFit }
        set { state.canFit = newValue }
    }
    var accepts: Bool {
        get { state.accepts }
        set { state.accepts = newValue }
    }
    var attemptedIntents: [String] { state.attemptedIntents }

    init(package: CharacterPackage, policy: ReactiveBehaviorPolicy, entropy: UInt64) throws {
        let state = CoordinatorProbeState()
        self.state = state
        coordinator = try ReactiveBehaviorCoordinator(
            policy: policy,
            characterIdentifier: package.identifier,
            traits: .sprout,
            capabilityIDs: Set(package.capabilities),
            previewIntent: { intentID in
                try? CharacterTimeline(
                    package: package, intentID: intentID,
                    from: package.animationGraph.defaultPoseID,
                    context: CharacterPlaybackContext(habitatID: "desktop")
                )
            },
            canFitRootMotion: { _ in state.canFit },
            performIntent: { intentID in
                state.attemptedIntents.append(intentID)
                return state.accepts
            },
            entropy: { entropy }
        )
    }
}

@MainActor
private final class CoordinatorProbeState {
    var canFit = true
    var accepts = true
    var attemptedIntents: [String] = []
}

private struct ReactiveFailure: LocalizedError {
    let errorDescription: String?
    init(_ value: String) { errorDescription = value }
}
