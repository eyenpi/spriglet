import AppKit
import CryptoKit
import Darwin
import SprigletCore

/// A disposable native integration check. Building this target never runs it.
@main
enum PersonalityCheck {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        let incompatible = ["--probe", "--soak", "--sample-review", "--welcome-review", "--desktop-acceptance"]
        guard !incompatible.contains(where: arguments.contains) else {
            print("PersonalityCheck uses its own isolated runtime. Use only --output <report.json>.")
            exit(2)
        }
        let output = arguments.firstIndex(of: "--output").flatMap { index in
            index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = PersonalityRunner(output: output)
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}

private enum CheckStatus: String, Codable { case passed, failed, blocked }

private struct Check: Codable {
    let name: String
    let status: CheckStatus
    let detail: String
}

private struct BuildProvenance: Codable {
    let sourceSHA256: [String: String]
    let assetSHA256: [String: String]
    let swiftVersion: String
    let sdkVersion: String
    let architecture: String
    let compilerFlags: [String]
}

private struct EnvironmentEvidence: Encodable {
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let actualLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let actualReduceMotion: Bool
    let thermalState: Int
    let screens: [[Double]]
    let screenCount: Int

    @MainActor
    init() {
        actualReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        thermalState = ProcessInfo.processInfo.thermalState.rawValue
        screens = NSScreen.screens.map { screen in
            [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height,
             screen.visibleFrame.minX, screen.visibleFrame.minY, screen.visibleFrame.width,
             screen.visibleFrame.height, screen.backingScaleFactor, Double(screen.maximumFramesPerSecond)]
        }
        screenCount = screens.count
    }
}

private struct Snapshot: Codable {
    let submittedFrames: UInt64
    let displayLinkCallbacks: UInt64
    let movementApplications: UInt64
    let automaticActions: UInt64
    let completedRoutines: UInt64
    let bufferedFrames: Int
    let animating: Bool
    let displayLinkActive: Bool
    let scheduledBehavior: Bool
    let fireflyVisible: Bool
    let routine: String?
    let frame: Int?
    let effectiveOrigin: [Double]
    let visible: Bool
    let onActiveSpace: Bool
    let occluded: Bool
    let keyWindow: Bool
    let appActive: Bool

    @MainActor
    init(_ runtime: PetRuntime) {
        let renderer = runtime.renderer
        let desktop = runtime.desktop!
        submittedFrames = renderer.submittedFrameCount
        displayLinkCallbacks = renderer.displayLinkCallbackCount
        movementApplications = desktop.movementTickCount
        automaticActions = runtime.automaticActionCount
        completedRoutines = renderer.completedRoutineCount
        bufferedFrames = renderer.bufferedFrameCount
        animating = renderer.isAnimating
        displayLinkActive = renderer.hasActiveDisplayLink
        scheduledBehavior = runtime.hasScheduledBehavior
        fireflyVisible = renderer.fireflyVisible
        routine = renderer.currentRoutine?.rawValue
        frame = renderer.currentSnapshot?.timelineFrameIndex
        effectiveOrigin = [desktop.effectiveOrigin.x, desktop.effectiveOrigin.y]
        visible = desktop.panel.isVisible
        onActiveSpace = desktop.panel.isOnActiveSpace
        occluded = !desktop.panel.occlusionState.contains(.visible)
        keyWindow = desktop.panel.isKeyWindow
        appActive = NSApp.isActive
    }

