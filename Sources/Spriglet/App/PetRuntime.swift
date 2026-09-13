import AppKit
import Observation
import OSLog
import SprigletCore

/// Owns only low-frequency UI state. Frame counters are sampled on demand.
@MainActor @Observable
final class PetRuntime {
    private(set) var isHidden = false
    private(set) var isPaused = false
    private(set) var isAnimating = false
    private(set) var isMoving = false
    private(set) var clickThrough = false
    private(set) var allSpaces = true
    private(set) var autonomousBehavior = true
    private(set) var isSleeping = false
    private(set) var hasScheduledBehavior = false
    private(set) var automaticActionCount: UInt64 = 0
    private(set) var lowPower = false
    private(set) var reduceMotion = false
    private(set) var submittedFrames: UInt64 = 0
    private(set) var characterIssue: String?
    private(set) var footprintMiB: Double?
    private(set) var positionDescription = "Unavailable"
    private(set) var sampling = false
    private(set) var reportJSON: String?
    private(set) var diagnosticProgress = ""
    private(set) var message = "Quiet company. Spriglet rests between small moments of activity."

    @ObservationIgnored let renderer = PetRenderView(frame: NSRect(x: 0, y: 0, width: 224, height: 224))
    @ObservationIgnored private(set) var desktop: PetWindowController!
    private var policy = ActivityPolicy()
    @ObservationIgnored private var tokens: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorGeneration: UInt64 = 0
    @ObservationIgnored private var behaviorPlanner = PetBehaviorPlanner(seed: UInt64.random(in: .min ... .max))
    @ObservationIgnored private let preferencesStore: PetPreferencesStore
    @ObservationIgnored private let initialPlacement: PetSavedPlacement?
    @ObservationIgnored private var probePlacement: PetSavedPlacement?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isInteracting = false
    @ObservationIgnored private let isCommandLineProbe = CommandLine.arguments.contains("--probe")
        || CommandLine.arguments.contains("--soak")
    @ObservationIgnored private let isTemporaryReview = CommandLine.arguments.contains("--sample-review")
        || CommandLine.arguments.contains("--welcome-review")
    @ObservationIgnored private let logger = Logger(subsystem: "dev.spriglet.app", category: "lifecycle")

    init(preferencesStore: PetPreferencesStore = PetPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let preferences = isCommandLineProbe || isTemporaryReview ? PetPreferences() : preferencesStore.load()
        isHidden = preferences.isHidden
        isPaused = preferences.isPaused
        clickThrough = preferences.clickThrough
        allSpaces = preferences.allSpaces
        autonomousBehavior = preferences.autonomousBehavior
        initialPlacement = preferences.placement
    }

    var status: String {
        if isHidden { return "Hidden" }
        if isPaused { return "Paused" }
        if !policy.allowsAnimation { return "System rest" }
        if isMoving { return "Moving" }
        if isAnimating { return "Active" }
        return isSleeping ? "Napping" : "Resting"
    }

    var permitsMotion: Bool { policy.allowsAnimation && !reduceMotion && renderer.assetError == nil }

