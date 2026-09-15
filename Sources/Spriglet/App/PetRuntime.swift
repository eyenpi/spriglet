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
    private(set) var isParked = true
    private(set) var displaySize: PetDisplaySize = .standard
    private(set) var activityLevel: PetActivityLevel = .balanced
    private(set) var soundEnabled = false
    private(set) var profile = PetProfile()
    private(set) var interactionMemory = PetInteractionMemory()
    private(set) var isSleeping = false
    private(set) var hasScheduledBehavior = false
    private(set) var automaticActionCount: UInt64 = 0
    private(set) var lastAutomaticIntent: PetBehaviorIntent?
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
    @ObservationIgnored let sound = PetSoundService()
    @ObservationIgnored var onShowSettingsRequested: (@MainActor () -> Void)? {
        didSet { refreshAccessibility() }
    }
    private var policy = ActivityPolicy()
    @ObservationIgnored private var tokens: [NotificationCenter.ObservationToken] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorGeneration: UInt64 = 0
    @ObservationIgnored private var behaviorMutationDepth = 0
    @ObservationIgnored private let interactionClock = ContinuousClock()
    @ObservationIgnored private var fireflyReadyAt: ContinuousClock.Instant?
    @ObservationIgnored private var prefersLeftExcursion = true
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
        || CommandLine.arguments.contains("--desktop-acceptance")
        || CommandLine.arguments.contains("--settings-review")
        || CommandLine.arguments.contains("--diagnostics")
        || CommandLine.arguments.contains("--everyday-review")
    @ObservationIgnored private let logger = Logger(subsystem: "dev.spriglet.app", category: "lifecycle")

    init(preferencesStore: PetPreferencesStore = PetPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let preferences = isCommandLineProbe || isTemporaryReview ? PetPreferences() : preferencesStore.load()
        isHidden = preferences.isHidden
        isPaused = preferences.isPaused
        clickThrough = preferences.clickThrough
        allSpaces = preferences.allSpaces
        autonomousBehavior = preferences.autonomousBehavior
        isParked = preferences.isParked
        displaySize = preferences.displaySize
        activityLevel = preferences.activityLevel
        soundEnabled = preferences.soundEnabled
        profile = preferences.profile
        interactionMemory = preferences.interactionMemory
        initialPlacement = preferences.placement
    }

    var petName: String { profile.name }
    var traitDescription: String { profile.traitSummary }
    var recentPreferenceDescription: String {
        let recent = interactionMemory.values()
        if recent.relocation > 0.15 { return "Taking extra quiet time after being moved." }
        if recent.play > 0.15 { return "A little more rest after recent games." }
        if recent.affection > 0.15 { return "Recent pets encourage a few more friendly greetings." }
        return "A steady personality, with small preferences shaped by your interactions."
    }

    var status: String {
        if isHidden { return "Hidden" }
        if isPaused { return "Paused" }
        if !policy.allowsAnimation { return "System rest" }
        if renderer.currentRoutine == .firefly { return "Firefly play" }
        if renderer.currentRoutine == .explore { return "Exploring nearby" }
        if renderer.currentRoutine == .greet { return "Saying hello" }
        if isMoving { return "Moving" }
        if isAnimating { return "Active" }
        return isSleeping ? "Napping" : (isParked ? "Parked" : "Resting")
    }

    var permitsMotion: Bool { policy.allowsAnimation && !reduceMotion && renderer.assetError == nil }
    var canInteract: Bool { permitsMotion && !sampling }
    var canPlayWithFirefly: Bool { canInteract && !isAnimating && !isInteracting }
    var canPreviewSound: Bool { soundEnabled && policy.allowsAnimation && !sampling && !isTemporaryReview && !isCommandLineProbe }

    func start() {
        guard desktop == nil else { return }
        renderer.setDisplaySize(displaySize)
        desktop = PetWindowController(contentView: renderer, size: renderer.displaySize) { [weak renderer] point in
            renderer?.containsPet(at: point) ?? false
        }
        desktop.onPetClicked = { [weak self] in
            guard let self, !self.sampling else { return }
            self.play()
        }
        desktop.onAccessibilityPress = { [weak self] in
            guard let self, self.canInteract else { return false }
            return self.play()
        }
        desktop.onUserInteractionChanged = { [weak self] interacting in
            guard let self else { return }
            isInteracting = interacting
            if interacting {
                cancelBehaviorSchedule()
                behaviorPlanner.resetAfterInteraction()
                sound.stop()
                renderer.resetPose()
            } else {
                reconcileBehaviorSchedule()
            }
        }
        desktop.onMovementChanged = { [weak self] moving in
            self?.isMoving = moving
            if !moving { self?.refreshMeasurements() }
            self?.reconcileBehaviorSchedule()
            self?.refreshAccessibility()
        }
        desktop.onOcclusionChanged = { [weak self] visible in self?.setSuspension(.occluded, active: !visible) }
        desktop.onScreenChanged = { [weak self] in self?.refreshEnvironment() }
        desktop.onMovementInterrupted = { [weak self] in self?.renderer.resetPose() }
        desktop.onWalkRequested = { [weak self] in self?.walk() }
        desktop.onImageOffsetChanged = { [weak self] offset in self?.renderer.setImageOffset(offset) }
        desktop.onPlacementSettled = { [weak self] _ in
            self?.recordInteraction(.relocated)
            self?.savePreferences()
            self?.refreshMeasurements()
        }
        renderer.onAnimationStateChanged = { [weak self] animating in
            guard let self else { return }
            isAnimating = animating
            isSleeping = renderer.isSleeping
            if !animating { refreshMeasurements() }
            reconcileBehaviorSchedule()
            refreshAccessibility()
        }
        renderer.onPlaybackWillStart = { [weak self] timeline in
            self?.desktop.beginAuthoredMotion(timeline.rootOffsets) ?? false
        }
        renderer.onFrame = { [weak self] snapshot in
            self?.desktop.applyAuthoredFrame(snapshot) ?? false
        }
        renderer.onPlaybackStopped = { [weak self] in
            self?.desktop.finishAuthoredMotion()
            self?.sound.stop()
        }
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
        refreshSoundPolicy()
        refreshAccessibility()
        logger.info("Companion started; finite activity with a single cancellable resting deadline")
        if CommandLine.arguments.contains("--sample-review") {
            autonomousBehavior = false
            characterSample()
        } else if CommandLine.arguments.contains("--soak") {
            runSoak(terminateWhenFinished: true)
        } else if isCommandLineProbe {
            runProbe(terminateWhenFinished: true)
        } else if isTemporaryReview {
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
        refreshSoundPolicy()
        tokens.removeAll()
    }

    @discardableResult
    func play() -> Bool {
        preview(.react)
    }

    func renamePet(_ name: String) {
        let updated = PetProfile(name: name, traits: profile.traits)
        guard updated != profile else { return }
        profile = updated
        refreshAccessibility()
        savePreferences()
        message = "Name saved on this Mac. The same personality stays with your pet."
    }

    func resetRecentPreferences() {
        withBehaviorTransition {
            interactionMemory = PetInteractionMemory()
            behaviorPlanner.resetAfterInteraction()
            savePreferences(clearingRecentMemory: true)
            message = "Recent preferences cleared. The name and stable traits are unchanged."
        }
    }

    func setDisplaySize(_ value: PetDisplaySize) {
        guard value != displaySize else { return }
        withBehaviorTransition {
            displaySize = value
            desktop?.cancelInteraction()
            renderer.setDisplaySize(value)
            desktop?.setDisplaySize(value)
            sound.stop()
            savePreferences()
            refreshMeasurements()
            message = "Companion size changed to \(value.title.lowercased())."
        }
    }

    func setActivityLevel(_ value: PetActivityLevel) {
        guard value != activityLevel else { return }
        withBehaviorTransition {
            activityLevel = value
            savePreferences()
            message = value.summary
        }
    }

    func setSoundEnabled(_ value: Bool) {
        soundEnabled = value
        refreshSoundPolicy()
        savePreferences()
        message = value ? "Soft sounds are on for petting and firefly play." : "Sounds are off."
    }

    func previewSound() {
        guard canPreviewSound else { return }
        _ = sound.play(.play)
        if let error = sound.lastError { message = error }
    }

    /// Parking stops an active excursion where it is; it never teleports home.
    /// Explicit placement and short-walk commands remain available.
    func setParked(_ value: Bool) {
        guard isParked != value else { return }
        withBehaviorTransition {
            isParked = value
            if value, renderer.currentRoutine == .explore || renderer.currentRoutine == .firefly || desktop.isMoving {
                renderer.resetPose()
                desktop.stopMovement()
            }
            behaviorPlanner.resetAfterInteraction()
            savePreferences()
            message = value
                ? "Parked. Quiet moments and firefly play stay in one place; you can still move the pet yourself."
                : "Short strolls are allowed. Each one stays on this display and returns to its starting spot."
        }
    }

    @discardableResult
    func playWithFirefly() -> Bool {
        guard permitsMotion, !isAnimating, !isInteracting else { return false }
        if let fireflyReadyAt, interactionClock.now < fireflyReadyAt {
            message = "Give the firefly a little time to return before another game."
            return false
        }
        var accepted = false
        withBehaviorTransition {
            let direction = isParked || lowPower ? nil : fittingRoutine(.firefly)
            let stationary = direction == nil
            renderer.playRoutine(.firefly, direction: direction ?? .walkLeft, stationary: stationary)
            if renderer.isAnimating, renderer.currentRoutine == .firefly {
                accepted = true
                if !sampling { fireflyReadyAt = interactionClock.now.advanced(by: .seconds(20)) }
                recordInteraction(.played)
                savePreferences()
                if canPreviewSound { _ = sound.play(.play) }
                message = stationary
                    ? "A tiny visitor: watch the firefly, catch its glow, and settle."
                    : "Follow the firefly, catch its glow, then stroll back to the same spot."
            }
        }
        return accepted
    }

    @discardableResult
    func preview(_ action: PetAction) -> Bool {
        guard permitsMotion else {
            message = "Show and resume the pet to interact. Reduce Motion keeps Spriglet still."
            return false
        }
        var accepted = false
        withBehaviorTransition {
            behaviorPlanner.resetAfterInteraction()
            // Deliberate input interrupts an excursion/game. Ordinary manual
            // clips retain their resting-boundary queue and coalesce repeat pets.
            if renderer.currentRoutine != nil { renderer.resetPose() }
            accepted = renderer.play(action)
            if action == .react, accepted {
                recordInteraction(.petted)
                savePreferences()
                if canPreviewSound { _ = sound.play(.greeting) }
                message = "A little affection for \(petName)."
            } else if accepted {
                message = action == .fallAsleep ? "Settling down for a nap." : "A quiet moment together."
            }
        }
        return accepted
    }

    @discardableResult
    func walk(direction: SampleClipID? = nil) -> Bool {
        guard permitsMotion else { return false }
        var accepted = false
        withBehaviorTransition {
            behaviorPlanner.resetAfterInteraction()
            renderer.resetPose()
            guard let clip = fittingWalk(preferred: direction) else {
                message = "There is not enough room for a planted short walk in that direction. Move Spriglet away from the edge."
                return
            }
            renderer.playWalk(clip)
            accepted = renderer.isAnimating
            if accepted { message = "Taking a short walk to the \(clip == .walkLeft ? "left" : "right")." }
        }
        return accepted
    }

    func characterSample() {
        guard permitsMotion else { return }
        withBehaviorTransition {
            behaviorPlanner.resetAfterInteraction()
            renderer.resetPose()
            guard let clip = fittingWalk(preferred: nil, sample: true) else {
                message = "Move Spriglet away from the screen edge to play the complete character sample."
                return
            }
            message = "An idle moment, a planted short walk, a happy pet reaction, then settle."
            renderer.playSample(walk: clip)
        }
    }

    private func fittingWalk(preferred: SampleClipID?, sample: Bool = false) -> SampleClipID? {
        let candidates: [SampleClipID] = preferred.map { [$0] } ?? [.walkLeft, .walkRight]
        return candidates.first { direction in
            guard direction == .walkLeft || direction == .walkRight,
                  let offsets = renderer.rootOffsets(for: sample ? [.idle, direction, .pet, .settle] : [direction]) else { return false }
            return desktop.canFitRootMotion(offsets)
        }
    }

    private func fittingRoutine(_ routine: PetRoutine) -> SampleClipID? {
        let candidates: [SampleClipID] = prefersLeftExcursion ? [.walkLeft, .walkRight] : [.walkRight, .walkLeft]
        return candidates.first { direction in
            guard let offsets = renderer.routineRootOffsets(routine, direction: direction, stationary: false) else { return false }
            return desktop.canFitRootMotion(offsets)
        }
    }

    func setPaused(_ value: Bool) {
        withBehaviorTransition {
            isPaused = value
            setSuspension(.userPaused, active: value)
            message = value ? "Paused. Animation and movement have stopped." : "Resumed in a resting pose."
            savePreferences()
        }
    }

    func setHidden(_ value: Bool) {
        withBehaviorTransition {
            isHidden = value
            setSuspension(.hidden, active: value)
            if value { desktop.hide() } else { desktop.show() }
            message = value ? "Pet hidden. Settings and the leaf menu remain available." : "Your companion is visible again."
            savePreferences()
        }
    }

    func setClickThrough(_ value: Bool) {
        withBehaviorTransition {
            clickThrough = value
            desktop.setClickThrough(value)
            message = value ? "Clicks pass through the entire pet window. Use this menu to interact." : "Pet interaction enabled."
            savePreferences()
        }
    }

    func setAllSpaces(_ value: Bool) {
        withBehaviorTransition {
            allSpaces = value
            desktop.setAllSpaces(value)
            message = value ? "Your companion follows ordinary desktop Spaces." : "Your companion stays on its current desktop Space."
            savePreferences()
        }
    }

    func setAutonomousBehavior(_ value: Bool) {
        withBehaviorTransition {
            autonomousBehavior = value
            if !value, renderer.currentRoutine == .explore { renderer.resetPose() }
            savePreferences()
            message = value
                ? "Quiet moments are on. Parked mode keeps them in one place; otherwise an occasional stroll returns to the same spot."
                : "Quiet behavior is off. You can still pet, play, and place your companion."
        }
    }

    func recenter() {
        withBehaviorTransition {
            behaviorPlanner.resetAfterInteraction()
            desktop.recenter()
            message = "Your companion is back at its home position."
        }
    }

    func moveToNextDisplay() {
        withBehaviorTransition {
            behaviorPlanner.resetAfterInteraction()
            desktop.moveToNextDisplay()
            refreshEnvironment()
            message = "Display placement updated."
        }
    }

    func nudge(dx: CGFloat = 0, dy: CGFloat = 0) {
        withBehaviorTransition {
            behaviorPlanner.resetAfterInteraction()
            desktop.nudge(dx: dx, dy: dy)
            refreshMeasurements()
            message = "Companion placement updated."
        }
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
        refreshSoundPolicy()
        refreshAccessibility()
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
            refreshSoundPolicy()
            refreshAccessibility()
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
        withBehaviorTransition {
            policy.set(reason, active: active)
            let suspended = !policy.allowsAnimation
            if suspended {
                desktop?.cancelInteraction()
                desktop?.stopMovement()
            }
            renderer.setSuspended(suspended)
            refreshSoundPolicy()
            refreshMeasurements()
        }
    }

    private func refreshEnvironment() {
        applyEnvironmentPolicy(
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func applyEnvironmentPolicy(lowPower newLowPower: Bool, reduceMotion newReduceMotion: Bool) {
        withBehaviorTransition {
            let enteringLowPower = !lowPower && newLowPower
            lowPower = newLowPower
            reduceMotion = newReduceMotion
            let thermal = ProcessInfo.processInfo.thermalState
            setSuspension(.thermalPressure, active: thermal == .serious || thermal == .critical)
            let maxFPS = desktop?.panel.screen?.maximumFramesPerSecond ?? 60
            renderer.setPreferredFramesPerSecond(lowPower ? 30 : maxFPS)
            if reduceMotion || (enteringLowPower && (renderer.currentRoutine == .explore || renderer.currentRoutine == .firefly)) {
                desktop?.stopMovement()
                renderer.resetPose()
            }
        }
    }

    #if SPRIGLET_BEHAVIOR_VALIDATION
    /// The native validation executable shortens only the requested deadline;
    /// production eligibility, cancellation, rendering and placement still run.
    func scheduleBehaviorForValidation(_ plan: PlannedBehavior) {
        scheduleBehavior(plan)
    }

    func setEnvironmentForValidation(lowPower: Bool, reduceMotion: Bool) {
        applyEnvironmentPolicy(lowPower: lowPower, reduceMotion: reduceMotion)
    }
    #endif

    private func savePreferences(clearingRecentMemory: Bool = false) {
        guard isRunning, !sampling, !isCommandLineProbe, !isTemporaryReview else { return }
        let preferences = snapshotPreferencesForProbe()
        if clearingRecentMemory { preferencesStore.saveClearingRecentMemory(preferences) }
        else { preferencesStore.save(preferences) }
    }

    private func refreshSoundPolicy() {
        sound.setEnabled(soundEnabled && isRunning && !isCommandLineProbe && !isTemporaryReview)
        sound.setSuspended(!policy.allowsAnimation || sampling)
    }

    /// Only name, settings and finite state transitions update accessibility.
    /// Neither rendering ticks nor a global event monitor are involved.
    private func refreshAccessibility() {
        guard let desktop, behaviorMutationDepth == 0 else { return }
        var actions: [NSAccessibilityCustomAction] = []
        func command(_ name: String, _ perform: @escaping @MainActor (PetRuntime) -> Bool) {
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, !self.sampling else { return false }
                return perform(self)
            })
        }
        if !sampling {
            if canPlayWithFirefly {
                command(AppText.playWithFirefly) { $0.canPlayWithFirefly && $0.playWithFirefly() }
            }
            if canInteract {
                let wasSleeping = isSleeping
                command(wasSleeping ? "Wake up" : "Take a nap") {
                    guard $0.canInteract, $0.isSleeping == wasSleeping else { return false }
                    return $0.preview(wasSleeping ? .wakeUp : .fallAsleep)
                }
            }
            let targetParked = !isParked
            command(targetParked ? "Park here" : "Allow strolls") {
                guard $0.isParked != targetParked else { return false }
                $0.setParked(targetParked)
                return true
            }
            let targetPaused = !isPaused
            command(targetPaused ? AppText.pause : AppText.resume) {
                guard $0.isPaused != targetPaused else { return false }
                $0.setPaused(targetPaused)
                return true
            }
            command("Bring pet home") { $0.recenter(); return true }
            command("Move left") { $0.nudge(dx: -48); return true }
            command("Move right") { $0.nudge(dx: 48); return true }
            command("Move up") { $0.nudge(dy: 48); return true }
            command("Move down") { $0.nudge(dy: -48); return true }
        }
        if onShowSettingsRequested != nil {
            actions.append(NSAccessibilityCustomAction(name: "Open Settings") { [weak self] in
                guard let handler = self?.onShowSettingsRequested else { return false }
                handler()
                return true
            })
        }
        desktop.updateAccessibility(name: "\(petName), desktop companion",
            status: "\(status), \(displaySize.title.lowercased()) size", canPress: canInteract, actions: actions)
    }

    func snapshotPreferencesForProbe() -> PetPreferences {
        PetPreferences(
            isHidden: isHidden, isPaused: isPaused, clickThrough: clickThrough,
            allSpaces: allSpaces, autonomousBehavior: autonomousBehavior,
            placement: desktop.savedPlacement, profile: profile,
            interactionMemory: interactionMemory, isParked: isParked,
            displaySize: displaySize, activityLevel: activityLevel, soundEnabled: soundEnabled
        )
    }

    /// Reentrant renderer/window callbacks cannot schedule between reset and
    /// begin, consume another suggestion, or leave a stale deadline behind.
    private func withBehaviorTransition(_ update: () -> Void) {
        behaviorMutationDepth += 1
        cancelBehaviorSchedule()
        defer {
            behaviorMutationDepth -= 1
            if behaviorMutationDepth == 0 {
                reconcileBehaviorSchedule()
                refreshAccessibility()
            }
        }
        update()
    }

    private func recordInteraction(_ kind: PetInteractionKind) {
        guard isRunning, !sampling, !isCommandLineProbe, !isTemporaryReview else { return }
        interactionMemory.record(kind)
        behaviorPlanner.resetAfterInteraction()
        cancelBehaviorSchedule()
    }

    private func reconcileBehaviorSchedule() {
        guard behaviorMutationDepth == 0, isRunning, autonomousBehavior, !sampling, permitsMotion,
              desktop.panel.isOnActiveSpace, !isAnimating, !isMoving, !isInteracting else {
            cancelBehaviorSchedule()
            return
        }
        guard behaviorTask == nil else { return }
        scheduleBehavior(behaviorPlanner.next(
            isSleeping: renderer.isSleeping, profile: profile, memory: interactionMemory,
            now: .now, canWander: !isParked, lowPower: lowPower, activityLevel: activityLevel
        ))
    }

    private func cancelBehaviorSchedule() {
        behaviorGeneration &+= 1
        behaviorTask?.cancel()
        behaviorTask = nil
        hasScheduledBehavior = false
    }

    private func scheduleBehavior(_ plan: PlannedBehavior, duringProbe: Bool = false) {
        cancelBehaviorSchedule()
        guard plan.delaySeconds.isFinite, plan.delaySeconds >= 0 else { return }
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
                  desktop.panel.isOnActiveSpace, !isAnimating, !isMoving, !isInteracting,
                  !sampling || duringProbe else { return }
            performBehavior(plan.intent, duringProbe: duringProbe)
        }
    }

    private func performBehavior(_ intent: PetBehaviorIntent, duringProbe: Bool) {
        withBehaviorTransition {
            var performed = intent
            let wasSleeping = renderer.isSleeping
            switch intent {
            case .explore:
                // Recheck the complete route when the deadline fires. Parking,
                // power changes and geometry may differ from planning time.
                if !isParked, !lowPower, let direction = fittingRoutine(.explore) {
                    renderer.playRoutine(.explore, direction: direction, stationary: false)
                    if renderer.isAnimating { prefersLeftExcursion = direction == .walkRight }
                } else {
                    performed = .observe
                    renderer.playRoutine(.observe)
                }
            case .observe: renderer.playRoutine(.observe)
            case .greet: renderer.playRoutine(.greet)
            case .nap: renderer.play(.fallAsleep)
            case .wake: renderer.play(.wakeUp)
            }
            if renderer.isAnimating || renderer.isSleeping != wasSleeping {
                automaticActionCount &+= 1
                lastAutomaticIntent = performed
                if !duringProbe { behaviorPlanner.didPerform(performed) }
            }
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
        withBehaviorTransition {
            desktop.stopMovement()
            renderer.resetPose()
            profile = preferences.profile
            interactionMemory = preferences.interactionMemory
            isParked = preferences.isParked
            setDisplaySize(preferences.displaySize)
            activityLevel = preferences.activityLevel
            soundEnabled = preferences.soundEnabled
            refreshSoundPolicy()
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
    }

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.ActiveSpaceDidChangeMessage.self) { [weak self] _ in
            await self?.activeSpaceChanged()
        })
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

    private func activeSpaceChanged() {
        withBehaviorTransition {
            if desktop?.panel.isOnActiveSpace == false {
                desktop.stopMovement()
                renderer.resetPose()
            }
        }
    }
}