    func remainedStill(since before: Self) -> Bool {
        submittedFrames == before.submittedFrames && displayLinkCallbacks == before.displayLinkCallbacks
            && movementApplications == before.movementApplications && automaticActions == before.automaticActions
            && !animating && !displayLinkActive && !fireflyVisible && effectiveOrigin == before.effectiveOrigin
    }
}

private struct RoutineObservation: Codable {
    let name: String
    let expectedClips: [String]
    var clipsSeen: [String] = []
    var acceptedFrames = 0
    var rejectedFrames = 0
    var mismatchedFrameRootPairs = 0
    var mismatchedCommittedFrameRootPairs = 0
    var maximumEffectiveOriginErrorPoints = 0.0
    var maximumLayerOffsetMismatchPoints = 0.0
    var maximumExcursionPoints = 0.0
    var maximumBufferedFrames = 0
    var fireflySamples = 0
    var fireflyOutsideCanvasSamples = 0
    var fireflyChangesWithoutImageCommit = 0
    var bufferUnderruns: UInt64 = 0
    var originAtStart: [Double] = []
    var originAfterFinish: [Double] = []
    var finalSnapshot: Snapshot?
}

private struct RestObservation: Codable {
    let name: String
    let elapsedSeconds: Double
    let before: Snapshot
    let after: Snapshot
}

private struct Report: Encodable {
    let schemaVersion = 1
    let evidenceKind = "native-personality-integration-with-test-only-plans-and-policy-values"
    let beganAt: Date
    let endedAt: Date
    let elapsedSeconds: Double
    let outcome: CheckStatus
    let environment: EnvironmentEvidence
    let checks: [Check]
    let routines: [RoutineObservation]
    let rests: [RestObservation]
    let build: BuildProvenance?
    let executableSHA256: String?
    let actualBundledAssetSHA256: [String: String]
    let defaultsSuiteRemoved: Bool
    let limitations = [
        "The harness displays only its own nonactivating 96-point pet panel with whole-window pass-through; it sends no mouse or keyboard events.",
        "The real runtime scheduler receives injected intentions and short delays; policy booleans exercise production branches without changing system settings.",
        "Suspension reasons are called directly. This does not prove real sleep/wake, notification delivery, physical input routing, Spaces, full-screen, or display disconnect/reconnect.",
        "Frame/root observations concern native application callbacks and retained layer geometry, not atomic WindowServer/GPU presentation or a visual-quality verdict.",
        "Buffer size is sampled during frame application and async waits; a short unobserved allocation peak is possible. This is not an energy or long-duration memory measurement.",
        "The cancellation path of the ordinary diagnostic is exercised. Complete probe/soak runs and launch-time review-flag isolation require their separate checks.",
        "Profile checks use a temporary defaults domain and report only equality results, never the pet name or serialized profile."
    ]
}

private enum HarnessError: Error { case blocked(String) }

@MainActor
private final class PersonalityRunner: NSObject, NSApplicationDelegate {
    private let output: URL?
    private let suiteName = "dev.spriglet.personality-validation.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var store: PetPreferencesStore!
    private var runtime: PetRuntime!
    private var runTask: Task<Void, Never>?
    private var finishing = false
    private var checks: [Check] = []
    private var routines: [RoutineObservation] = []
    private var rests: [RestObservation] = []
    private var activeObservation: Int?
    private var motionStart = CGPoint.zero
    private var previousSubmittedFrames: UInt64?
    private var previousFireflyPosition: CGPoint?
    private var previousFireflyVisible = false
    private var observedAppActivation = false
    private var observedKeyWindow = false
    private var beganAt = Date()
    private let clock = ContinuousClock()
    private var startInstant = ContinuousClock.now
    private var environment: EnvironmentEvidence!
    private var build: BuildProvenance?
    private var assetHashes: [String: String] = [:]
    private var executableHash: String?

    init(output: URL?) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        beganAt = .now
        startInstant = clock.now
        environment = EnvironmentEvidence()
        runTask = Task { [weak self] in await self?.run() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finishing { return .terminateNow }
        runTask?.cancel()
        return .terminateCancel
    }

    private func run() async {
        do {
            try loadEvidence()
            defaults = UserDefaults(suiteName: suiteName)
            guard defaults != nil else { throw HarnessError.blocked("A temporary defaults suite was unavailable.") }
            defaults.removePersistentDomain(forName: suiteName)
            store = PetPreferencesStore(defaults: defaults)
            store.save(PetPreferences(isHidden: true, clickThrough: true, allSpaces: false,
                                      autonomousBehavior: false, isParked: true))
            runtime = PetRuntime(preferencesStore: store)
            runtime.start()
            runtime.desktop.panel.isRestorable = false
            runtime.desktop.panel.disableSnapshotRestoration()
            installObservation()
            check("actual-sample-assets-loaded", runtime.renderer.assetError == nil && runtime.renderer.manifest != nil,
                  "The actual runtime loaded the copied bundled manifest and image assets.")
            guard runtime.renderer.assetError == nil else { finish(); return }
            guard environment.screenCount > 0 else { throw HarnessError.blocked("No desktop display was available.") }
            runtime.setHidden(false)
            try await pause(0.5)
            try requireEnvironment()
            positionWithFractionalOrigin()
            guard let offsets = runtime.renderer.routineRootOffsets(.explore, direction: .walkLeft),
                  let opposite = runtime.renderer.routineRootOffsets(.explore, direction: .walkRight),
                  runtime.desktop.canFitRootMotion(offsets), runtime.desktop.canFitRootMotion(opposite) else {
                throw HarnessError.blocked("The current usable display area could not fit both complete 102.4-point excursions.")
            }
            check("native-nonactivating-96-point-panel", runtime.desktop.panel.frame.size == NSSize(width: 96, height: 96)
                  && !runtime.desktop.panel.canBecomeKey && !runtime.desktop.panel.canBecomeMain
                  && runtime.desktop.panel.ignoresMouseEvents,
                  "The production desktop host is 96 points, cannot become key/main, and uses explicit pass-through.")
            try await restingCheck("initial-rest", seconds: 0.35)

            for direction in [SampleClipID.walkLeft, .walkRight] {
                try await finiteRoutine(.explore, direction: direction)
                try await finiteRoutine(.firefly, direction: direction)
            }
            runtime.setParked(true)
            try await finiteRoutine(.firefly, direction: .walkLeft, stationary: true, useRuntimeCommand: true)
            try await verifyPersistenceAndProbeCancellation()
            try await verifyPendingDeadlines()
            try await verifyAutomaticExecution()
            try await verifyInFlightCancellation()
            try await verifyEnvironmentPolicy()
            try await verifyCallbackOwnership()
            runtime.setAutonomousBehavior(false)
            runtime.renderer.resetPose()
            try await restingCheck("final-stable-rest", seconds: 0.75)
            check("native-panel-stayed-nonkey", !observedKeyWindow,
                  "The harness's own panel was never key at any sampled point; this is not a cross-app physical-focus test.")
            check("app-remained-inactive-at-samples", !observedAppActivation,
                  "No sampled harness state was app-active. This does not establish continuous foreground-focus behavior.")
        } catch HarnessError.blocked(let reason) {
            checks.append(Check(name: "environment", status: .blocked, detail: reason))
        } catch is CancellationError {
            checks.append(Check(name: "completed-run", status: .blocked, detail: "The finite harness was cancelled before all cases completed."))
        } catch {
            checks.append(Check(name: "completed-run", status: .failed, detail: "The harness could not read or encode its own evidence: \(error.localizedDescription)"))
        }
        finish()
    }