    func start() {
        guard desktop == nil else { return }
        desktop = PetWindowController(contentView: renderer, size: renderer.displaySize) { [weak renderer] point in
            renderer?.containsPet(at: point) ?? false
        }
        desktop.onPetClicked = { [weak self] in
            guard let self, !self.sampling else { return }
            self.play()
        }
        desktop.onUserInteractionChanged = { [weak self] interacting in
            guard let self else { return }
            isInteracting = interacting
            if interacting {
                cancelBehaviorSchedule()
                behaviorPlanner.resetAfterInteraction()
                renderer.resetPose()
            } else {
                reconcileBehaviorSchedule()
            }
        }
        desktop.onMovementChanged = { [weak self] moving in
            self?.isMoving = moving
            if !moving { self?.refreshMeasurements() }
            self?.reconcileBehaviorSchedule()
        }
        desktop.onOcclusionChanged = { [weak self] visible in self?.setSuspension(.occluded, active: !visible) }
        desktop.onScreenChanged = { [weak self] in self?.refreshEnvironment() }
        desktop.onMovementInterrupted = { [weak self] in self?.renderer.resetPose() }
        desktop.onWalkRequested = { [weak self] in self?.walk() }
        desktop.onImageOffsetChanged = { [weak self] offset in self?.renderer.setImageOffset(offset) }
        desktop.onPlacementSettled = { [weak self] _ in
            self?.savePreferences()
            self?.refreshMeasurements()
        }
        renderer.onAnimationStateChanged = { [weak self] animating in
            guard let self else { return }
            isAnimating = animating
            isSleeping = renderer.isSleeping
            if !animating { refreshMeasurements() }
            reconcileBehaviorSchedule()
        }
        renderer.onPlaybackWillStart = { [weak self] timeline in
            self?.desktop.beginAuthoredMotion(timeline.rootOffsets) ?? false
        }
        renderer.onFrame = { [weak self] snapshot in
            self?.desktop.applyAuthoredFrame(snapshot) ?? false
        }
        renderer.onPlaybackStopped = { [weak self] in self?.desktop.finishAuthoredMotion() }
        renderer.onAssetError = { [weak self] error in
            self?.characterIssue = error
            self?.message = error
        }
        characterIssue = renderer.assetError
        if let characterIssue { message = characterIssue }
        desktop.setClickThrough(clickThrough)
        desktop.setAllSpaces(allSpaces)
        desktop.restorePlacement(initialPlacement)
        setSuspension(.hidden, active: isHidden)
        setSuspension(.userPaused, active: isPaused)
        observeEnvironment()
        refreshEnvironment()
        if !isHidden { desktop.show() }
        refreshMeasurements()
        isRunning = true
        logger.info("Companion started; finite activity with a single cancellable resting deadline")
        if CommandLine.arguments.contains("--sample-review") {
            autonomousBehavior = false
            characterSample()
        } else if CommandLine.arguments.contains("--soak") {
            runSoak(terminateWhenFinished: true)
        } else if isCommandLineProbe {
            runProbe(terminateWhenFinished: true)
        } else if CommandLine.arguments.contains("--welcome-review") {
            autonomousBehavior = false
        } else {
            reconcileBehaviorSchedule()
        }
    }

    func stop() {
        isRunning = false
        cancelBehaviorSchedule()
        probeTask?.cancel()
        probeTask = nil
        desktop?.stopMovement()
        renderer.setSuspended(true)
        tokens.removeAll()
    }

    func play() {
        preview(.react)
    }

    func preview(_ action: PetAction) {
        guard permitsMotion else {
            message = "Show and resume the pet to interact. Reduce Motion keeps Spriglet still."
            return
        }
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        renderer.play(action)
        // A redundant wake/sleep request may be a no-op, with no completion event.
        reconcileBehaviorSchedule()
    }

    func walk(direction: SampleClipID? = nil) {
        guard permitsMotion else { return }
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        renderer.resetPose()
        guard let clip = fittingWalk(preferred: direction) else {
            message = "There is not enough room for a planted short walk in that direction. Move Spriglet away from the edge."
            reconcileBehaviorSchedule()
            return
        }
        renderer.playWalk(clip)
        reconcileBehaviorSchedule()
    }

    func characterSample() {
        guard permitsMotion else { return }
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        renderer.resetPose()
        guard let clip = fittingWalk(preferred: nil, sample: true) else {
            message = "Move Spriglet away from the screen edge to play the complete character sample."
            reconcileBehaviorSchedule()
            return
        }
        message = "Sprout · idle, a planted short walk, a happy pet reaction, then settle."
        renderer.playSample(walk: clip)
        reconcileBehaviorSchedule()
    }

    private func fittingWalk(preferred: SampleClipID?, sample: Bool = false) -> SampleClipID? {
        let candidates: [SampleClipID] = preferred.map { [$0] } ?? [.walkLeft, .walkRight]
        return candidates.first { direction in
            guard direction == .walkLeft || direction == .walkRight,
                  let offsets = renderer.rootOffsets(for: sample ? [.idle, direction, .pet, .settle] : [direction]) else { return false }
            return desktop.canFitRootMotion(offsets)
        }
    }

    func setPaused(_ value: Bool) {
        isPaused = value
        setSuspension(.userPaused, active: value)
        message = value ? "Paused. Animation and movement have stopped." : "Resumed in a resting pose."
        savePreferences()
    }

    func setHidden(_ value: Bool) {
        isHidden = value
        setSuspension(.hidden, active: value)
        if value { desktop.hide() } else { desktop.show() }
        savePreferences()
    }

    func setClickThrough(_ value: Bool) {
        clickThrough = value
        desktop.setClickThrough(value)
        message = value ? "Clicks pass through the entire pet window. Use this menu to interact." : "Pet interaction enabled."
        savePreferences()
    }

