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
    private(set) var sceneUpdates: UInt64 = 0
    private(set) var footprintMiB: Double?
    private(set) var sampling = false
    private(set) var probeResult: ProbeReport?
    private(set) var message = "Quiet company. Spriglet rests between small moments of activity."

    @ObservationIgnored let renderer = PetRenderView(frame: NSRect(x: 0, y: 0, width: 192, height: 192))
    @ObservationIgnored private(set) var desktop: PetWindowController!
    private var policy = ActivityPolicy()
    @ObservationIgnored private var tokens: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorGeneration: UInt64 = 0
    @ObservationIgnored private var behaviorPlanner = PetBehaviorPlanner(seed: UInt64.random(in: .min ... .max))
    @ObservationIgnored private let preferencesStore: PetPreferencesStore
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isInteracting = false
    @ObservationIgnored private let isCommandLineProbe = CommandLine.arguments.contains("--probe")
    @ObservationIgnored private let logger = Logger(subsystem: "dev.spriglet.prototype", category: "lifecycle")

    init(preferencesStore: PetPreferencesStore = PetPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let preferences = isCommandLineProbe ? PetPreferences() : preferencesStore.load()
        isHidden = preferences.isHidden
        isPaused = preferences.isPaused
        clickThrough = preferences.clickThrough
        allSpaces = preferences.allSpaces
        autonomousBehavior = preferences.autonomousBehavior
    }

    var status: String {
        if isHidden { return "Hidden" }
        if isPaused { return "Paused" }
        if !policy.allowsAnimation { return "System rest" }
        if isMoving { return "Moving" }
        if isAnimating { return "Active" }
        return isSleeping ? "Napping" : "Resting"
    }

    var permitsMotion: Bool { policy.allowsAnimation && !reduceMotion }

    func start() {
        guard desktop == nil else { return }
        desktop = PetWindowController(contentView: renderer) { [weak renderer] point in
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
            } else {
                reconcileBehaviorSchedule()
            }
        }
        desktop.onMovementChanged = { [weak self] moving in
            self?.isMoving = moving
            self?.reconcileBehaviorSchedule()
        }
        desktop.onOcclusionChanged = { [weak self] visible in self?.setSuspension(.occluded, active: !visible) }
        desktop.onScreenChanged = { [weak self] in self?.refreshEnvironment() }
        renderer.onAnimationStateChanged = { [weak self] animating in
            guard let self else { return }
            isAnimating = animating
            isSleeping = renderer.isSleeping
            if !animating { refreshMeasurements() }
            reconcileBehaviorSchedule()
        }
        desktop.setClickThrough(clickThrough)
        desktop.setAllSpaces(allSpaces)
        setSuspension(.hidden, active: isHidden)
        setSuspension(.userPaused, active: isPaused)
        observeEnvironment()
        refreshEnvironment()
        if !isHidden { desktop.show() }
        refreshMeasurements()
        isRunning = true
        logger.info("Companion started; finite activity with a single cancellable resting deadline")
        if isCommandLineProbe {
            runProbe(terminateWhenFinished: true)
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
            message = "Show and resume the pet to interact. Reduce Motion keeps this prototype still."
            return
        }
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        renderer.play(action)
        // A redundant wake/sleep request may be a no-op, with no completion event.
        reconcileBehaviorSchedule()
    }

    func walk() {
        guard permitsMotion else { return }
        cancelBehaviorSchedule()
        behaviorPlanner.resetAfterInteraction()
        if renderer.isSleeping { renderer.play(.wakeUp) }
        desktop.beginWalk(duration: 3)
        reconcileBehaviorSchedule()
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
        message = value ? "Spriglet will occasionally blink, look around, stretch, or nap." : "Quiet behavior is off. You can still interact with Spriglet."
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

    func refreshMeasurements() {
        sceneUpdates = renderer.sceneUpdateCount
        footprintMiB = ProcessSample.capture().footprintBytes.map { Double($0) / 1_048_576 }
    }

    func runProbe(terminateWhenFinished: Bool = false) {
        guard !sampling else { return }
        sampling = true
        cancelBehaviorSchedule()
        message = "Running a finite check. Controls return when it finishes."
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await RuntimeProbe.run(runtime: self)
                probeResult = report
                print(report.json)
                switch report.outcome {
                case .passed: message = "Automatic checks passed. Desktop interaction still needs the manual matrix."
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
            refreshMeasurements()
            probeTask = nil
            if terminateWhenFinished { NSApp.terminate(nil) }
            else { reconcileBehaviorSchedule() }
        }
    }

    func copyReport() {
        guard let report = probeResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.json, forType: .string)
    }

    func cancelProbe() {
        probeTask?.cancel()
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
        desktop?.movementFrameRate = fps
        if reduceMotion {
            desktop?.stopMovement()
            renderer.resetPose()
        }
        reconcileBehaviorSchedule()
    }

    private func savePreferences() {
        guard isRunning, !sampling, !isCommandLineProbe else { return }
        preferencesStore.save(PetPreferences(
            isHidden: isHidden, isPaused: isPaused, clickThrough: clickThrough,
            allSpaces: allSpaces, autonomousBehavior: autonomousBehavior
        ))
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
