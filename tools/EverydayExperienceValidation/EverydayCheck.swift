import AppKit
import CryptoKit
import Darwin
import SprigletCore

/// Native provider/action and size integration, not a spoken VoiceOver test.
@main
enum EverydayCheck {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard !["--probe", "--soak", "--sample-review", "--welcome-review", "--desktop-acceptance",
                "--settings-review", "--diagnostics", "--everyday-review"].contains(where: arguments.contains) else {
            print("Use the packaged EverydayCheck with only --output <report.json>.")
            exit(2)
        }
        let output = arguments.firstIndex(of: "--output").flatMap { index in
            index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = EverydayRunner(output: output)
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}

private enum Outcome: String, Codable { case passed, failed, blocked }
private struct Check: Codable { let name: String; let outcome: Outcome; let detail: String }
private enum ValidationError: Error { case blocked(String) }

private struct BuildEvidence: Codable {
    let sourceSHA256: [String: String]
    let assetSHA256: [String: String]
    let swiftVersion: String
    let sdkVersion: String
    let compilerFlags: [String]
}

private struct AlphaProbes: Decodable {
    struct Probe: Decodable {
        let name: String
        let normalizedBottomLeft: SamplePoint
        let expectedHit: Bool
    }
    let manifestSHA256: String
    let hitTestProbes: [Probe]
}

private struct Snapshot: Codable {
    let submittedFrames: UInt64
    let displayLinkCallbacks: UInt64
    let movementApplications: UInt64
    let completedRoutines: UInt64
    let automaticActions: UInt64
    let animating: Bool
    let displayLinkActive: Bool
    let toyVisible: Bool
    let bufferedFrames: Int
    let deadlineScheduled: Bool
    let effectiveOrigin: [Double]
    let panelSize: [Double]
    let viewSize: [Double]
    let backingScale: Double
    let visible: Bool
    let onActiveSpace: Bool
    let occluded: Bool
    let appActive: Bool
    let keyWindow: Bool

    @MainActor
    init(_ runtime: PetRuntime) {
        let renderer = runtime.renderer
        let desktop = runtime.desktop!
        submittedFrames = renderer.submittedFrameCount
        displayLinkCallbacks = renderer.displayLinkCallbackCount
        movementApplications = desktop.movementTickCount
        completedRoutines = renderer.completedRoutineCount
        automaticActions = runtime.automaticActionCount
        animating = renderer.isAnimating
        displayLinkActive = renderer.hasActiveDisplayLink
        toyVisible = renderer.fireflyVisible
        bufferedFrames = renderer.bufferedFrameCount
        deadlineScheduled = runtime.hasScheduledBehavior
        effectiveOrigin = [desktop.effectiveOrigin.x, desktop.effectiveOrigin.y]
        panelSize = [desktop.panel.frame.width, desktop.panel.frame.height]
        viewSize = [renderer.bounds.width, renderer.bounds.height]
        backingScale = desktop.panel.backingScaleFactor
        visible = desktop.panel.isVisible
        onActiveSpace = desktop.panel.isOnActiveSpace
        occluded = !desktop.panel.occlusionState.contains(.visible)
        appActive = NSApp.isActive
        keyWindow = desktop.panel.isKeyWindow
    }