    private func positionWithFractionalOrigin() {
        runtime.recenter()
        guard let screen = runtime.desktop.panel.screen else { return }
        let desired = CGPoint(x: screen.visibleFrame.midX - 112 + 0.375,
                              y: screen.visibleFrame.minY + min(60, (screen.visibleFrame.height - runtime.renderer.displaySize.height) / 2) + 0.25)
        let start = runtime.desktop.effectiveOrigin
        runtime.nudge(dx: desired.x - start.x, dy: desired.y - start.y)
    }

    private func installObservation() {
        let renderer = runtime.renderer
        let start = renderer.onPlaybackWillStart
        let apply = renderer.onFrame
        renderer.onPlaybackWillStart = { [weak self] timeline in
            let accepted = start?(timeline) ?? false
            if accepted, let self { motionStart = runtime.desktop.effectiveOrigin }
            return accepted
        }
        renderer.onFrame = { [weak self] frame in
            let accepted = apply?(frame) ?? false
            guard let self, let index = activeObservation else { return accepted }
            if !accepted { routines[index].rejectedFrames += 1; return false }
            let desktop = runtime.desktop!
            routines[index].acceptedFrames += 1
            if routines[index].clipsSeen.last != frame.clip.rawValue { routines[index].clipsSeen.append(frame.clip.rawValue) }
            if desktop.appliedFrameIndex != frame.timelineFrameIndex || desktop.appliedRootOffset != frame.rootOffsetPoints {
                routines[index].mismatchedFrameRootPairs += 1
            }
            let expected = CGPoint(x: motionStart.x + frame.rootOffsetPoints.x, y: motionStart.y + frame.rootOffsetPoints.y)
            let actual = CGPoint(x: desktop.panel.frame.minX + renderer.actualImageLayerOffset.x,
                                 y: desktop.panel.frame.minY + renderer.actualImageLayerOffset.y)
            routines[index].maximumEffectiveOriginErrorPoints = max(routines[index].maximumEffectiveOriginErrorPoints, error(actual, expected))
            routines[index].maximumLayerOffsetMismatchPoints = max(routines[index].maximumLayerOffsetMismatchPoints,
                max(error(desktop.imageOffset, renderer.actualImageLayerOffset), error(renderer.imageOffset, renderer.actualImageLayerOffset)))
            routines[index].maximumExcursionPoints = max(routines[index].maximumExcursionPoints, error(actual, motionStart))
            routines[index].maximumBufferedFrames = max(routines[index].maximumBufferedFrames, renderer.bufferedFrameCount)
            return accepted
        }
    }

    private func observe() {
        guard let runtime else { return }
        observedAppActivation = observedAppActivation || NSApp.isActive
        observedKeyWindow = observedKeyWindow || runtime.desktop.panel.isKeyWindow
        guard let index = activeObservation else { return }
        let renderer = runtime.renderer
        routines[index].maximumBufferedFrames = max(routines[index].maximumBufferedFrames, renderer.bufferedFrameCount)
        if renderer.isAnimating, let snapshot = renderer.currentSnapshot,
           runtime.desktop.appliedFrameIndex != snapshot.timelineFrameIndex || runtime.desktop.appliedRootOffset != snapshot.rootOffsetPoints {
            routines[index].mismatchedCommittedFrameRootPairs += 1
        }
        if let position = renderer.currentFireflyPosition {
            routines[index].fireflySamples += 1
            // The toy owns a 28-point layer; include its complete bounds.
            if position.x < 14 || position.y < 14 || position.x > renderer.bounds.width - 14 || position.y > renderer.bounds.height - 14 {
                routines[index].fireflyOutsideCanvasSamples += 1
            }
        }
        if renderer.isAnimating, let previousSubmittedFrames, previousSubmittedFrames == renderer.submittedFrameCount,
           previousFireflyVisible != renderer.fireflyVisible || previousFireflyPosition != renderer.currentFireflyPosition {
            routines[index].fireflyChangesWithoutImageCommit += 1
        }
        previousSubmittedFrames = renderer.submittedFrameCount
        previousFireflyVisible = renderer.fireflyVisible
        previousFireflyPosition = renderer.currentFireflyPosition
    }

