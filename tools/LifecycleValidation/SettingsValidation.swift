import AppKit
import CompanionCore

@MainActor enum SettingsValidation {
    static let savedDisplayID = "13C77939-1CBE-4F41-B07F-F9E46A467535"
    static var savedPreferences: CompanionPreferences {
        CompanionPreferences(characterSize: .large, movementIntensity: .gentle,
                             homeDisplayID: savedDisplayID, homeLocation: .center)
    }
    static func preferences() throws {
        let suite = "dev.spriglet.settings-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        try LifecycleValidation.require(store.load() == CompanionPreferences(), "First launch has unexpected preferences")
        defaults.set("bad root", forKey: PreferenceStore.storageKey)
        try LifecycleValidation.require(store.load() == CompanionPreferences(), "Malformed preferences root did not use defaults")
        defaults.set(["characterSize": 42, "movementIntensity": "gentle", "homeLocation": "future-value",
                      "homeDisplayID": "not-a-display"], forKey: PreferenceStore.storageKey)
        let repaired = store.load()
        try LifecycleValidation.require(repaired.characterSize == .medium && repaired.movementIntensity == .gentle
                                       && repaired.homeLocation == .automatic && repaired.homeDisplayID == nil,
                                       "Bad preference field discarded another valid choice")
        defaults.set("legacy-value", forKey: "characterSize")
        store.save(savedPreferences)
        try LifecycleValidation.require(PreferenceStore(defaults: defaults).load() == savedPreferences, "Saved choices failed to reload")
        try LifecycleValidation.require(defaults.string(forKey: "characterSize") == "legacy-value", "Saving changed retired preferences")
        // A fresh process exercises CFPreferences disk persistence, not a shared
        // UserDefaults object or an in-memory runtime snapshot.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--preferences-probe", suite]
        try process.run(); process.waitUntilExit()
        try LifecycleValidation.require(process.terminationStatus == 0, "Fresh process did not restore saved preferences")
        store.save(CompanionPreferences())
        try LifecycleValidation.require(store.load().homeDisplayID == nil, "Automatic display retained a stale saved ID")
        print("Preferences passed: defaults, malformed/partial values, isolated storage and fresh-process restoration.")
    }
    static func runtime(screen: NSScreen) throws {
        let suite = "dev.spriglet.settings-runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        store.save(savedPreferences)
        let original = DisplayContext(screen: screen)
        let external = DisplayContext(screen: screen, id: original.id &+ 1,
            frame: Rect(x: -1024, y: -200, width: 1024, height: 768),
            scene: SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1024, height: 768),
                                 home: Rect(x: 794, y: 4, width: 180, height: 20), floor: 720, hasHardwareNotch: false),
            persistentID: savedDisplayID)
        var available = [original, external]
        let events = NotificationCenter()
        let environment = DesktopEnvironment(applicationCenter: events, workspaceCenter: events, lockCenter: events, displays: { available })
        let clock = ScreenFrameClock(), host = CompanionWindowHost()
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host, preferenceStore: store, leftButtonIsDown: { true })
        defer { runtime.stop() }
        runtime.start()
        var panel = try LifecycleValidation.visiblePanel()
        try LifecycleValidation.assertHome(panel)
        try LifecycleValidation.require(LifecycleValidation.view(panel).context.id == external.id, "Launch ignored saved home display")
        try LifecycleValidation.require(LifecycleValidation.view(panel).snapshot.scene.scale == 1.2
                                       && LifecycleValidation.view(panel).snapshot.scene.home.midX == 512,
                                       "Launch ignored saved size/location")
        try LifecycleValidation.require(panel.frame.width == WindowGeometry.width * 1.2
                                       && panel.frame.height == WindowGeometry.height * 1.2,
                                       "Large character kept an unscaled native canvas")

        LifecycleValidation.beginDrag(host: host, window: panel, clock: clock)
        var choices = runtime.preferences
        choices.movementIntensity = .lively
        runtime.updatePreferences(choices)
        try LifecycleValidation.require(try LifecycleValidation.visiblePanel() === panel
                                       && LifecycleValidation.view(panel).snapshot.phase == .held && !panel.ignoresMouseEvents,
                                       "Movement change cancelled or rebuilt an active drag")
        choices.characterSize = .small; choices.homeLocation = .left
        runtime.updatePreferences(choices)
        panel = try LifecycleValidation.visiblePanel(); try LifecycleValidation.assertHome(panel)
        let changedScene = LifecycleValidation.view(panel).snapshot.scene
        try LifecycleValidation.require(changedScene.scale == 0.8 && changedScene.home.minX == 20,
                                       "Size/location did not apply immediately")
        try LifecycleValidation.require(store.load() == choices, "Runtime failed to persist an immediate change")

        available = [original]
        events.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel = try LifecycleValidation.visiblePanel()
        try LifecycleValidation.require(LifecycleValidation.view(panel).context.id == original.id
                                       && runtime.preferences.homeDisplayID == savedDisplayID,
                                       "Disconnect did not fall back while preserving the saved choice")
        events.post(name: NSWorkspace.willSleepNotification, object: nil)
        choices.characterSize = .large; choices.homeLocation = .right
        runtime.updatePreferences(choices)
        try LifecycleValidation.require(NSApp.windows.allSatisfy { !($0.contentView is CompanionView) || !$0.isVisible },
                                       "Settings change while sleeping flashed a companion")
        available = []
        events.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        events.post(name: NSWorkspace.didWakeNotification, object: nil)
        try LifecycleValidation.require(NSApp.windows.allSatisfy { !($0.contentView is CompanionView) || !$0.isVisible },
                                       "Settings recovery without displays resurrected a companion")
        // Simulate a changed session display number with the same persistent UUID.
        let reconnected = DisplayContext(screen: screen, id: external.id &+ 9, frame: external.frame,
                                         scene: external.scene, persistentID: savedDisplayID)
        available = [original, reconnected]
        events.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel = try LifecycleValidation.visiblePanel(); try LifecycleValidation.assertHome(panel)
        try LifecycleValidation.require(LifecycleValidation.view(panel).context.id == reconnected.id
                                       && LifecycleValidation.view(panel).snapshot.scene.scale == 1.2,
                                       "Reconnect lost saved display identity or updated settings")
        runtime.setVisible(false); runtime.setPaused(true)
        runtime.stop()
        let relaunched = CompanionRuntime(environment: environment, preferenceStore: PreferenceStore(defaults: defaults))
        defer { relaunched.stop() }
        relaunched.start(); panel = try LifecycleValidation.visiblePanel()
        try LifecycleValidation.require(relaunched.controlState.isVisible && !relaunched.controlState.isPaused,
                                       "Session-only Hide/Pause leaked into saved preferences")
        try LifecycleValidation.require(relaunched.preferences == choices && LifecycleValidation.view(panel).context.id == reconnected.id,
                                       "Relaunch failed to restore choices and home")
        print("Settings runtime passed: saved launch, live edits/drag cancellation, sleep, no display, fallback, persistent reconnect and relaunch.")
    }
    static func window(screen: NSScreen) throws {
        let original = DisplayContext(screen: screen)
        for location in HomeLocation.allCases {
            let scene = original.placingHome(size: .large, location: location).scene
            try LifecycleValidation.require(scene.home.minX >= scene.bounds.minX && scene.home.maxX <= scene.bounds.maxX
                                           && scene.home.maxY < scene.floor, "Home placement escaped its display")
            if location != .automatic { try LifecycleValidation.require(!scene.hasHardwareNotch, "Chosen edge claimed a hardware notch") }
        }
        let controller = SettingsWindowController(state: SettingsState(preferences: savedPreferences,
                                                                       displays: [HomeDisplay(id: savedDisplayID, name: "Test display")],
                                                                       controls: CompanionControlState(isVisible: true, isPaused: false, canShow: true)))
        defer { controller.close() }
        func controls(in view: NSView) -> [NSPopUpButton] {
            view.subviews.flatMap { child in (child as? NSPopUpButton).map { [$0] } ?? controls(in: child) }
        }
        guard let window = controller.window, let content = window.contentView else {
            throw ValidationFailure(description: "Settings has no native window")
        }
        controller.showWindow(nil); LifecycleValidation.pump(0.1); content.layoutSubtreeIfNeeded()
        let popups = controls(in: content)
        try LifecycleValidation.require(popups.count == 4, "Settings lacks required controls")
        for control in popups {
            try LifecycleValidation.require(!(control.accessibilityLabel() ?? "").isEmpty, "Settings control lacks an accessible label")
            let frame = control.convert(control.bounds, to: content)
            try LifecycleValidation.require(content.bounds.contains(frame), "Settings control is clipped")
        }
        guard let display = popups.first(where: { $0.accessibilityLabel() == AppText.homeDisplay }),
              let size = popups.first(where: { $0.accessibilityLabel() == AppText.characterSize }),
              let movement = popups.first(where: { $0.accessibilityLabel() == AppText.movementIntensity }),
              let location = popups.first(where: { $0.accessibilityLabel() == AppText.homeLocation }) else {
            throw ValidationFailure(description: "Settings labels do not identify their controls")
        }
        controller.update(SettingsState(preferences: savedPreferences, displays: [],
                                        controls: CompanionControlState(isVisible: false, isPaused: true, canShow: false)))
        try LifecycleValidation.require(display.titleOfSelectedItem == AppText.disconnectedDisplay, "Settings forgot the disconnected selection")
        var emitted: CompanionPreferences?
        controller.onChange = { emitted = $0 }
        size.selectItem(at: 0)
        NSApp.sendAction(size.action!, to: size.target, from: size)
        try LifecycleValidation.require(emitted?.characterSize == .small && emitted?.homeDisplayID == savedDisplayID,
                                       "Control edit overwrote the disconnected display choice")
        movement.selectItem(at: 2); NSApp.sendAction(movement.action!, to: movement.target, from: movement)
        location.selectItem(at: 3); NSApp.sendAction(location.action!, to: location.target, from: location)
        try LifecycleValidation.require(emitted?.movementIntensity == .lively && emitted?.homeLocation == .right
                                       && emitted?.characterSize == .small && emitted?.homeDisplayID == savedDisplayID,
                                       "Movement/location control edit lost earlier choices")
        display.selectItem(at: 0)
        NSApp.sendAction(display.action!, to: display.target, from: display)
        try LifecycleValidation.require(emitted?.homeDisplayID == nil, "Automatic display selection did not clear the saved ID")
        controller.close(); controller.showWindow(nil)
        try LifecycleValidation.require(controller.window === window && window.isVisible, "Reopening settings duplicated or lost the window")
        print("Native Settings passed: accessible controls, live edits, disconnected selection, close/reopen and control layout.")
    }
}