    func stayedStill(since earlier: Self) -> Bool {
        submittedFrames == earlier.submittedFrames && displayLinkCallbacks == earlier.displayLinkCallbacks
            && movementApplications == earlier.movementApplications && automaticActions == earlier.automaticActions
            && effectiveOrigin == earlier.effectiveOrigin && !animating && !displayLinkActive && !toyVisible
    }
}

private struct Playback: Codable {
    let size: String
    let routine: String
    let direction: String
    var acceptedFrames = 0
    var rejectedFrames = 0
    var frameRootMismatches = 0
    var committedFrameRootMismatches = 0
    var maximumEffectiveOriginErrorPoints = 0.0
    var maximumExcursionPoints = 0.0
    var maximumBufferCount = 0
    var toySamples = 0
    var toyBoundsFailures = 0
    var toyScaleFailures = 0
    var clipsSeen: [String] = []
    var settled: Snapshot?
}

private struct StateObservation: Codable {
    let name: String
    let primaryPressAllowed: Bool
    let elementEnabled: Bool
    let customActionNames: [String]
    let snapshot: Snapshot
}

private struct Report: Encodable {
    let schemaVersion = 1
    let evidenceKind = "native-accessibility-provider-actions-and-size-integration"
    let startedAt: Date
    let endedAt: Date
    let elapsedSeconds: Double
    let outcome: Outcome
    let operatingSystem: String
    let actualLowPowerMode: Bool
    let actualReduceMotion: Bool
    let actualVoiceOverEnabledAtStart: Bool
    let actualVoiceOverEnabledAtEnd: Bool
    let screenCount: Int
    let checks: [Check]
    let playback: [Playback]
    let states: [StateObservation]
    let build: BuildEvidence?
    let executableSHA256: String?
    let actualAssetSHA256: [String: String]
    let limits = [
        "Build alone never launches the harness. A run displays only its own nonactivating pet panel with Pass Clicks Through enabled.",
        "Accessibility properties/actions are read and invoked directly on the actual native provider. This does not establish spoken output, rotor discoverability, VoiceOver focus order, or assistive-client delivery.",
        "No VoiceOver or macOS keyboard-navigation setting is changed. Production SwiftUI Settings and keyboard-command navigation require their separate app review.",
        "Constructed local mouse events exercise held-drag cancellation only. They are not injected into the desktop and do not establish physical input routing or keyboard focus.",
        "Display-size and missing-home checks use current desktop geometry and a synthetic absent display identity, not hardware disconnect/reconnect or real sleep/wake.",
        "Image/root/toy observations concern application callbacks and layer geometry, not atomic compositor presentation, animation appearance, GPU load, battery cost, or long resource behavior.",
        "The harness uses a UUID defaults domain and never invokes login registration. Sound persistence is changed only while paused, then disabled before any action, so it performs no audible review.",
        "Open Settings invokes a fixture callback to check action wiring; opening the production Settings scene is tested separately. No pet name or serialized profile is included in this report."
    ]
}

@MainActor
private final class EverydayRunner: NSObject, NSApplicationDelegate {
    private let output: URL?
    private let suiteName = "dev.spriglet.everyday-validation.\(UUID().uuidString)"
    private let clock = ContinuousClock()
    private var began = ContinuousClock.now
    private var startedAt = Date()
    private var defaults: UserDefaults!
    private var store: PetPreferencesStore!
    private var runtime: PetRuntime!
    private var task: Task<Void, Never>?
    private var finishing = false
    private var checks: [Check] = []
    private var playback: [Playback] = []
    private var states: [StateObservation] = []
    private var build: BuildEvidence?
    private var assets: [String: String] = [:]
    private var executableSHA256: String?
    private var probes: AlphaProbes?
    private var activePlayback: Int?
    private var motionStart = CGPoint.zero
    private var settingsRequests = 0
    private var placementSettlements = 0
    private var observedKeyWindow = false
    private var observedAppActive = false
    private var voiceOverAtStart = false
    private var actualLowPower = false
    private var actualReduceMotion = false
    private var displayCount = 0
    private var element: PetInteractionView { runtime.desktop.panel.contentView as! PetInteractionView }
    private var pressSelector: Selector { #selector(PetInteractionView.accessibilityPerformPress) }

    init(output: URL?) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startedAt = .now
        began = clock.now
        voiceOverAtStart = NSWorkspace.shared.isVoiceOverEnabled
        actualLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        actualReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        displayCount = NSScreen.screens.count
        task = Task { [weak self] in await self?.run() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finishing { return .terminateNow }
        task?.cancel()
        return .terminateCancel
    }

    private func run() async {
        do {
            try loadEvidence()
            defaults = UserDefaults(suiteName: suiteName)
            guard defaults != nil else { throw ValidationError.blocked("A temporary preferences domain was unavailable.") }
            defaults.removePersistentDomain(forName: suiteName)
            store = PetPreferencesStore(defaults: defaults)
            store.save(PetPreferences(isHidden: true, clickThrough: true, allSpaces: false, autonomousBehavior: false))
            runtime = PetRuntime(preferencesStore: store)
            runtime.onShowSettingsRequested = { [weak self] in self?.settingsRequests += 1 }
            runtime.start()
            runtime.desktop.panel.isRestorable = false
            runtime.desktop.panel.disableSnapshotRestoration()
            installFrameObservation()
            check("actual-assets-loaded-sound-off", runtime.renderer.assetError == nil && !runtime.soundEnabled,
                  "The runtime loaded the copied authored sample and retained the default-disabled sound setting.")
            guard runtime.renderer.assetError == nil else { finish(); return }
            guard displayCount > 0 else { throw ValidationError.blocked("No native desktop display was available.") }
            runtime.setHidden(false)
            try await pause(0.5)
            try requireEnvironment()
            positionSafely()
            try await checkAccessibility()
            try await checkSizes()
            try await checkResizeCancellation()
            try checkEdgeAndMissingHome()
            try await checkPersistenceAndSampling()
            runtime.setAutonomousBehavior(false)
            runtime.renderer.resetPose()
            let rest = Snapshot(runtime)
            try await pause(0.75)
            check("final-static-rest", Snapshot(runtime).stayedStill(since: rest) && !runtime.hasScheduledBehavior,
                  "The final short settled interval had no continuing image, display-link, movement, toy, or behavior work.")
            check("own-panel-never-key-at-samples", !observedKeyWindow,
                  "Neither accessibility actions nor size changes made the nonactivating pet panel key at sampled points.")
            check("own-app-inactive-at-samples", !observedAppActive,
                  "The harness remained inactive at sampled points. This is not continuous physical cross-app focus evidence.")
        } catch ValidationError.blocked(let reason) {
            checks.append(Check(name: "native-environment", outcome: .blocked, detail: reason))
        } catch is CancellationError {
            checks.append(Check(name: "completed-run", outcome: .blocked, detail: "The finite check was cancelled before all cases finished."))
        } catch {
            checks.append(Check(name: "evidence", outcome: .failed, detail: "The harness could not read or write its own evidence: \(error.localizedDescription)"))
        }
        finish()
    }

    private func checkAccessibility() async throws {
        runtime.renamePet("  Maple   Friend  ")
        check("native-accessibility-identity-and-state", element.isAccessibilityElement() && element.accessibilityRole() == .button
              && element.accessibilityIdentifier() == "spriglet.pet.interaction"
              && element.accessibilityLabel() == "\(runtime.petName), desktop companion"
              && !(element.accessibilityValue() as? String ?? "").isEmpty,
              "The actual native button exposes its current name, a stable identifier, and a readable state value.")
        check("native-press-selector-available", element.isAccessibilitySelectorAllowed(pressSelector) && element.isAccessibilityEnabled(),
              "Primary press is advertised while the live runtime accepts petting; the element remains available to assistive clients.")
        let completed = runtime.renderer.completedRoutineCount
        let pressed = element.accessibilityPerformPress()
        let reaction = runtime.renderer.isAnimating
        _ = try await waitUntil(timeout: 5) { !self.runtime.renderer.isAnimating }
        check("native-primary-press-triggers-pet", pressed && reaction && runtime.interactionMemory.values().affection > 0
              && runtime.renderer.completedRoutineCount == completed,
              "The provider's primary action triggered the real accepted pet request and deliberate-interaction memory; an ordinary clip is not a routine completion.")
        observeState("ordinary")

        let openBefore = settingsRequests
        check("native-settings-action-calls-request-handler", invoke("Open Settings") && settingsRequests == openBefore + 1,
              "The exported custom action invoked the installed settings-request callback once, without opening a window in this harness.")
        let initialParked = runtime.isParked
        let retainedParkAction = action(named: initialParked ? "Allow strolls" : "Park here")
        check("native-park-action-toggles", retainedParkAction?.handler?() == true && runtime.isParked != initialParked,
              "The actual exported park action changed runtime policy and its subsequent action name.")
        let parkedAfterAction = runtime.isParked
        check("retained-park-action-keeps-named-intent", retainedParkAction?.handler?() == false && runtime.isParked == parkedAfterAction,
              "Reinvoking an old native Park/Allow action after its target state was reached rejected the stale request instead of reversing its meaning.")
        _ = invoke(runtime.isParked ? "Allow strolls" : "Park here")

        let paused = invoke("Pause")
        let beforeRejected = Snapshot(runtime)
        let rejected = !element.accessibilityPerformPress()
        observeState("paused")
        check("paused-primary-absent-resume-retained", paused && runtime.isPaused && rejected
              && !element.isAccessibilitySelectorAllowed(pressSelector) && element.isAccessibilityEnabled()
              && action(named: "Resume") != nil && Snapshot(runtime).stayedStill(since: beforeRejected),
              "Paused petting is not advertised and directly rejects activation, while the enabled native element retains Resume.")
        let retainedResume = action(named: "Resume")
        check("native-resume-action-works", retainedResume?.handler?() == true && !runtime.isPaused && element.isAccessibilitySelectorAllowed(pressSelector),
              "The available Resume custom action restored live primary-action availability.")
        check("retained-resume-does-not-pause", retainedResume?.handler?() == false && !runtime.isPaused,
              "An already-used native Resume action rejected a repeated invocation instead of pausing the companion.")
        let retainedNap = action(named: "Take a nap")
        let napped = retainedNap?.handler?() == true && runtime.isSleeping
        check("retained-nap-does-not-wake", napped && retainedNap?.handler?() == false && runtime.isSleeping,
              "A retained named nap action rejected a repeated request after the pet slept, preserving the requested sleep state.")
        check("native-wake-action-works", invoke("Wake up") && !runtime.isSleeping,
              "The newly exported Wake up action restored the ordinary resting state.")

        runtime.setHidden(true)
        observeState("hidden")
        check("hidden-primary-rejected", !element.isAccessibilitySelectorAllowed(pressSelector) && !element.accessibilityPerformPress(),
              "A direct provider call cannot pet an explicitly hidden runtime. Hidden-window discoverability is not asserted.")
        runtime.setHidden(false)
        try await pause(0.1)
        runtime.setSuspension(.systemAsleep, active: true)
        check("suspended-primary-rejected", !element.isAccessibilitySelectorAllowed(pressSelector) && !element.accessibilityPerformPress(),
              "A direct runtime suspension disables primary assistive activation; this does not reproduce Mac sleep or notification delivery.")
        runtime.setSuspension(.systemAsleep, active: false)
        try await pause(0.1)

        runtime.setParked(true)
        let origin = runtime.desktop.effectiveOrigin
        let play = invoke("Play with Firefly")
        let toyAppeared = try await waitUntil(timeout: 2) { self.runtime.renderer.fireflyVisible }
        _ = try await waitUntil(timeout: 6) { !self.runtime.renderer.isAnimating }
        check("native-firefly-action-finite-and-parked", play && toyAppeared && !runtime.renderer.fireflyVisible
              && error(origin, runtime.desktop.effectiveOrigin) < 0.001,
              "The native custom action used the real guarded firefly command and completed in place while parked.")

        let beforeMove = runtime.desktop.effectiveOrigin
        let move = invoke("Move right")
        check("native-placement-action-works-with-pass-through", move && runtime.clickThrough
              && runtime.desktop.panel.ignoresMouseEvents && runtime.desktop.effectiveOrigin.x > beforeMove.x,
              "The menu-equivalent native move action remained available with whole-window mouse pass-through.")
        check("native-home-action-works", invoke("Bring pet home") && runtime.desktop.savedPlacement != nil,
              "The actual placement action returned a successful result and established a saved home.")
        positionSafely()
    }

    private func checkSizes() async throws {
        let choices = PetDisplaySize.allCases
        check("three-supported-size-choices", choices.count == 3, "Every supported size is covered by the native geometry and playback cases.")
        for choice in choices {
            try requireEnvironment()
            let home = runtime.desktop.savedPlacement
            let memory = runtime.interactionMemory
            let anchor = bottomCenter()
            runtime.setDisplaySize(choice)
            let renderer = runtime.renderer
            check("\(choice.rawValue)-native-size-and-anchor", runtime.displaySize == choice && renderer.petDisplaySize == choice
                  && runtime.desktop.panel.frame.size == choice.size && renderer.bounds.size == choice.size && element.bounds.size == choice.size
                  && error(anchor, bottomCenter()) < 0.001 && runtime.desktop.savedPlacement == home && runtime.interactionMemory == memory,
                  "Window, rendered view and interaction view use the selected size. A safe resize preserves the fractional canvas bottom-center, saved home and relocation memory.")
            checkAlphaProbes(choice)
            for (routine, direction) in [(PetRoutine.explore, SampleClipID.walkLeft), (.firefly, .walkRight)] {
                try await runRoutine(routine, direction: direction, size: choice)
            }
        }
    }

    private func runRoutine(_ routine: PetRoutine, direction: SampleClipID, size: PetDisplaySize) async throws {
        guard let offsets = runtime.renderer.routineRootOffsets(routine, direction: direction),
              runtime.desktop.canFitRootMotion(offsets) else {
            throw ValidationError.blocked("The current display could not fit a complete excursion at a supported size.")
        }
        let origin = runtime.desktop.effectiveOrigin
        let home = runtime.desktop.savedPlacement
        let completed = runtime.renderer.completedRoutineCount
        let index = playback.count
        playback.append(Playback(size: size.rawValue, routine: routine.rawValue, direction: direction.rawValue))
        activePlayback = index
        runtime.renderer.playRoutine(routine, direction: direction)
        let started = runtime.renderer.isAnimating
        let finished = try await waitUntil(timeout: min(15, runtime.renderer.routineDuration(routine, direction: direction) + 3)) {
            !self.runtime.renderer.isAnimating
        }
        try requireEnvironment()
        playback[index].settled = Snapshot(runtime)
        activePlayback = nil
        let observed = playback[index]
        let expectedClips = routine.clips(direction: direction).map(\.rawValue)
        check("\(size.rawValue)-\(routine.rawValue)-finite-scaled-return", started && finished
              && runtime.renderer.completedRoutineCount == completed + 1 && observed.clipsSeen == expectedClips
              && error(origin, runtime.desktop.effectiveOrigin) < 0.001 && runtime.desktop.savedPlacement == home
              && abs(observed.maximumExcursionPoints - 78.4 * size.scale) < 0.001,
              "One complete routine used scaled authored travel, returned to the precise starting origin, and retained saved home.")
        check("\(size.rawValue)-\(routine.rawValue)-paired-native-frames", observed.acceptedFrames > 0 && observed.rejectedFrames == 0
              && observed.frameRootMismatches == 0 && observed.committedFrameRootMismatches == 0
              && observed.maximumEffectiveOriginErrorPoints < 0.001 && observed.maximumBufferCount <= 12,
              "Accepted and sampled committed frames retained matching scaled root offsets and fractional layer geometry; observed decoding remained bounded.")
        check("\(size.rawValue)-\(routine.rawValue)-toy-scale-and-teardown", observed.toyBoundsFailures == 0 && observed.toyScaleFailures == 0
              && (routine != .firefly || observed.toySamples > 0) && !runtime.renderer.fireflyVisible && !runtime.renderer.hasActiveDisplayLink,
              "The firefly's actual layer bounds scaled with its canvas and stayed inside it. No toy or display link survived completion.")
    }

    private func checkAlphaProbes(_ size: PetDisplaySize) {
        guard let probes, probes.hitTestProbes.contains(where: \.expectedHit) else {
            check("\(size.rawValue)-independent-alpha-probes", false, "The bundled independent asset report lacked an opaque probe.")
            return
        }
        let renderer = runtime.renderer
        var matched = 0
        for probe in probes.hitTestProbes {
            let point = NSPoint(x: probe.normalizedBottomLeft.x * renderer.bounds.width + renderer.imageOffset.x,
                                y: probe.normalizedBottomLeft.y * renderer.bounds.height + renderer.imageOffset.y)
            let parentPoint = renderer.convert(point, to: element.superview)
            if renderer.containsPet(at: point) == probe.expectedHit,
               (element.hitTest(parentPoint) != nil) == probe.expectedHit { matched += 1 }
        }
        check("\(size.rawValue)-independent-alpha-probes", matched == probes.hitTestProbes.count,
              "Independent full-PNG alpha probes matched the resized renderer mask and native local hit view, including retained fractional image offset. This is not WindowServer routing evidence.")
    }

    private func checkResizeCancellation() async throws {
        positionSafely()
        runtime.setParked(false)
        let choices = PetDisplaySize.allCases
        let next = choices.first { $0 != runtime.displaySize }!
        let complete = runtime.renderer.completedRoutineCount
        runtime.renderer.playRoutine(.firefly, direction: .walkRight)
        let moving = try await waitUntil(timeout: 3) { self.runtime.desktop.isMoving && self.runtime.renderer.fireflyVisible }
        let anchor = bottomCenter()
        let home = runtime.desktop.savedPlacement
        runtime.setDisplaySize(next)
        let resized = Snapshot(runtime)
        try await pause(0.4)
        check("resize-cancels-active-travel-and-toy", moving && Snapshot(runtime).stayedStill(since: resized)
              && runtime.renderer.completedRoutineCount == complete && error(anchor, bottomCenter()) < 0.001
              && runtime.desktop.savedPlacement == home && !runtime.desktop.isMoving,
              "Resizing an actual walking toy routine cancelled decode/display work, retained the current bottom-center, and did not record completion or change home.")

        let start = runtime.desktop.effectiveOrigin
        let pointer = CGPoint(x: start.x + runtime.renderer.bounds.midX, y: start.y + runtime.renderer.bounds.midY)
        element.mouseDown(with: event(.leftMouseDown, at: pointer))
        let dragged = CGPoint(x: pointer.x + 11, y: pointer.y + 7)
        element.mouseDragged(with: event(.leftMouseDragged, at: dragged))
        let settlements = placementSettlements
        let heldHome = runtime.desktop.savedPlacement
        let heldMemory = runtime.interactionMemory
        let heldAnchor = bottomCenter()
        let afterDragSize = choices.first { $0 != runtime.displaySize }!
        runtime.setDisplaySize(afterDragSize)
        let originAfterResize = runtime.desktop.effectiveOrigin
        element.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: dragged.x + 60, y: dragged.y + 40)))
        element.mouseUp(with: event(.leftMouseUp, at: dragged))
        check("resize-cancels-held-native-drag", error(heldAnchor, bottomCenter()) < 0.001
              && error(originAfterResize, runtime.desktop.effectiveOrigin) < 0.001 && placementSettlements == settlements
              && runtime.desktop.savedPlacement == heldHome && runtime.interactionMemory == heldMemory,
              "Constructed local drag handlers were cancelled by resize; late drag/up neither moved nor committed a home or relocation memory.")
    }

    private func checkEdgeAndMissingHome() throws {
        let original = runtime.snapshotPreferencesForProbe()
        defer { runtime.restoreAfterProbe(original) }
        let choices = PetDisplaySize.allCases
        runtime.setDisplaySize(choices.first!)
        runtime.nudge(dx: 1_000_000, dy: 1_000_000)
        let edgeHome = runtime.desktop.savedPlacement
        runtime.setDisplaySize(choices.last!)
        guard let screen = runtime.desktop.panel.screen else { throw ValidationError.blocked("The resize target display became unavailable.") }
        let origin = runtime.desktop.effectiveOrigin
        let clamped = PetPlacement.clampedOrigin(origin, windowSize: runtime.desktop.panel.frame.size, visibleFrame: screen.visibleFrame)
        check("edge-resize-clamps-without-relearning-home", error(origin, clamped) < 0.001 && runtime.desktop.savedPlacement == edgeHome,
              "Increasing size at an edge retained a reachable native panel without replacing the previously saved home.")

        let absent = PetSavedPlacement(displayUUID: UUID(), normalizedX: 0.42, normalizedY: 0.35)!
        runtime.desktop.restorePlacement(absent)
        for choice in choices { runtime.setDisplaySize(choice) }
        check("resize-retains-absent-display-home", runtime.desktop.savedPlacement == absent
              && runtime.snapshotPreferencesForProbe().placement == absent,
              "A synthetic absent display identity survived fallback placement and all size changes. This does not simulate a real monitor event.")
    }

    private func checkPersistenceAndSampling() async throws {
        runtime.setPaused(true)
        runtime.setDisplaySize(.small)
        runtime.setActivityLevel(.lively)
        runtime.setSoundEnabled(true)
        runtime.setParked(true)
        let expected = runtime.snapshotPreferencesForProbe()
        let reconstructed = PetRuntime(preferencesStore: store)
        check("new-settings-reconstruct-from-isolated-store", reconstructed.displaySize == expected.displaySize
              && reconstructed.activityLevel == expected.activityLevel && reconstructed.soundEnabled == expected.soundEnabled
              && reconstructed.isParked == expected.isParked && reconstructed.profile == expected.profile
              && reconstructed.interactionMemory == expected.interactionMemory && store.load().placement == expected.placement,
              "A reconstructed runtime recovered size, activity, sound preference, parking, profile, memory and saved home. It was not started and no sound was requested.")
        runtime.setSoundEnabled(false)
        runtime.setPaused(false)
        runtime.setActivityLevel(.quiet)
        let before = runtime.snapshotPreferencesForProbe()
        let currentData = defaults.data(forKey: "dev.spriglet.preferences")
        let backupData = defaults.data(forKey: "dev.spriglet.preferences.lastGood")
        runtime.runProbe()
        try await pause(0.2)
        observeState("sampling")
        check("sampling-primary-rejected", runtime.sampling && !element.isAccessibilitySelectorAllowed(pressSelector)
              && !element.accessibilityPerformPress(), "The ordinary diagnostic made native primary availability match its temporary interaction guard.")
        runtime.cancelProbe()
        let ended = try await waitUntil(timeout: 3) { !self.runtime.sampling }
        check("cancelled-diagnostic-restores-new-settings", ended && runtime.snapshotPreferencesForProbe() == before
              && defaults.data(forKey: "dev.spriglet.preferences") == currentData
              && defaults.data(forKey: "dev.spriglet.preferences.lastGood") == backupData,
              "Cancelling the ordinary diagnostic restored the complete current preference snapshot without writing its temporary settings.")
        check("primary-availability-recovers-after-diagnostic", element.isAccessibilitySelectorAllowed(pressSelector) == runtime.canInteract,
              "The native provider's advertised primary action returned to the actual runtime guard after cancellation.")
    }

    private func installFrameObservation() {
        let renderer = runtime.renderer
        let originalStart = renderer.onPlaybackWillStart
        let originalFrame = renderer.onFrame
        let originalPlacement = runtime.desktop.onPlacementSettled
        runtime.desktop.onPlacementSettled = { [weak self] placement in
            self?.placementSettlements += 1
            originalPlacement?(placement)
        }
        renderer.onPlaybackWillStart = { [weak self] timeline in
            let accepted = originalStart?(timeline) ?? false
            if accepted, let self { motionStart = runtime.desktop.effectiveOrigin }
            return accepted
        }
        renderer.onFrame = { [weak self] snapshot in
            let accepted = originalFrame?(snapshot) ?? false
            guard let self, let index = activePlayback else { return accepted }
            if !accepted { playback[index].rejectedFrames += 1; return false }
            playback[index].acceptedFrames += 1
            if playback[index].clipsSeen.last != snapshot.clip.rawValue { playback[index].clipsSeen.append(snapshot.clip.rawValue) }
            let desktop = runtime.desktop!
            if desktop.appliedFrameIndex != snapshot.timelineFrameIndex || desktop.appliedRootOffset != snapshot.rootOffsetPoints {
                playback[index].frameRootMismatches += 1
            }
            let expected = CGPoint(x: motionStart.x + snapshot.rootOffsetPoints.x, y: motionStart.y + snapshot.rootOffsetPoints.y)
            let actual = CGPoint(x: desktop.panel.frame.minX + renderer.actualImageLayerOffset.x,
                                 y: desktop.panel.frame.minY + renderer.actualImageLayerOffset.y)
            playback[index].maximumEffectiveOriginErrorPoints = max(playback[index].maximumEffectiveOriginErrorPoints, error(expected, actual))
            playback[index].maximumExcursionPoints = max(playback[index].maximumExcursionPoints, error(actual, motionStart))
            playback[index].maximumBufferCount = max(playback[index].maximumBufferCount, renderer.bufferedFrameCount)
            return accepted
        }
    }

    private func observe() {
        guard let runtime else { return }
        observedKeyWindow = observedKeyWindow || runtime.desktop.panel.isKeyWindow
        observedAppActive = observedAppActive || NSApp.isActive
        guard let index = activePlayback else { return }
        let renderer = runtime.renderer
        playback[index].maximumBufferCount = max(playback[index].maximumBufferCount, renderer.bufferedFrameCount)
        if renderer.isAnimating, let frame = renderer.currentSnapshot,
           runtime.desktop.appliedFrameIndex != frame.timelineFrameIndex || runtime.desktop.appliedRootOffset != frame.rootOffsetPoints {
            playback[index].committedFrameRootMismatches += 1
        }
        if let frame = renderer.currentFireflyFrame {
            playback[index].toySamples += 1
            if !renderer.bounds.contains(frame) { playback[index].toyBoundsFailures += 1 }
            let expected = 28 * runtime.displaySize.scale
            if abs(frame.width - expected) > 0.001 || abs(frame.height - expected) > 0.001 { playback[index].toyScaleFailures += 1 }
        }
    }

    private func positionSafely() {
        runtime.recenter()
        guard let screen = runtime.desktop.panel.screen else { return }
        let side = runtime.renderer.displaySize.width
        let desired = CGPoint(x: screen.visibleFrame.midX - side / 2 + 0.375, y: screen.visibleFrame.minY + 60.25)
        runtime.nudge(dx: desired.x - runtime.desktop.effectiveOrigin.x, dy: desired.y - runtime.desktop.effectiveOrigin.y)
    }

    private func bottomCenter() -> CGPoint {
        CGPoint(x: runtime.desktop.effectiveOrigin.x + runtime.desktop.panel.frame.width / 2, y: runtime.desktop.effectiveOrigin.y)
    }

    private func observeState(_ name: String) {
        states.append(StateObservation(name: name, primaryPressAllowed: element.isAccessibilitySelectorAllowed(pressSelector),
                                       elementEnabled: element.isAccessibilityEnabled(),
                                       customActionNames: element.accessibilityCustomActions()?.map(\.name) ?? [], snapshot: Snapshot(runtime)))
    }

    private func action(named name: String) -> NSAccessibilityCustomAction? {
        element.accessibilityCustomActions()?.first { $0.name == name }
    }

    private func invoke(_ name: String) -> Bool { action(named: name)?.handler?() ?? false }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: runtime.desktop.panel.convertPoint(fromScreen: point), modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: runtime.desktop.panel.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func requireEnvironment() throws {
        guard runtime.canInteract, runtime.desktop.panel.isVisible, runtime.desktop.panel.isOnActiveSpace,
              runtime.desktop.panel.occlusionState.contains(.visible) else {
            throw ValidationError.blocked("The own panel or current system motion/visibility policy prevented native playback.")
        }
    }

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(name: name, outcome: passed ? .passed : .failed, detail: detail))
    }

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

    private func loadEvidence() throws {
        guard let resourceRoot = Bundle.main.resourceURL,
              let provenance = Bundle.main.url(forResource: "build-provenance", withExtension: "json"),
              let alpha = Bundle.main.url(forResource: "asset-alpha-probes", withExtension: "json") else {
            throw ValidationError.blocked("Run the packaged check with its copied assets, independent alpha probes and build provenance.")
        }
        build = try JSONDecoder().decode(BuildEvidence.self, from: Data(contentsOf: provenance))
        probes = try JSONDecoder().decode(AlphaProbes.self, from: Data(contentsOf: alpha))
        for directory in ["SproutSample", "PetSounds"] {
            let root = resourceRoot.appendingPathComponent(directory)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            while let file = files?.nextObject() as? URL {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                assets[String(file.path.dropFirst(resourceRoot.path.count + 1))] = try hash(file)
            }
        }
        if let executable = Bundle.main.executableURL { executableSHA256 = try hash(executable) }
        check("bundled-assets-match-compiled-snapshot", assets == build?.assetSHA256,
              "All actual bundled sample and optional sound files matched their build-time SHA-256 values.")
        check("independent-alpha-report-matches-sample", probes?.manifestSHA256 == assets["SproutSample/manifest.json"],
              "The independently generated rest-image alpha probes belong to the copied source manifest.")
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func error(_ first: CGPoint, _ second: CGPoint) -> Double { max(abs(first.x - second.x), abs(first.y - second.y)) }
    private func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        runtime?.setSoundEnabled(false)
        runtime?.stop()
        runtime?.desktop?.hide()
        defaults?.removePersistentDomain(forName: suiteName)
        check("temporary-defaults-domain-removed", defaults?.persistentDomain(forName: suiteName)?.isEmpty ?? true,
              "The UUID preferences domain was removed before the harness returned.")
        let outcome: Outcome = checks.contains { $0.outcome == .failed } ? .failed
            : checks.contains { $0.outcome == .blocked } ? .blocked : .passed
        let report = Report(startedAt: startedAt, endedAt: .now, elapsedSeconds: seconds(began.duration(to: clock.now)),
                            outcome: outcome, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            actualLowPowerMode: actualLowPower, actualReduceMotion: actualReduceMotion,
                            actualVoiceOverEnabledAtStart: voiceOverAtStart, actualVoiceOverEnabledAtEnd: NSWorkspace.shared.isVoiceOverEnabled,
                            screenCount: displayCount, checks: checks, playback: playback, states: states,
                            build: build, executableSHA256: executableSHA256, actualAssetSHA256: assets)
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
            print("Could not encode the validation report: \(error.localizedDescription)")
            exit(1)
        }
        exit(outcome == .passed ? 0 : outcome == .blocked ? 2 : 1)
    }
}