    private func finiteRoutine(_ routine: PetRoutine, direction: SampleClipID, stationary: Bool = false,
                               useRuntimeCommand: Bool = false) async throws {
        try requireEnvironment()
        runtime.setAutonomousBehavior(false)
        runtime.renderer.resetPose()
        let name = "\(routine.rawValue)-\(stationary ? "parked" : direction.rawValue)"
        let renderer = runtime.renderer
        let origin = runtime.desktop.effectiveOrigin
        let home = runtime.desktop.savedPlacement
        let completed = renderer.completedRoutineCount
        let underruns = renderer.bufferUnderrunCount
        let index = routines.count
        routines.append(RoutineObservation(name: name, expectedClips: routine.clips(direction: direction, stationary: stationary).map(\.rawValue),
                                           originAtStart: [origin.x, origin.y]))
        activeObservation = index
        previousSubmittedFrames = nil
        if useRuntimeCommand { runtime.playWithFirefly() }
        else { renderer.playRoutine(routine, direction: direction, stationary: stationary) }
        let began = renderer.isAnimating
        let finished = try await waitUntil(timeout: min(15, renderer.routineDuration(routine, direction: direction, stationary: stationary) + 3)) {
            !self.runtime.renderer.isAnimating
        }
        try requireEnvironment()
        observe()
        let end = runtime.desktop.effectiveOrigin
        routines[index].originAfterFinish = [end.x, end.y]
        routines[index].bufferUnderruns = renderer.bufferUnderrunCount - underruns
        routines[index].finalSnapshot = Snapshot(runtime)
        activeObservation = nil
        let observation = routines[index]
        check("\(name)-finite-and-completed-once", began && finished && renderer.completedRoutineCount == completed + 1
              && renderer.lastCompletedRoutine == routine && observation.clipsSeen == observation.expectedClips,
              "The complete expected authored sequence ran as one finite request and incremented completion exactly once.")
        check("\(name)-matched-image-and-root", observation.acceptedFrames > 0 && observation.rejectedFrames == 0
              && observation.mismatchedFrameRootPairs == 0 && observation.mismatchedCommittedFrameRootPairs == 0
              && observation.maximumEffectiveOriginErrorPoints < 0.001 && observation.maximumLayerOffsetMismatchPoints < 0.001,
              "Accepted host frames and sampled committed images matched their root offsets; native layer compensation retained fractional geometry.")
        check("\(name)-bounded-return-preserves-home", error(origin, end) < 0.001 && home == runtime.desktop.savedPlacement
              && abs(observation.maximumExcursionPoints - (stationary ? 0 : 102.4)) < 0.001,
              "The complete excursion returned to its precise initial origin without overwriting saved home; parked play did not travel.")
        check("\(name)-bounded-buffer-and-toy", observation.maximumBufferedFrames <= 12
              && observation.fireflyOutsideCanvasSamples == 0 && observation.fireflyChangesWithoutImageCommit == 0
              && (routine != .firefly || observation.fireflySamples > 0) && !renderer.fireflyVisible && !renderer.hasActiveDisplayLink,
              "Observed decoded frames stayed within twelve; toy samples stayed inside the canvas and changed only with submitted images. No toy or display link survived completion.")
        try await restingCheck("\(name)-settled", seconds: 0.2)
    }

