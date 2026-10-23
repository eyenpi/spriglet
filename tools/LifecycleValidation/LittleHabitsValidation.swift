import AppKit
import CompanionCore

@MainActor enum LittleHabitsValidation {
    static func run(screen: NSScreen) throws {
        let suite = "dev.spriglet.habits-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        let introduction = IntroductionPreferences(defaults: defaults); introduction.recordDismissal()
        let context = DisplayContext(screen: screen), events = NotificationCenter()
        let environment = DesktopEnvironment(applicationCenter: events, workspaceCenter: events,
                                             lockCenter: events, displays: { [context] })
        let clock = ScreenFrameClock(), host = CompanionWindowHost()
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                       introductionPreferences: introduction, preferenceStore: store,
                                       boredomTiming: BoredomTiming(threshold: 1, cooldown: 2), idleSeed: 42,
                                       pointerLocation: { Point(x: -1000, y: -1000) })
        runtime.start()
        defer { runtime.stop() }
        environment.onConditionsChanged?(RuntimeConditions())
        let panel = try LifecycleValidation.visiblePanel(), view = LifecycleValidation.view(panel)
        func advance(_ seconds: Double) {
            for _ in 0..<Int(seconds * 20) { clock.onTick?(0.05) }
        }
        func awaitBoat(_ stage: String) throws {
            // Across two shuffled cycles, eight ordinary moments may separate boat visits.
            for _ in 0..<2000 {
                clock.onTick?(0.05)
                if view.snapshot.idleMoment?.moment.boatHabit != nil { return }
            }
            throw ValidationFailure(description: "Ordinary idle scheduling never showed the boat at \(stage); time=\(view.snapshot.time)")
        }
        try awaitBoat("initial launch")
        let description = view.accessibilityValue() as? String ?? ""
        try LifecycleValidation.require(description.contains("paper boat"), "VoiceOver cannot inspect the current habit")
        let frame = view.snapshot
        runtime.setPaused(true); advance(20)
        try LifecycleValidation.require(view.snapshot.time == frame.time && view.snapshot.idleMoment == frame.idleMoment
                                        && view.accessibilityValue() as? String == AppText.pausedPresence,
                                        "Pause did not freeze the habit and retain paused accessibility")
        runtime.setPaused(false)
        try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Resume replayed an interrupted boat habit")
        advance(0.5)
        try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Resume skipped the fresh quiet interval")
        try awaitBoat("resume")
        runtime.setVisible(false); advance(100)
        runtime.setVisible(true)
        try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Hide retained a pending boat")
        try awaitBoat("show recovery")
        events.post(name: DesktopEnvironment.screenLocked, object: nil)
        advance(100)
        events.post(name: DesktopEnvironment.screenUnlocked, object: nil)
        try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Lock recovery replayed a habit")
        for restriction in 0..<4 {
            environment.onConditionsChanged?(RuntimeConditions())
            try awaitBoat("restricted mode setup \(restriction)")
            var conditions = RuntimeConditions()
            switch restriction {
            case 0: conditions.onBattery = true
            case 1: conditions.lowPower = true
            case 2: conditions.reduceMotion = true
            default: conditions.thermal = .serious
            }
            environment.onConditionsChanged?(conditions)
            advance(30)
            try LifecycleValidation.require(view.snapshot.idleMoment == nil, "A restricted condition retained or launched a habit")
        }
        print("Native habits passed: default behavior, on-demand accessible state, fresh resume, Hide/lock recovery, and injected power/motion restrictions.")
    }
}