    func setAllSpaces(_ value: Bool) {
        allSpaces = value
        desktop.setAllSpaces(value)
        savePreferences()
    }

    func setAutonomousBehavior(_ value: Bool) {
        autonomousBehavior = value
        reconcileBehaviorSchedule()
        savePreferences()
        message = value ? "Spriglet will occasionally play its idle sample or settle into a nap." : "Quiet behavior is off. You can still interact with Spriglet."
    }

    func recenter() {
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        desktop.recenter()
        reconcileBehaviorSchedule()
    }

    func moveToNextDisplay() {
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        desktop.moveToNextDisplay()
        refreshEnvironment()
    }

    func nudge(dx: CGFloat = 0, dy: CGFloat = 0) {
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        desktop.nudge(dx: dx, dy: dy)
        refreshMeasurements()
        reconcileBehaviorSchedule()
    }

    func refreshMeasurements() {
        submittedFrames = renderer.submittedFrameCount
        footprintMiB = ProcessSample.capture().footprintBytes.map { Double($0) / 1_048_576 }
        if let frame = desktop?.panel.frame {
            positionDescription = String(format: "x %.0f, y %.0f · %.0f × %.0f pt", frame.minX, frame.minY, frame.width, frame.height)
        }
    }

    func runProbe(terminateWhenFinished: Bool = false) {
        runDiagnostic(extended: false, terminateWhenFinished: terminateWhenFinished)
    }

    func runSoak(terminateWhenFinished: Bool = false) {
        runDiagnostic(extended: true, terminateWhenFinished: terminateWhenFinished)
    }