    private func verifyPersistenceAndProbeCancellation() async throws {
        runtime.setAutonomousBehavior(false)
        runtime.renamePet("  Cedar   Friend  ")
        let traits = runtime.profile.traits
        runtime.setParked(false)
        runtime.resetRecentPreferences()
        runtime.play()
        let accepted = runtime.renderer.isAnimating
        let learned = runtime.interactionMemory.values().affection > 0
        _ = try await waitUntil(timeout: 5) { !self.runtime.renderer.isAnimating }
        runtime.setParked(true)
        let saved = runtime.snapshotPreferencesForProbe()
        let loaded = PetRuntime(preferencesStore: store)
        check("profile-memory-and-parked-persist", accepted && learned && runtime.petName == "Cedar Friend"
              && loaded.profile == saved.profile && loaded.profile.traits == traits
              && loaded.interactionMemory == saved.interactionMemory && loaded.isParked == saved.isParked
              && store.load().placement == saved.placement,
              "A reconstructed runtime recovered the normalized name, stable traits, deliberate-pet memory, parking, and saved home from its isolated store. No name is included in this report.")

        let before = runtime.snapshotPreferencesForProbe()
        let beforePosition = runtime.desktop.effectiveOrigin
        let beforeData = defaults.data(forKey: "dev.spriglet.preferences")
        let beforeBackup = defaults.data(forKey: "dev.spriglet.preferences.lastGood")
        runtime.runProbe()
        try await pause(0.2) // The ordinary probe captures its snapshot, then starts its two-second warm-up.
        let sampling = runtime.sampling
        runtime.renamePet("Temporary Validation")
        runtime.setParked(!before.isParked)
        runtime.play()
        runtime.nudge(dx: 1.25)
        let noLearning = runtime.interactionMemory == before.interactionMemory
        runtime.cancelProbe()
        let cancelled = try await waitUntil(timeout: 3) { !self.runtime.sampling }
        check("cancelled-probe-restores-without-learning", sampling && cancelled && noLearning
              && runtime.snapshotPreferencesForProbe() == before && error(beforePosition, runtime.desktop.effectiveOrigin) < 0.001
              && defaults.data(forKey: "dev.spriglet.preferences") == beforeData
              && defaults.data(forKey: "dev.spriglet.preferences.lastGood") == beforeBackup,
              "The normal diagnostic captured/restored state on cancellation. Interactions during sampling added no memory; both isolated preference payloads remained byte-identical.")
        runtime.setClickThrough(runtime.clickThrough)
        check("post-probe-save-does-not-persist-diagnostic-state", store.load() == before,
              "A subsequent ordinary settings save contained the restored profile, memory, parking and home, excluding temporary diagnostic changes.")
    }

