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
        var view = LifecycleValidation.view(try LifecycleValidation.visiblePanel())
        func tick() throws {
            clock.onTick?(0.05)
            if view.snapshot.scene.form == .fingertipGrip, let moment = view.snapshot.idleMoment {
                try LifecycleValidation.require(moment.moment == .boat(.fiddle)
                                                && view.snapshot.homeTuck == 1 && view.snapshot.tuckedBoat != nil,
                                                "Small exposed its face or ran an unsupported habit")
            }
        }
        func advance(_ seconds: Double) throws {
            for _ in 0..<Int(seconds * 20) { try tick() }
        }
        func awaitBoat(_ stage: String) throws {
            // Across two shuffled cycles, eight ordinary moments may separate boat visits.
            for _ in 0..<2000 {
                try tick()
                if view.snapshot.idleMoment?.moment.boatHabit != nil { return }
            }
            throw ValidationFailure(description: "Ordinary idle scheduling never showed the boat at \(stage); time=\(view.snapshot.time)")
        }
        func validateLifecycle() throws {
            try awaitBoat("initial launch")
            try advance(2)
            let description = view.accessibilityValue() as? String ?? ""
            try LifecycleValidation.require(description.contains("paper boat"), "VoiceOver cannot inspect the current habit")
            let frame = view.snapshot
            runtime.setPaused(true); try advance(20)
            try LifecycleValidation.require(view.snapshot.time == frame.time && view.snapshot.idleMoment == frame.idleMoment
                                            && view.accessibilityValue() as? String == AppText.pausedPresence,
                                            "Pause did not freeze the habit and retain paused accessibility")
            runtime.setPaused(false)
            try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Resume replayed an interrupted boat habit")
            try advance(0.5)
            try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Resume skipped the fresh quiet interval")
            try awaitBoat("resume")
            runtime.setVisible(false); try advance(100)
            runtime.setVisible(true)
            try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Hide retained a pending boat")
            // Recovery samples actual power; restore this fixture's eligible AC
            // conditions before testing a new encounter (battery is tested below).
            environment.onConditionsChanged?(RuntimeConditions())
            try advance(0.5)
            try LifecycleValidation.require(view.snapshot.idleMoment == nil, "Show skipped the fresh quiet interval")
            try awaitBoat("show recovery")
            events.post(name: DesktopEnvironment.screenLocked, object: nil)
            try advance(100)
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
                try advance(30)
                try LifecycleValidation.require(view.snapshot.idleMoment == nil, "A restricted condition retained or launched a habit")
            }
        }
        for home in [HomeLocation.automatic, .right] {
            for size in CharacterSize.allCases {
                environment.onConditionsChanged?(RuntimeConditions())
                var preferences = runtime.preferences
                preferences.characterSize = size; preferences.homeLocation = home
                runtime.updatePreferences(preferences)
                view = LifecycleValidation.view(try LifecycleValidation.visiblePanel())
                try validateLifecycle()
            }
        }
        print("Native habits passed at Small, Medium and Large in both homes: hidden Small face, on-demand accessible state, fresh resume, Hide/lock recovery, and injected power/motion restrictions.")
    }
}
