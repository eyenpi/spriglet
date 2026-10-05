import AppKit
import CompanionCore

/// Uses native key loops, key equivalents and accessibility providers. Spoken
/// VoiceOver and delivery of physical system transitions remain device checks.
@MainActor enum AccessibilityValidation {
    static func key(_ characters: String, code: UInt16, window: NSWindow,
                    modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code)!
    }

    static func run(screen: NSScreen) throws {
        let events = NotificationCenter(), context = DisplayContext(screen: screen)
        let suite = "dev.spriglet.accessibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let introduction = IntroductionPreferences(defaults: defaults); introduction.recordDismissal()
        let host = CompanionWindowHost(), clock = ScreenFrameClock()
        let environment = DesktopEnvironment(applicationCenter: events, workspaceCenter: events,
                                             lockCenter: events, displays: { [context] })
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                       introductionPreferences: introduction, preferenceStore: PreferenceStore(defaults: defaults),
                                       leftButtonIsDown: { true })
        let loginService = FakeLoginService()
        let delegate = AppDelegate(runtime: runtime, launchAtLogin: LaunchAtLoginController(service: loginService))
        let previousMenu = NSApp.mainMenu, previousHelp = NSApp.helpMenu
        let previousApp = NSWorkspace.shared.frontmostApplication
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = previousMenu; NSApp.helpMenu = previousHelp
            if let previousApp { NSApp.yieldActivation(to: previousApp); previousApp.activate() }
        }
        let panel = try LifecycleValidation.visiblePanel(), character = LifecycleValidation.view(panel)
        func action(_ title: String) throws -> NSAccessibilityCustomAction {
            guard let action = character.accessibilityCustomActions()?.first(where: { $0.name == title }) else {
                throw ValidationFailure(description: "Missing character action: \(title)")
            }
            return action
        }
        func perform(_ title: String) throws {
            try LifecycleValidation.require(try action(title).handler?() == true, "Character action failed: \(title)")
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try LifecycleValidation.require(character.accessibilityValue() as? String == AppText.restingPresence,
                                        "Character has no initial accessible state")
        try perform(AppText.inviteMallow)
        try LifecycleValidation.require(character.snapshot.presence == .engaged, "Invite did not reach the engine")
        let staleInvite = try action(AppText.inviteMallow)
        try perform(AppText.swingMallow)
        try LifecycleValidation.require(character.snapshot.gesture == .swing, "Named Swing did not select the gesture")
        try perform(AppText.stretchMallow)
        try LifecycleValidation.require(character.snapshot.gesture == .stretch, "Named Stretch did not select the gesture")
        let staleStretch = try action(AppText.stretchMallow)
        LifecycleValidation.beginDrag(host: host, window: panel, clock: clock)
        try LifecycleValidation.require(character.accessibilityValue() as? String == AppText.heldPresence,
                                        "A grab is not described to VoiceOver")
        try perform(AppText.bringHome); try LifecycleValidation.assertHome(panel)
        host.onInput?(.pointerDragged(Point(x: 600, y: 300)))
        host.onInput?(.pointerReleased(Point(x: 600, y: 300)))
        try LifecycleValidation.assertHome(panel)
        let catchStart = character.snapshot.hitBounds.center
        host.onInput?(.pointerPressed(catchStart)); host.onInput?(.pointerDragged(catchStart + Point(x: 20, y: 10)))
        try LifecycleValidation.require(character.accessibilityValue() as? String == AppText.catchReadyPresence,
                                        "Catch readiness is not described to VoiceOver")
        try perform(AppText.bringHome); try LifecycleValidation.assertHome(panel)
        let stalePause = try action(AppText.pauseMallow)
        try perform(AppText.pauseMallow)
        try LifecycleValidation.require(character.accessibilityValue() as? String == AppText.pausedPresence
                                        && !character.accessibilityPerformPress() && staleInvite.handler?() == false
                                        && staleStretch.handler?() == false && stalePause.handler?() == false,
                                        "Paused character accepted an accessible interaction or retained a stale Invite")
        try LifecycleValidation.require(runtime.controlState.isPaused, "Retained Pause resumed Mallow")
        try LifecycleValidation.require(panel.ignoresMouseEvents, "Accessible Pause retained mouse capture")
        try perform(AppText.bringHome)
        try LifecycleValidation.require(runtime.controlState.isPaused, "Accessible Bring Home cleared Pause")
        try perform(AppText.resumeMallow)
        let staleHide = try action(AppText.hideMallow)
        try perform(AppText.hideMallow)
        try LifecycleValidation.require(staleHide.handler?() == false, "Retained Hide showed hidden Mallow")
        try LifecycleValidation.require(!panel.isVisible && delegate.menuBar?.statusItem != nil, "Accessible Hide lost recovery")
        delegate.perform(.bringHome); try LifecycleValidation.assertHome(panel)
        try LifecycleValidation.require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                                        "Character accessibility actions took application focus")

        // Exercise the same keyboard shortcuts used by the native main menu.
        try LifecycleValidation.require(NSApp.mainMenu?.performKeyEquivalent(with: key(",", code: 43, window: panel, modifiers: .command)) == true,
                                        "Command-comma did not open Settings")
        LifecycleValidation.pump(0.1)
        guard let settings = NSApp.windows.first(where: { $0.title == AppText.settingsTitle && $0.isVisible }),
              let content = settings.contentView else { throw ValidationFailure(description: "Keyboard Settings did not appear") }
        let controls = LifecycleValidation.descendants(of: content).filter { $0 is NSPopUpButton || $0 is NSButton }
        func control(_ title: String) throws -> NSView {
            guard let control = controls.first(where: { $0.accessibilityLabel() == title || ($0 as? NSButton)?.title == title }) else {
                throw ValidationFailure(description: "Missing keyboard control: \(title)")
            }
            return control
        }
        let titles = [AppText.characterSize, AppText.movementIntensity, AppText.homeDisplay, AppText.homeLocation,
                      AppText.showMallow, AppText.animateMallow, AppText.bringHome, AppText.launchAtLogin, AppText.openLoginItemsSettings]
        let ordered = try titles.map { try control($0) }
        try LifecycleValidation.require(settings.initialFirstResponder === ordered[0], "Settings has no predictable initial focus")
        settings.makeFirstResponder(ordered[0])
        for (index, current) in ordered.enumerated() {
            try LifecycleValidation.require(current.acceptsFirstResponder && settings.firstResponder === current,
                                            "Settings cannot focus \(titles[index])")
            settings.sendEvent(key("\t", code: 48, window: settings))
            try LifecycleValidation.require(settings.firstResponder === ordered[(index + 1) % ordered.count],
                                            "Tab skipped or trapped \(titles[index]); next valid: \(String(describing: current.nextValidKeyView)), responder: \(String(describing: settings.firstResponder))")
        }
        settings.sendEvent(key("\t", code: 48, window: settings, modifiers: .shift))
        try LifecycleValidation.require(settings.firstResponder === ordered.last, "Shift-Tab did not reverse the key loop")
        events.post(name: DesktopEnvironment.screenLocked, object: nil)
        settings.makeFirstResponder(ordered[3])
        settings.sendEvent(key("\t", code: 48, window: settings))
        try LifecycleValidation.require(settings.firstResponder === ordered[5], "Tab did not skip unavailable Show during suspension")
        settings.sendEvent(key("\t", code: 48, window: settings, modifiers: .shift))
        try LifecycleValidation.require(settings.firstResponder === ordered[3], "Shift-Tab did not skip unavailable Show")
        events.post(name: DesktopEnvironment.screenUnlocked, object: nil)
        loginService.registration = .unknown
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        settings.makeFirstResponder(ordered[6])
        settings.sendEvent(key("\t", code: 48, window: settings))
        try LifecycleValidation.require(settings.firstResponder === ordered[8], "Tab trapped focus on unavailable login registration")
        loginService.registration = .notRegistered
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        delegate.perform(.togglePause)
        try LifecycleValidation.require(NSApp.mainMenu?.performKeyEquivalent(with: key("P", code: 35, window: settings, modifiers: [.command, .shift])) == true
                                        && !runtime.controlState.isPaused, "Keyboard Resume did not reach the runtime")
        LifecycleValidation.beginDrag(host: host, window: panel, clock: clock)
        let beforeRecoveryKeyWindow = NSApp.keyWindow
        try LifecycleValidation.require(NSApp.mainMenu?.performKeyEquivalent(with: key("H", code: 4, window: settings, modifiers: [.command, .shift])) == true,
                                        "Keyboard Bring Home is unavailable")
        try LifecycleValidation.assertHome(panel)
        try LifecycleValidation.require(NSApp.keyWindow === beforeRecoveryKeyWindow,
                                        "Recovery changed keyboard focus (before: \(String(describing: beforeRecoveryKeyWindow)), after: \(String(describing: NSApp.keyWindow)))")
        try LifecycleValidation.require(NSApp.mainMenu?.performKeyEquivalent(with: key("M", code: 46, window: settings, modifiers: [.command, .shift])) == true
                                        && !panel.isVisible, "Keyboard Hide did not work")
        delegate.perform(.bringHome)
        if settings.isKeyWindow {
            try LifecycleValidation.require(NSApp.mainMenu?.performKeyEquivalent(with: key("w", code: 13, window: settings, modifiers: .command)) == true,
                                            "Command-W did not reach the focused window")
        } else {
            // An unbundled, programmatic fixture can be denied activation by
            // WindowServer. Still exercise the native close target; verify the
            // real responder-chain shortcut in the bundled daily-use fixture.
            let close = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }.first { $0.keyEquivalent == "w" }!
            try LifecycleValidation.require(NSApp.sendAction(close.action!, to: settings, from: close), "Native close target failed")
            print("Command-W responder-chain focus unavailable in this unbundled fixture; native close target exercised. Device keyboard routing remains separate.")
        }
        try LifecycleValidation.require(!settings.isVisible && runtime.controlState.isVisible,
                                        "Command-W failed to close Settings independently of the companion")

        // A live Reduce Motion update must use the same policy as a fresh launch.
        var conditions = RuntimeConditions(); conditions.reduceMotion = true
        environment.onConditionsChanged?(conditions)
        try perform(AppText.inviteMallow)
        try LifecycleValidation.require(character.snapshot.openness == 1 && character.snapshot.rotation == 0,
                                        "Accessible Invite ignored live Reduce Motion")
        for title in [AppText.swingMallow, AppText.stretchMallow] {
            try perform(title)
            LifecycleValidation.pump(0.1)
            try LifecycleValidation.require(character.snapshot.rotation == 0 && character.snapshot.pose.arm == 0
                                            && character.snapshot.pose.height == 1,
                                            "Named gesture ignored Reduce Motion: \(title)")
        }
        LifecycleValidation.beginDrag(host: host, window: panel, clock: clock)
        host.onInput?(.pointerReleased(Point(x: 500, y: 250)))
        try LifecycleValidation.assertHome(panel)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try LifecycleValidation.require(character.accessibilityPerformPress() == false && staleInvite.handler?() == false
                                        && character.onControlAction == nil && host.onControlAction == nil,
                                        "Retained accessibility elements can still act after shutdown")
        print("Accessibility passed: character state/actions, stale/paused actions, drag-free recovery, native Tab/Shift-Tab and menu shortcuts, live Reduce Motion and shutdown.")
    }
}