    private func verifyPendingDeadlines() async throws {
        let cases: [(String, @MainActor () -> Void, @MainActor () -> Void, Bool)] = [
            ("parked", { self.runtime.setParked(true) }, { self.runtime.setParked(false) }, false),
            ("quiet-off", { self.runtime.setAutonomousBehavior(false) }, { }, true),
            ("hidden", { self.runtime.setHidden(true) }, { self.runtime.setHidden(false) }, true),
            ("paused", { self.runtime.setPaused(true) }, { self.runtime.setPaused(false) }, true),
            ("system-suspension", { self.runtime.setSuspension(.systemAsleep, active: true) },
             { self.runtime.setSuspension(.systemAsleep, active: false) }, true)
        ]
        for (name, cancel, restore, mustHaveNoDeadline) in cases {
            runtime.setAutonomousBehavior(false)
            runtime.renderer.resetPose()
            runtime.setParked(false)
            runtime.setAutonomousBehavior(true)
            let actions = runtime.automaticActionCount
            runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.20))
            let scheduled = runtime.hasScheduledBehavior
            cancel()
            let pendingCleared = !runtime.hasScheduledBehavior
            try await pause(1.35)
            check("\(name)-cancels-pending-explore", scheduled && runtime.automaticActionCount == actions
                  && !runtime.renderer.isAnimating && !runtime.renderer.fireflyVisible
                  && (!mustHaveNoDeadline || pendingCleared),
                  "The prior short explore deadline did not execute after the state change. Parked mode may schedule a later quiet observation.")
            runtime.setAutonomousBehavior(false)
            restore()
            try await pause(0.05)
        }
    }

    private func verifyAutomaticExecution() async throws {
        try requireEnvironment()
        runtime.setParked(false)
        runtime.setAutonomousBehavior(true)
        let count = runtime.automaticActionCount
        let completed = runtime.renderer.completedRoutineCount
        let home = runtime.desktop.savedPlacement
        let origin = runtime.desktop.effectiveOrigin
        runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.01))
        let started = try await waitUntil(timeout: 2) { self.runtime.automaticActionCount > count }
        let acceptedExplore = runtime.lastAutomaticIntent == .explore && runtime.renderer.currentRoutine == .explore
        let ended = try await waitUntil(timeout: 12) { !self.runtime.renderer.isAnimating }
        check("real-scheduler-starts-one-returning-explore", started && acceptedExplore && ended
              && runtime.automaticActionCount == count + 1 && runtime.renderer.completedRoutineCount == completed + 1
              && error(origin, runtime.desktop.effectiveOrigin) < 0.001 && runtime.desktop.savedPlacement == home,
              "An injected intention/delay used the real scheduler and policy, accepted one complete explore, and returned without altering saved home.")

        runtime.setAutonomousBehavior(false)
        runtime.setAutonomousBehavior(true)
        let replacementCount = runtime.automaticActionCount
        let replacementCompleted = runtime.renderer.completedRoutineCount
        runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.20))
        runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .observe, delaySeconds: 0.01))
        let replacementStarted = try await waitUntil(timeout: 2) { self.runtime.automaticActionCount > replacementCount }
        let replacementWasObservation = runtime.lastAutomaticIntent == .observe
        _ = try await waitUntil(timeout: 4) { !self.runtime.renderer.isAnimating }
        try await pause(0.35)
        check("replaced-deadline-fires-once", replacementStarted && replacementWasObservation
              && runtime.automaticActionCount == replacementCount + 1
              && runtime.renderer.completedRoutineCount == replacementCompleted + 1,
              "Replacing a pending explore with one observation left no second execution or duplicate completion after the old deadline.")
        runtime.setAutonomousBehavior(false)

        runtime.setParked(true)
        runtime.setAutonomousBehavior(true)
        let parkedOrigin = runtime.desktop.effectiveOrigin
        let parkedCount = runtime.automaticActionCount
        runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.01))
        let parkedStarted = try await waitUntil(timeout: 2) { self.runtime.automaticActionCount > parkedCount }
        let becameObservation = runtime.lastAutomaticIntent == .observe
        _ = try await waitUntil(timeout: 4) { !self.runtime.renderer.isAnimating }
        check("parked-policy-revalidates-injected-explore", parkedStarted && becameObservation
              && error(parkedOrigin, runtime.desktop.effectiveOrigin) < 0.001,
              "Even a newly injected explore is revalidated by production policy and becomes an in-place observation when parked.")
        runtime.setAutonomousBehavior(false)
    }

    private func verifyInFlightCancellation() async throws {
        let cases: [(String, @MainActor () -> Void, @MainActor () -> Void)] = [
            ("parked", { self.runtime.setParked(true) }, { self.runtime.setParked(false) }),
            ("hidden", { self.runtime.setHidden(true) }, { self.runtime.setHidden(false) }),
            ("paused", { self.runtime.setPaused(true) }, { self.runtime.setPaused(false) }),
            ("system-suspension", { self.runtime.setSuspension(.systemAsleep, active: true) },
             { self.runtime.setSuspension(.systemAsleep, active: false) })
        ]
        for (name, cancel, restore) in cases {
            try requireEnvironment()
            runtime.setAutonomousBehavior(false)
            runtime.setParked(false)
            runtime.renderer.resetPose()
            positionWithFractionalOrigin()
            let completed = runtime.renderer.completedRoutineCount
            let home = runtime.desktop.savedPlacement
            runtime.renderer.playRoutine(.firefly, direction: .walkRight)
            let active = try await waitUntil(timeout: 3) { self.runtime.desktop.isMoving && self.runtime.renderer.fireflyVisible }
            let heldOrigin = runtime.desktop.effectiveOrigin
            cancel()
            let cancellation = Snapshot(runtime)
            try await pause(0.35)
            let settled = Snapshot(runtime)
            check("\(name)-cancels-running-firefly-without-reward", active
                  && settled.remainedStill(since: cancellation) && !runtime.desktop.isMoving
                  && runtime.renderer.completedRoutineCount == completed
                  && runtime.desktop.savedPlacement == home && error(heldOrigin, runtime.desktop.effectiveOrigin) < 0.001,
                  "Cancellation during an actual walking frame removed the toy and clocks, retained placement, and did not increment routine completion.")
            restore()
            try await pause(0.05)
        }
    }

    private func verifyEnvironmentPolicy() async throws {
        runtime.setAutonomousBehavior(false)
        runtime.setParked(false)
        positionWithFractionalOrigin()
        runtime.setAutonomousBehavior(true)
        let count = runtime.automaticActionCount
        runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.20))
        runtime.setEnvironmentForValidation(lowPower: true, reduceMotion: false)
        try await pause(1.35)
        check("low-power-replaces-pending-explore", runtime.lowPower && runtime.automaticActionCount == count
              && !runtime.renderer.isAnimating, "The production Low Power transition invalidated the prior short explore deadline.")
        let lowPowerOrigin = runtime.desktop.effectiveOrigin
        runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.01))
        let observed = try await waitUntil(timeout: 2) { self.runtime.automaticActionCount > count }
        let stationary = runtime.lastAutomaticIntent == .observe
        _ = try await waitUntil(timeout: 4) { !self.runtime.renderer.isAnimating }
        check("low-power-revalidates-explore", observed && stationary && error(lowPowerOrigin, runtime.desktop.effectiveOrigin) < 0.001,
              "A fresh explore intention became a stationary observation under the production Low Power policy.")
        runtime.setAutonomousBehavior(false)
        let fireflyOrigin = runtime.desktop.effectiveOrigin
        runtime.playWithFirefly()
        let acceptedFirefly = runtime.renderer.currentRoutine == .firefly
        _ = try await waitUntil(timeout: 6) { !self.runtime.renderer.isAnimating }
        check("low-power-manual-firefly-stays-in-place", acceptedFirefly && error(fireflyOrigin, runtime.desktop.effectiveOrigin) < 0.001
              && !runtime.renderer.fireflyVisible, "Explicit firefly play remained finite and stationary under Low Power policy.")
        runtime.setEnvironmentForValidation(lowPower: false, reduceMotion: false)

        for reduce in [false, true] {
            runtime.renderer.playRoutine(.firefly, direction: .walkLeft)
            let began = try await waitUntil(timeout: 3) { self.runtime.desktop.isMoving && self.runtime.renderer.fireflyVisible }
            let completed = runtime.renderer.completedRoutineCount
            runtime.setEnvironmentForValidation(lowPower: !reduce, reduceMotion: reduce)
            let stopped = Snapshot(runtime)
            try await pause(0.3)
            check("\(reduce ? "reduce-motion" : "low-power")-cancels-running-excursion", began
                  && Snapshot(runtime).remainedStill(since: stopped) && runtime.renderer.completedRoutineCount == completed,
                  "Changing the production environment-policy values cancelled an active toy excursion without completion or continuing callbacks.")
            if reduce {
                runtime.setAutonomousBehavior(true)
                let beforeRequests = Snapshot(runtime)
                runtime.play()
                runtime.walk()
                runtime.playWithFirefly()
                runtime.scheduleBehaviorForValidation(PlannedBehavior(intent: .explore, delaySeconds: 0.01))
                try await pause(1.35)
                check("reduce-motion-blocks-manual-and-automatic-motion", !runtime.permitsMotion
                      && !runtime.hasScheduledBehavior && Snapshot(runtime).remainedStill(since: beforeRequests),
                      "Pet, walk, firefly, and injected autonomous requests produced no motion or toy while Reduce Motion was active.")
                runtime.setAutonomousBehavior(false)
            }
            runtime.setEnvironmentForValidation(lowPower: false, reduceMotion: false)
        }
    }

    private func verifyCallbackOwnership() async throws {
        runtime.setAutonomousBehavior(false)
        runtime.renderer.resetPose()
        let renderer = runtime.renderer
        let originalStart = renderer.onPlaybackWillStart
        let originalStop = renderer.onPlaybackStopped
        defer {
            renderer.onPlaybackWillStart = originalStart
            renderer.onPlaybackStopped = originalStop
        }

        for suspend in [false, true] {
            let completed = renderer.completedRoutineCount
            renderer.onPlaybackWillStart = { [weak self] timeline in
                let accepted = originalStart?(timeline) ?? false
                guard let self else { return false }
                if suspend { runtime.setPaused(true) }
                else {
                    runtime.desktop.stopMovement()
                    renderer.resetPose()
                }
                return accepted
            }
            renderer.playRoutine(.firefly)
            try await pause(0.15)
            check("start-callback-\(suspend ? "suspension" : "cancellation")-owns-generation",
                  !renderer.isAnimating && renderer.currentRoutine == nil && renderer.bufferedFrameCount == 0
                    && !renderer.hasActiveDisplayLink && !renderer.fireflyVisible && renderer.completedRoutineCount == completed,
                  "The real host accepted a start, then its callback cancelled or suspended and returned true. The old begin did not restart or repopulate playback.")
            renderer.onPlaybackWillStart = originalStart
            if suspend { runtime.setPaused(false) }
        }

        for cancel in [true, false] {
            runtime.renderer.resetPose()
            var replaced = false
            let completed = renderer.completedRoutineCount
            renderer.onPlaybackStopped = {
                originalStop?()
                if !replaced {
                    replaced = true
                    renderer.playRoutine(.greet)
                }
            }
            renderer.playRoutine(cancel ? .firefly : .observe)
            if cancel {
                _ = try await waitUntil(timeout: 2) { renderer.fireflyVisible }
                // A new public request tears down the old one; replacement work
                // installed by that teardown must keep ownership over this caller.
                renderer.playRoutine(.explore)
            } else {
                // If old finish resumes its captured queue, this action would
                // replace the callback's named greet routine and lose completion.
                renderer.play(.react)
            }
            let didReplace = try await waitUntil(timeout: 3) { replaced }
            let replacementOwnsState = renderer.currentRoutine == .greet && renderer.isAnimating
            let finished = try await waitUntil(timeout: 5) { !renderer.isAnimating }
            check("stop-callback-replacement-survives-\(cancel ? "cancellation" : "completion")",
                  didReplace && replacementOwnsState && finished && renderer.lastCompletedRoutine == .greet
                    && renderer.completedRoutineCount == completed + (cancel ? 1 : 2)
                    && !renderer.fireflyVisible && !renderer.hasActiveDisplayLink,
                  "A stop callback installed a new greet. The superseded caller did not clear it, start a competing request, or resume a stale queued action.")
            renderer.onPlaybackStopped = originalStop
        }
    }

    private func restingCheck(_ name: String, seconds: Double) async throws {
        let before = Snapshot(runtime)
        let began = clock.now
        try await pause(seconds)
        let after = Snapshot(runtime)
        rests.append(RestObservation(name: name, elapsedSeconds: duration(began.duration(to: clock.now)), before: before, after: after))
        check(name, after.remainedStill(since: before) && !after.scheduledBehavior,
              "No image assignment, display-link callback, movement application, automatic action, toy, or pending behavior occurred during this short stable rest.")
    }

    /// Polling observes native work; it never advances a timeline or injects input.
    private func pause(_ seconds: Double) async throws {
        let deadline = clock.now.advanced(by: .seconds(min(15, max(0, seconds))))
        repeat {
            try Task.checkCancellation()
            observe()
            if clock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(20), tolerance: .milliseconds(2))
        } while true
    }

    private func waitUntil(timeout: Double, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = clock.now.advanced(by: .seconds(min(15, max(0, timeout))))
        repeat {
            try Task.checkCancellation()
            observe()
            if condition() { return true }
            if clock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(20), tolerance: .milliseconds(2))
        } while true
    }

    private func requireEnvironment(context: String = #function, line: UInt = #line) throws {
        let panel = runtime.desktop.panel
        let permitsMotion = runtime.permitsMotion
        let visible = panel.isVisible
        let onActiveSpace = panel.isOnActiveSpace
        let occlusion = panel.occlusionState
        guard permitsMotion, visible, onActiveSpace, occlusion.contains(.visible) else {
            let frame = panel.frame
            throw HarnessError.blocked(
                "The own pet panel was unavailable or system visibility/motion policy prevented native playback. "
                + "Gate at \(context):\(line): permitsMotion=\(permitsMotion), status=\(runtime.status), "
                + "isVisible=\(visible), isOnActiveSpace=\(onActiveSpace), "
                + "occlusionVisible=\(occlusion.contains(.visible)), occlusionRawValue=\(occlusion.rawValue), "
                + "frame=[\(frame.minX), \(frame.minY), \(frame.width), \(frame.height)], "
                + "isHidden=\(runtime.isHidden), isPaused=\(runtime.isPaused), allSpaces=\(runtime.allSpaces), "
                + "lowPower=\(runtime.lowPower), reduceMotion=\(runtime.reduceMotion), "
                + "hasAssetError=\(runtime.renderer.assetError != nil), appActive=\(NSApp.isActive)."
            )
        }
    }

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(name: name, status: passed ? .passed : .failed, detail: detail))
    }

    private func loadEvidence() throws {
        guard let resources = PetAssetDefinition.acornHopper.resourceDirectory(in: .main),
              let provenance = Bundle.main.url(forResource: "build-provenance", withExtension: "json") else {
            throw HarnessError.blocked("Run the packaged validation app so its asset snapshot and build provenance are available.")
        }
        build = try JSONDecoder().decode(BuildProvenance.self, from: Data(contentsOf: provenance))
        let files = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(resources.path.count + 1))
            assetHashes[relative] = try hash(file)
        }
        if let executable = Bundle.main.executableURL { executableHash = try hash(executable) }
        check("bundled-assets-match-build-snapshot", build?.assetSHA256 == assetHashes,
              "Every bundled sample file matched the SHA-256 recorded when the source snapshot was compiled.")
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func error(_ a: CGPoint, _ b: CGPoint) -> Double { max(abs(a.x - b.x), abs(a.y - b.y)) }
    private func duration(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        runtime?.stop()
        runtime?.desktop?.hide()
        defaults?.removePersistentDomain(forName: suiteName)
        let removed = defaults?.persistentDomain(forName: suiteName)?.isEmpty ?? true
        check("temporary-defaults-domain-removed", removed,
              "The harness removed its UUID preferences domain before returning its result.")
        let outcome: CheckStatus = checks.contains { $0.status == .failed } ? .failed
            : checks.contains { $0.status == .blocked } ? .blocked : .passed
        let report = Report(beganAt: beganAt, endedAt: .now, elapsedSeconds: duration(startInstant.duration(to: clock.now)),
                            outcome: outcome, environment: environment, checks: checks, routines: routines, rests: rests,
                            build: build, executableSHA256: executableHash, actualBundledAssetSHA256: assetHashes,
                            defaultsSuiteRemoved: removed)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let output {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
            }
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("Could not write the validation report: \(error.localizedDescription)")
            exit(1)
        }
        exit(outcome == .passed && removed ? 0 : outcome == .blocked ? 2 : 1)
    }
}
