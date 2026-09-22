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

    let character: PetAssetDefinition
    @ObservationIgnored let renderer: PetRenderView
    @ObservationIgnored let characterResourceDirectory: URL?
    @ObservationIgnored private(set) var desktop: PetWindowController!
    @ObservationIgnored let sound = PetSoundService()
    @ObservationIgnored var onShowSettingsRequested: (@MainActor () -> Void)? {
        didSet { refreshAccessibility() }
    }
    @ObservationIgnored private var world = PetWorldSnapshot()
    @ObservationIgnored private let environment: any EnvironmentObserving
    @ObservationIgnored private let deadlines: any DeadlineScheduling
    @ObservationIgnored private let awareness: PetAwarenessCoordinator
    @ObservationIgnored private let contextCoordinator: PetContextCoordinator
    @ObservationIgnored private var reactiveBehavior: ReactiveBehaviorCoordinator?
    /// Observable projection of the world policy for menu and Settings updates.
    private var policy = ActivityPolicy()
    private var scene: any PetSceneRenderer { renderer }
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var behaviorGeneration: UInt64 = 0
    @ObservationIgnored private var behaviorMutationDepth = 0
    @ObservationIgnored private let interactionClock = ContinuousClock()
    @ObservationIgnored private var fireflyReadyAt: ContinuousClock.Instant?
    @ObservationIgnored private var prefersLeftExcursion = true
    @ObservationIgnored private var behaviorDirector: any BehaviorDirector = LegacyBehaviorDirector(seed: UInt64.random(in: .min ... .max))
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

    init(preferencesStore: PetPreferencesStore = PetPreferencesStore(),
         character: PetAssetDefinition = .acornHopper, resourceBundle: Bundle = .main,
         environment: any EnvironmentObserving = AppKitEnvironmentSource(),
         pointerSource: any PointerObserving = AppKitPointerSource(),
         contextSource: (any ContextObserving)? = nil,
         userActivitySource: (any UserActivityObserving)? = nil,
         wakeMovementSource: (any WakeMovementObserving)? = nil,
         deadlines: any DeadlineScheduling = DeadlineScheduler()) {
        self.environment = environment
        self.deadlines = deadlines
        awareness = PetAwarenessCoordinator(source: pointerSource, scheduler: deadlines)
        contextCoordinator = PetContextCoordinator(
            context: contextSource ?? ContextSource(scheduler: deadlines),
            userActivity: userActivitySource ?? UserActivitySource(),
            wakeMovement: wakeMovementSource ?? WakeMovementSource(),
            scheduler: deadlines
        )
        self.preferencesStore = preferencesStore
        self.character = character
        characterResourceDirectory = character.resourceDirectory(in: resourceBundle)
        renderer = PetRenderView(frame: NSRect(x: 0, y: 0, width: 224, height: 224),
                                 resourceDirectory: characterResourceDirectory)
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
    var pointerCounters: PointerSourceCounters { awareness.counters }
    var characterPreviewURL: URL? {
        guard let package = renderer.characterPackage,
              let file = package.poses[package.animationGraph.defaultPoseID]?.stillFrame else { return nil }
        return characterResourceDirectory?.appendingPathComponent(file)
    }
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
            scene.perform(.interactionHeld(interacting))
            if interacting {
                reactiveBehavior?.suppressCurrentApproach()
                cancelBehaviorSchedule()
                behaviorDirector.resetAfterInteraction()
                sound.stop()
                refreshWorld()
                reconcileAwareness()
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
        desktop.onMovementInterrupted = { [weak self] in self?.scene.perform(.resetPose) }
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
            if animating { reactiveBehavior?.suppressCurrentApproach() }
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
        awareness.onStimulus = { [weak self] update in
            guard let self else { return }
            receive(.pointer(perception: update.perception, attention: update.attention))
            guard isRunning else { return }
            for command in PointerIntentDirector.commands(in: world) { scene.perform(command) }
            _ = reactiveBehavior?.receive(world: world)
        }
        contextCoordinator.onFact = { [weak self] fact in
            self?.receiveContextFact(fact)
        }
        if let characterIssue { message = characterIssue }
        desktop.setClickThrough(clickThrough)
        desktop.setAllSpaces(allSpaces)
        desktop.restorePlacement(initialPlacement)
        reconcilePlaybackContext()
        configureReactiveBehavior()
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
            reconcileBehaviorSchedule()
        } else {
            reconcileBehaviorSchedule()
        }
    }

    func stop() {
        isRunning = false
        awareness.stop()
        contextCoordinator.stop()
        contextCoordinator.onFact = nil
        deadlines.cancelAll()
        cancelBehaviorSchedule()
        probeTask?.cancel()
        probeTask = nil
        desktop?.stopMovement()
        scene.perform(.suspended(true))
        refreshSoundPolicy()
        environment.stop()
        environment.onEvent = nil
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
            behaviorDirector.resetAfterInteraction()
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
            desktop?.setDisplaySize(renderer.displaySize)
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
                scene.perform(.resetPose)
                desktop.stopMovement()
            }
            behaviorDirector.resetAfterInteraction()
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
            scene.perform(.routine(.firefly, direction: direction ?? .walkLeft, stationary: stationary))
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
            behaviorDirector.resetAfterInteraction()
            // Finish the current authored landing/settle, then honor the latest
            // interaction. A sleeping pet wakes through its authored bridge.
            accepted = scene.perform(.action(action))
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
            behaviorDirector.resetAfterInteraction()
            guard let clip = fittingWalk(preferred: direction) else {
                message = "There is not enough room for a planted short walk in that direction. Move Spriglet away from the edge."
                return
            }
            accepted = scene.perform(.transition(clip == .walkLeft ? .moveLeft : .moveRight))
            if accepted { message = "Taking a short walk to the \(clip == .walkLeft ? "left" : "right")." }
        }
        return accepted
    }

    func characterSample() {
        guard permitsMotion else { return }
        withBehaviorTransition {
            behaviorDirector.resetAfterInteraction()
            scene.perform(.resetPose)
            guard let clip = fittingWalk(preferred: nil, sample: true) else {
                message = "Move Spriglet away from the screen edge to play the complete character sample."
                return
            }
            message = "An idle moment, a planted short walk, a happy pet reaction, then settle."
            scene.perform(.sample(walk: clip))
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
            if !value, renderer.currentRoutine == .explore { scene.perform(.resetPose) }
            savePreferences()
            message = value
                ? "Quiet moments are on. Parked mode keeps them in one place; otherwise an occasional stroll returns to the same spot."
                : "Quiet behavior is off. You can still pet, play, and place your companion."
        }
    }

    func recenter() {
        withBehaviorTransition {
            behaviorDirector.resetAfterInteraction()
            desktop.recenter()
            message = "Your companion is back at its home position."
        }
    }

    func moveToNextDisplay() {
        withBehaviorTransition {
            behaviorDirector.resetAfterInteraction()
            desktop.moveToNextDisplay()
            refreshEnvironment()
            message = "Display placement updated."
        }
    }

    func nudge(dx: CGFloat = 0, dy: CGFloat = 0) {
        withBehaviorTransition {
            behaviorDirector.resetAfterInteraction()
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
        refreshWorld()
        reconcileAwareness()
        reconcileContext()
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
            receive(.suspension(reason: reason, active: active))
            let suspended = !policy.allowsAnimation
            if suspended {
                desktop?.cancelInteraction()
                desktop?.stopMovement()
            }
            scene.perform(.suspended(suspended))
            refreshSoundPolicy()
            refreshMeasurements()
        }
    }

    private func refreshEnvironment() {
        applyEnvironmentPolicy(environment.currentSnapshot())
    }

    private func applyEnvironmentPolicy(_ snapshot: EnvironmentSnapshot) {
        withBehaviorTransition {
            let enteringLowPower = !lowPower && snapshot.lowPower
            lowPower = snapshot.lowPower
            reduceMotion = snapshot.reduceMotion
            receive(.lowPower(lowPower))
            receive(.reduceMotion(reduceMotion))
            setSuspension(.thermalPressure, active: snapshot.thermalPressure.requiresRest)
            let maxFPS = desktop?.panel.screen?.maximumFramesPerSecond ?? 60
            scene.perform(.preferredFramesPerSecond(lowPower ? 30 : maxFPS))
            reconcilePlaybackContext()
            if reduceMotion || (enteringLowPower && (renderer.currentRoutine == .explore || renderer.currentRoutine == .firefly)) {
                desktop?.stopMovement()
                scene.perform(.resetPose)
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
        applyEnvironmentPolicy(EnvironmentSnapshot(lowPower: lowPower, reduceMotion: reduceMotion,
                                                   thermalPressure: environment.currentSnapshot().thermalPressure))
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
        behaviorDirector.resetAfterInteraction()
        cancelBehaviorSchedule()
    }

    private func reconcileBehaviorSchedule() {
        guard behaviorMutationDepth == 0 else { return }
        refreshWorld()
        reconcileAwareness()
        reconcileContext()
        guard isRunning, autonomousBehavior, !world.isSleeping,
              !sampling, renderer.assetError == nil,
              world.allowsAutonomousBehavior else {
            cancelBehaviorSchedule()
            return
        }
        guard !hasScheduledBehavior else { return }
        scheduleBehavior(behaviorDirector.next(
            in: world, profile: profile, memory: interactionMemory, now: .now
        ))
    }

    private func cancelBehaviorSchedule() {
        behaviorGeneration &+= 1
        deadlines.cancel(.autonomousBehavior)
        hasScheduledBehavior = false
    }

    private func scheduleBehavior(_ plan: PlannedBehavior, duringProbe: Bool = false) {
        cancelBehaviorSchedule()
        guard plan.delaySeconds.isFinite, plan.delaySeconds >= 0 else { return }
        guard let deadline = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime + plan.delaySeconds) else { return }
        let generation = behaviorGeneration
        hasScheduledBehavior = true
        deadlines.schedule(.autonomousBehavior, at: deadline) { [weak self] in
            guard let self, generation == behaviorGeneration else { return }
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
                    scene.perform(.routine(.explore, direction: direction, stationary: false))
                    if renderer.isAnimating { prefersLeftExcursion = direction == .walkRight }
                } else {
                    performed = .observe
                    scene.perform(.routine(.observe))
                }
            case .observe: scene.perform(.routine(.observe))
            case .greet: scene.perform(.routine(.greet))
            case .nap: scene.perform(.action(.fallAsleep))
            case .wake: scene.perform(.action(.wakeUp))
            }
            if renderer.isAnimating || renderer.isSleeping != wasSleeping {
                automaticActionCount &+= 1
                lastAutomaticIntent = performed
                if !duringProbe { behaviorDirector.didPerform(performed, at: .now) }
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
            scene.perform(.resetPose)
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
        environment.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .activeSpaceChanged: activeSpaceChanged()
            case .policyChanged(let snapshot): applyEnvironmentPolicy(snapshot)
            case .context(let stimulus): contextCoordinator.submit(stimulus)
            case .suspension(let reason, let active):
                let reason: SuspensionReason = switch reason {
                case .displayAsleep: .displayAsleep
                case .systemAsleep: .systemAsleep
                case .sessionInactive: .sessionInactive
                }
                setSuspension(reason, active: active)
            }
        }
        environment.start()
    }

    private func receive(_ event: PetStimulus.Event) {
        guard let timestamp = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime) else { return }
        world = WorldReducer.reduce(world, PetStimulus(timestamp: timestamp, event: event))
        if policy != world.activityPolicy { policy = world.activityPolicy }
    }

    /// Synchronize only at semantic boundaries, never on a rendering tick.
    private func refreshWorld() {
        receive(.sleeping(renderer.isSleeping))
        receive(.wanderingAvailability(!isParked))
        receive(.activityLevel(activityLevel))
        receive(.activeSpace(desktop?.panel.isOnActiveSpace ?? false))
        receive(.interaction(isInteracting))
        receive(.animating(isAnimating))
        receive(.moving(isMoving))
        receive(.habitat(desktop?.currentHabitat))
        receive(.petBounds(desktop.map {
            CGRect(origin: $0.effectiveOrigin, size: renderer.displaySize)
        }))
    }

    private func reconcilePlaybackContext() {
        guard let package = renderer.characterPackage else { return }
        renderer.setPlaybackContext(CharacterPlaybackContext(
            capabilityIDs: Set(package.capabilities),
            habitatID: "desktop",
            reduceMotion: reduceMotion
        ))
    }

    private func configureReactiveBehavior() {
        guard reactiveBehavior == nil,
              let root = characterResourceDirectory,
              let package = renderer.characterPackage else { return }
        let url = root.appendingPathComponent("reactive/behavior.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let policy = try ReactiveBehaviorPolicy.decode(Data(contentsOf: url))
            let renderer = self.renderer
            let desktop = self.desktop
            reactiveBehavior = try ReactiveBehaviorCoordinator(
                policy: policy,
                characterIdentifier: package.identifier,
                traits: profile.traits,
                capabilityIDs: Set(package.capabilities),
                previewIntent: { [weak renderer] in renderer?.previewIntent($0) },
                canFitRootMotion: { [weak desktop] in desktop?.canFitRootMotion($0) == true },
                performIntent: { [weak renderer] in
                    renderer?.perform(.intent($0, priority: .contextual)) == true
                }
            )
        } catch {
            // Optional character behavior fails closed without disabling the
            // character's rest rig, direct interaction, or legacy routines.
            logger.error("Reactive character behavior disabled: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Composition wiring only; perception, hysteresis, and intent selection
    /// stay in their own reusable boundaries.
    private func reconcileAwareness() {
        awareness.update(policy: PointerAwarenessPolicy(
            isAwake: !world.isSleeping,
            isVisible: isRunning && !isHidden && world.isOnActiveSpace,
            isSuspended: world.isSuspended,
            isPaused: isPaused,
            isInteracting: world.isInteracting,
            isConstrained: world.isAnimating || world.isMoving || world.isReduceMotion || sampling || isCommandLineProbe,
            isLowPower: world.isLowPower
        ), petBounds: world.petBounds)
    }

    private func reconcileContext() {
        let reasons = world.activityPolicy.reasons
        contextCoordinator.update(policy: PetContextPolicy(
            isSleeping: world.isSleeping,
            isVisible: isRunning && !isHidden && world.isOnActiveSpace
                && !reasons.contains(.occluded),
            isPaused: isPaused || sampling || world.isInteracting
                || world.isAnimating || world.isMoving,
            isSessionActive: !reasons.contains(.sessionInactive),
            isSystemAwake: !reasons.contains(.systemAsleep),
            isDisplayAwake: !reasons.contains(.displayAsleep),
            isThermallyConstrained: reasons.contains(.thermalPressure),
            automaticMomentsEnabled: autonomousBehavior && !isCommandLineProbe
                && !isTemporaryReview
        ))
    }

    private func receiveContextFact(_ fact: UserActivityContextFact) {
        refreshWorld()
        guard let intent = ContextIntentDirector.intent(
            for: fact, in: world,
            automaticMomentsEnabled: autonomousBehavior && !isCommandLineProbe
                && !isTemporaryReview
        ) else { return }
        withBehaviorTransition {
            let accepted: Bool
            let recorded: PetBehaviorIntent
            switch intent {
            case .wake:
                recorded = .wake
                accepted = scene.perform(.action(.wakeUp))
            case .nap:
                recorded = .nap
                accepted = scene.perform(.action(.fallAsleep))
            case .appGlance:
                recorded = .observe
                accepted = scene.perform(.phrase("gaze"))
            }
            if accepted {
                automaticActionCount &+= 1
                lastAutomaticIntent = recorded
                behaviorDirector.didPerform(recorded, at: .now)
            }
        }
    }

    private func activeSpaceChanged() {
        withBehaviorTransition {
            if desktop?.panel.isOnActiveSpace == false {
                desktop.stopMovement()
                scene.perform(.resetPose)
            }
        }
    }
}