    private func runDiagnostic(extended: Bool, terminateWhenFinished: Bool) {
        guard isRunning, !sampling else { return }
        probePlacement = desktop.currentPlacement
        sampling = true
        cancelBehaviorSchedule()
        diagnosticProgress = extended ? "Warming up for 100 activity cycles. About 6–7 minutes; cancel any time." : "Checking behaviors and resting."
        message = "Running a finite check. Controls return when it finishes."
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome: ProbeOutcome
                let json: String
                if extended {
                    let report = try await SoakProbe.run(runtime: self)
                    outcome = report.outcome
                    json = report.json
                } else {
                    let report = try await RuntimeProbe.run(runtime: self)
                    outcome = report.outcome
                    json = report.json
                }
                reportJSON = json
                print(json)
                switch outcome {
                case .passed: message = extended ? "100-cycle checks passed. Resource observations are in the report." : "Automatic checks passed. Desktop interaction still needs the manual matrix."
                case .failed: message = "A check failed. Inspect the report before relying on idle behavior."
                case .blocked: message = "Check blocked by visibility or a system motion/power setting. No preference was changed."
                }
            } catch is CancellationError {
                message = "Check cancelled. Your previous choices have been restored."
            } catch {
                logger.error("Diagnostic could not finish: \(error.localizedDescription, privacy: .public)")
                message = "The check could not finish. Try again when Spriglet can move."
            }
            sampling = false
            probePlacement = nil
            diagnosticProgress = ""
            refreshMeasurements()
            probeTask = nil
            if terminateWhenFinished { NSApp.terminate(nil) }
            else { reconcileBehaviorSchedule() }
        }
    }

    func copyReport() {
        guard let reportJSON else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportJSON, forType: .string)
    }

    func cancelProbe() {
        probeTask?.cancel()
    }

    func updateDiagnosticProgress(_ progress: String) {
        guard sampling else { return }
        diagnosticProgress = progress
    }

    func setSuspension(_ reason: SuspensionReason, active: Bool) {
        policy.set(reason, active: active)
        let suspended = !policy.allowsAnimation
        if suspended { desktop?.stopMovement() }
        renderer.setSuspended(suspended)
        refreshMeasurements()
        reconcileBehaviorSchedule()
    }

    private func refreshEnvironment() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let thermal = ProcessInfo.processInfo.thermalState
        setSuspension(.thermalPressure, active: thermal == .serious || thermal == .critical)
        let maxFPS = desktop?.panel.screen?.maximumFramesPerSecond ?? 60
        let fps = lowPower ? 30 : maxFPS
        renderer.setPreferredFramesPerSecond(fps)
        if reduceMotion {
            desktop?.stopMovement()
            renderer.resetPose()
        }
        reconcileBehaviorSchedule()
    }

    private func savePreferences() {
        guard isRunning, !sampling, !isCommandLineProbe, !isTemporaryReview else { return }
        preferencesStore.save(snapshotPreferencesForProbe())
    }

    func snapshotPreferencesForProbe() -> PetPreferences {
        PetPreferences(
            isHidden: isHidden, isPaused: isPaused, clickThrough: clickThrough,
            allSpaces: allSpaces, autonomousBehavior: autonomousBehavior,
            placement: desktop.savedPlacement
        )
    }

    private func reconcileBehaviorSchedule() {
        guard isRunning, autonomousBehavior, !sampling, permitsMotion,
              !isAnimating, !isMoving, !isInteracting else {
            cancelBehaviorSchedule()
            return
        }
        guard behaviorTask == nil else { return }
        scheduleBehavior(behaviorPlanner.next(isSleeping: renderer.isSleeping))
    }

    private func cancelBehaviorSchedule() {
        behaviorGeneration &+= 1
        behaviorTask?.cancel()
        behaviorTask = nil
        hasScheduledBehavior = false
    }

    private func scheduleBehavior(_ plan: PlannedBehavior, duringProbe: Bool = false) {
        cancelBehaviorSchedule()
        let generation = behaviorGeneration
        hasScheduledBehavior = true
        behaviorTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(plan.delaySeconds),
                                     tolerance: duringProbe ? .zero : .seconds(1))
            } catch { return }
            guard let self, generation == behaviorGeneration else { return }
            behaviorTask = nil
            hasScheduledBehavior = false
            guard isRunning, autonomousBehavior, permitsMotion,
                  !isAnimating, !isMoving, !isInteracting, !sampling || duringProbe else { return }
            automaticActionCount &+= 1
            renderer.play(plan.action)
            reconcileBehaviorSchedule()
        }
    }

    /// Exercises the same one-shot scheduler with a short deadline while the
    /// finite probe keeps normal scheduling and preference writes disabled.
    func scheduleOneBehaviorForProbe(_ plan: PlannedBehavior) {
        guard sampling, permitsMotion, autonomousBehavior,
              !isAnimating, !isMoving, !isInteracting else { return }
        scheduleBehavior(plan, duringProbe: true)
    }

    func restoreAfterProbe(_ preferences: PetPreferences) {
        // A cancelled probe may finish unwinding after application shutdown.
        // Only an ordinary cancellation should restore visible runtime state.
        guard isRunning else { return }
        cancelBehaviorSchedule()
        desktop.stopMovement()
        renderer.resetPose()
        setClickThrough(preferences.clickThrough)
        setAllSpaces(preferences.allSpaces)
        desktop.restorePlacement(preferences.placement)
        if let probePlacement {
            desktop.restorePlacement(probePlacement, preservingSavedPlacement: true)
        }
        setPaused(preferences.isPaused)
        setHidden(preferences.isHidden)
        setAutonomousBehavior(preferences.autonomousBehavior)
    }

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.ScreensDidSleepMessage.self) { [weak self] _ in
            await self?.setSuspension(.displayAsleep, active: true)
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.ScreensDidWakeMessage.self) { [weak self] _ in
            await self?.setSuspension(.displayAsleep, active: false)
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.WillSleepMessage.self) { [weak self] _ in
            self?.setSuspension(.systemAsleep, active: true)
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.DidWakeMessage.self) { [weak self] _ in
            self?.setSuspension(.systemAsleep, active: false)
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.SessionDidResignActiveMessage.self) { [weak self] _ in
            self?.setSuspension(.sessionInactive, active: true)
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.SessionDidBecomeActiveMessage.self) { [weak self] _ in
            self?.setSuspension(.sessionInactive, active: false)
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.AccessibilityDisplayOptionsDidChangeMessage.self) { [weak self] _ in
            self?.refreshEnvironment()
        })
        let defaultCenter = NotificationCenter.default
        tokens.append(defaultCenter.addObserver(of: ProcessInfo.processInfo, for: ProcessInfo.PowerStateDidChangeMessage.self) { [weak self] _ in
            await self?.refreshEnvironment()
        })
        tokens.append(defaultCenter.addObserver(of: ProcessInfo.processInfo, for: ProcessInfo.ThermalStateDidChangeMessage.self) { [weak self] _ in
            await self?.refreshEnvironment()
        })
    }
}
