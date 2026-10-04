import AppKit
import CompanionCore
import Darwin

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor final class ValidationDelegate: NSObject, NSApplicationDelegate {
    let validate: () -> Void
    init(validate: @escaping () -> Void) { self.validate = validate; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.validate() }
    }
}

@MainActor @main enum LifecycleValidation {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ValidationFailure(description: message) }
    }
    static func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func visiblePanel() throws -> NSWindow {
        let windows = NSApp.windows.filter { $0.contentView is CompanionView && $0.isVisible }
        try require(windows.count == 1, "Expected one visible companion, found \(windows.count)")
        return windows[0]
    }
    static func view(_ window: NSWindow) -> CompanionView { window.contentView as! CompanionView }
    static func assertHome(_ window: NSWindow) throws {
        let snapshot = view(window).snapshot
        try require(snapshot.presence == .peek && snapshot.phase == .hanging, "Recovery did not return to resting home")
        try require(snapshot.windowAnchor == snapshot.scene.homeFeet, "Recovery left an old display anchor")
        try require(snapshot.openness == 0.6 && snapshot.gesture == nil, "Recovery retained an interrupted gesture")
        try require(!window.isKeyWindow && !window.canBecomeKey && !window.canBecomeMain, "Companion can take keyboard focus")
        try require(window.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]),
                    "Companion cannot join Spaces/fullscreen or is in window cycling")
    }
    static func beginDrag(host: CompanionWindowHost, window: NSWindow, clock: ScreenFrameClock) {
        host.onInput?(.pointerPressed(view(window).snapshot.hitBounds.center))
        host.onInput?(.pointerDragged(Point(x: 500, y: 250)))
        clock.onTick?(0.05)
    }
    static func nativePicking(screen: NSScreen) throws {
        let context = DisplayContext(screen: screen), host = CompanionWindowHost()
        let frame = CompanionEngine(scene: context.scene).snapshot
        host.attach(context: context, snapshot: frame); host.setVisible(true)
        defer { host.close() }
        let panel = try visiblePanel(), character = view(panel), bounds = frame.hitBounds
        let body = bounds.center, corner = Point(x: bounds.minX + 1, y: bounds.maxY - 1)
        // NSView.hitTest receives its point in the superview's coordinate space.
        func hitTestPoint(_ point: Point) -> NSPoint {
            character.convert(NSPoint(x: point.x + character.drawingOrigin.x, y: point.y + character.drawingOrigin.y),
                              to: character.superview)
        }
        host.update(snapshot: frame, capturesPointer: false, pointer: body)
        try require(!panel.ignoresMouseEvents && character.hitTest(hitTestPoint(body)) === character, "Visible body was not pickable in the compensated view")
        // Check view-level picking even before the next host pointer sample.
        try require(character.hitTest(hitTestPoint(corner)) == nil, "Transparent corner accepted a stale-sample press")
        host.update(snapshot: frame, capturesPointer: false, pointer: corner)
        try require(panel.ignoresMouseEvents, "Transparent corner did not enable native click-through")
        host.update(snapshot: frame, capturesPointer: true, pointer: corner)
        try require(!panel.ignoresMouseEvents, "Dragging through a transparent corner lost native capture")
        host.update(snapshot: frame, capturesPointer: false, pointer: corner)
        try require(panel.ignoresMouseEvents, "Release retained whole-panel capture")
    }
    static func nativeLifecycle(screen: NSScreen) throws {
        let application = NotificationCenter(), workspace = NotificationCenter(), locks = NotificationCenter()
        let original = DisplayContext(screen: screen)
        let fallbackScene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1024, height: 768),
                                          home: Rect(x: 794, y: 4, width: 180, height: 20), floor: 720, hasHardwareNotch: false)
        let fallback = DisplayContext(screen: screen, id: original.id &+ 1,
                                      frame: Rect(x: -1024, y: -200, width: 1024, height: 768), scene: fallbackScene)
        let resizedScene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1280, height: 800),
                                         home: Rect(x: 545, y: 0, width: 190, height: 32), floor: 750)
        let resized = DisplayContext(screen: screen, id: original.id,
                                     frame: Rect(x: 0, y: 0, width: 1280, height: 800), scene: resizedScene)
        var available = [original, fallback]
        var buttonDown = true
        let environment = DesktopEnvironment(applicationCenter: application, workspaceCenter: workspace,
                                             lockCenter: locks, displays: { available })
        let clock = ScreenFrameClock(), host = CompanionWindowHost()
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host, leftButtonIsDown: { buttonDown })
        let delegate = AppDelegate(runtime: runtime)
        defer { runtime.stop() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        runtime.start(); runtime.start()
        var window = try visiblePanel()
        try assertHome(window)
        let originalWindow = window
        beginDrag(host: host, window: window, clock: clock)
        try require(view(window).snapshot.phase == .held && !window.ignoresMouseEvents, "Drag did not capture the pointer")

        // A notification for another display must not reset a live drag or
        // make home follow a different primary/focused display.
        available = [fallback, original]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(try visiblePanel() === originalWindow, "Unchanged layout recreated the host")
        try require(view(window).snapshot.phase == .held, "Unrelated screen notification cancelled a drag")
        buttonDown = false; clock.onTick?(0.02)
        try assertHome(window)
        try require(window.ignoresMouseEvents == !view(window).snapshot.contains(original.point(NSEvent.mouseLocation)),
                    "Lost release left whole-panel mouse capture enabled")
        host.onInput?(.pointerReleased(Point(x: 500, y: 250)))
        try assertHome(window)
        buttonDown = true

        for _ in 0..<3 {
            beginDrag(host: host, window: window, clock: clock)
            workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            try require(!window.isVisible, "System sleep did not hide the panel")
            let suspendedTime = view(window).snapshot.time
            clock.onTick?(3600); host.onInput?(.activate)
            try require(view(window).snapshot.time == suspendedTime, "Suspended input/tick changed simulation")
            try assertHome(window)
            workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            locks.post(name: DesktopEnvironment.screenLocked, object: nil)
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            try require(!window.isVisible, "System wake bypassed display sleep/lock")
            workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            try require(!window.isVisible, "Display wake bypassed screen lock")
            workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            locks.post(name: DesktopEnvironment.screenUnlocked, object: nil)
            try require(!window.isVisible, "Unlock bypassed inactive session")
            workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            window = try visiblePanel(); try assertHome(window)
            let time = view(window).snapshot.time
            pump(0.2)
            try require(view(window).snapshot.time > time && view(window).snapshot.time - time < 0.3, "Recovered display clock stalled or simulated sleep time")
            workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            try assertHome(window)
            beginDrag(host: host, window: window, clock: clock)
            workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            try assertHome(window)
            host.onInput?(.pointerDragged(Point(x: 600, y: 300)))
            host.onInput?(.pointerReleased(Point(x: 600, y: 300)))
            try assertHome(window)
        }

        beginDrag(host: host, window: window, clock: clock)
        available = [fallback]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(!window.isVisible, "Unplug left the old host visible")
        window = try visiblePanel(); try assertHome(window)
        try require(view(window).context.id == fallback.id && view(window).snapshot.scene == fallbackScene, "Unplug failed to choose fallback home")
        available = []
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(!window.isVisible, "No displays left a stale host visible")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(NSApp.windows.allSatisfy { !($0.contentView is CompanionView) || !$0.isVisible }, "Wake with no display resurrected a host")
        available = [fallback, original]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        window = try visiblePanel(); try assertHome(window)
        try require(view(window).context.id == original.id, "Reconnect forgot the original home display")
        beginDrag(host: host, window: window, clock: clock)
        available = [resized, fallback]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        window = try visiblePanel(); try assertHome(window)
        try require(view(window).snapshot.scene == resizedScene, "Resolution change kept stale geometry")
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        available = [fallback]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(NSApp.windows.allSatisfy { !($0.contentView is CompanionView) || !$0.isVisible }, "Display change during sleep flashed a host")
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        window = try visiblePanel(); try assertHome(window)

        for _ in 0..<5 {
            beginDrag(host: host, window: window, clock: clock)
            try require(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true), "Reopen was not handled")
            try require(try visiblePanel() === window, "Reopen duplicated the host")
            try assertHome(window)
        }
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Launch/recovery/reopen stole application focus")
        runtime.stop(); runtime.stop()
        try require(!window.isVisible && host.onInput == nil && clock.onTick == nil, "Stop leaked a host or input callbacks")
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        runtime.start(); window = try visiblePanel()
        try assertHome(window)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        runtime.stop(); runtime.start(); window = try visiblePanel()
        try assertHome(window)
        print("Native runtime passed: ordered sleep/wake/lock/session cycles, Spaces, lost release, display fallback/reconnect/resize, reopen and restart.")
    }
    static func menuBarControls(screen: NSScreen) throws {
        let application = NotificationCenter(), workspace = NotificationCenter(), locks = NotificationCenter()
        let context = DisplayContext(screen: screen)
        var available = [context]
        let environment = DesktopEnvironment(applicationCenter: application, workspaceCenter: workspace,
                                             lockCenter: locks, displays: { available })
        let host = CompanionWindowHost(), clock = ScreenFrameClock()
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host, leftButtonIsDown: { true })
        let delegate = AppDelegate(runtime: runtime)
        let previousMenu = NSApp.mainMenu
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = previousMenu
        }
        guard let menuBar = delegate.menuBar else { throw ValidationFailure(description: "Menu bar was not installed") }
        let menu = menuBar.menu
        func item(_ action: AppControlAction) -> NSMenuItem { menu.items.first { !$0.isSeparatorItem && $0.tag == action.rawValue }! }
        func choose(_ action: AppControlAction) throws {
            menu.performActionForItem(at: menu.index(of: item(action)))
            try checkFocus()
        }
        func checkLabels() throws {
            try require(item(.toggleVisibility).title == (runtime.controlState.isVisible ? AppText.hideMallow : AppText.showMallow),
                        "Visibility label disagrees with actual runtime state")
            try require(item(.togglePause).title == (runtime.controlState.isPaused ? AppText.resumeMallow : AppText.pauseMallow),
                        "Pause label disagrees with the user's pause choice")
            try require(item(.toggleVisibility).isEnabled == runtime.controlState.canShow,
                        "Visibility action bypasses unavailable displays/session")
        }
        func panel(_ title: String) throws -> NSWindow {
            let matches = NSApp.windows.filter { $0.title == title && $0.isVisible && !($0.contentView is CompanionView) }
            try require(matches.count == 1, "Expected one \(title) panel")
            return matches[0]
        }
        func checkFocus() throws {
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                        "A menu-bar action changed the frontmost app")
            try require(NSApp.windows.allSatisfy { !$0.isKeyWindow && !$0.isMainWindow },
                        "A companion/control panel took keyboard focus")
        }
        func checkPanelLayout(_ window: NSWindow) throws {
            let content = window.contentView!
            pump(0.05); window.displayIfNeeded()
            content.layoutSubtreeIfNeeded()
            let stack = content.subviews.compactMap { $0 as? NSStackView }.first!
            try require(content.bounds.contains(stack.frame), "Control panel content is clipped")
            for view in stack.views {
                try require(view.bounds.width > 0 && view.bounds.height > 0, "Control panel row has no area")
                try require(content.bounds.contains(view.convert(view.bounds, to: content)), "Control panel row is clipped")
                if let label = view as? NSTextField, let cell = label.cell {
                    try require(cell.cellSize(forBounds: label.bounds).height <= label.bounds.height + 1,
                                "Help/Settings text is truncated")
                }
            }
        }
        try require(menu.items.filter { !$0.isSeparatorItem }.count == 6, "Menu is missing a required control")
        try require(item(.quit).action != nil && item(.quit).target === menuBar, "Quit is not routed through the menu action boundary")
        try require(menuBar.statusItem != nil && !menuBar.statusItem!.behavior.contains(.removalAllowed),
                    "Recovery entry can be removed")
        menuBar.start()
        try checkLabels()
        var window = try visiblePanel()
        host.onInput?(.activate); clock.onTick?(0.05)
        try choose(.togglePause)
        let frozen = view(window).snapshot
        pump(0.12); clock.onTick?(3600); host.onInput?(.activate)
        try require(view(window).snapshot.time == frozen.time && view(window).snapshot.presence == frozen.presence,
                    "Pause did not freeze animation and ignore interaction")
        try require(window.ignoresMouseEvents, "Paused Mallow intercepts desktop clicks")
        try checkLabels()

        try choose(.settings); try choose(.settings); try choose(.help); try choose(.help)
        let settings = try panel(AppText.settingsTitle), help = try panel(AppText.supportTitle)
        try require(!settings.canBecomeKey && !help.canBecomeKey && !settings.canBecomeMain && !help.canBecomeMain,
                    "Settings/Help can take keyboard focus")
        try checkPanelLayout(settings); try checkPanelLayout(help)
        let stack = settings.contentView!.subviews.compactMap { $0 as? NSStackView }.first!
        let buttons = stack.views.compactMap { $0 as? NSButton }
        let visibility = buttons.first { $0.title == AppText.showMallow }!
        let animation = buttons.first { $0.title == AppText.animateMallow }!
        try require(visibility.state == .on && animation.state == .off, "Settings do not reflect paused visible state")
        try choose(.toggleVisibility)
        try require(!window.isVisible && visibility.state == .off && menuBar.statusItem != nil,
                    "Hide lost the recovery entry or settings synchronization")
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(!window.isVisible && runtime.controlState.isPaused, "Lifecycle recovery overrode Hide/Pause")
        try checkLabels()
        try choose(.bringHome)
        window = try visiblePanel(); try assertHome(window)
        try require(runtime.controlState.isPaused && animation.state == .off, "Bring Home cleared Pause")
        let homeTime = view(window).snapshot.time
        pump(0.12)
        try require(view(window).snapshot.time == homeTime, "Bring Home restarted paused animation")
        visibility.performClick(nil)
        try checkFocus()
        try require(!window.isVisible, "Settings visibility control did not hide")
        try require(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "Hidden Finder reopen was not handled")
        try require(try visiblePanel() === window, "Finder recovery duplicated the companion")
        try assertHome(window); try checkLabels()
        try require(runtime.controlState.isPaused, "Finder recovery cleared Pause")
        animation.performClick(nil); pump(0.12)
        try checkFocus()
        try require(!runtime.controlState.isPaused && view(window).snapshot.time > homeTime,
                    "Settings Resume did not restart the display clock")
        try checkLabels()
        try require(animation.accessibilityPerformPress(), "Settings checkbox lacks an accessible press")
        try require(runtime.controlState.isPaused, "Accessible checkbox press did not pause")
        try checkFocus()
        animation.performClick(nil)

        beginDrag(host: host, window: window, clock: clock)
        try choose(.togglePause); try assertHome(window)
        try require(window.ignoresMouseEvents, "Pausing a drag retained capture")
        try choose(.toggleVisibility)
        try choose(.togglePause)
        let hiddenTime = view(window).snapshot.time
        pump(0.12); clock.onTick?(3600)
        try require(!window.isVisible && view(window).snapshot.time == hiddenTime, "Resume made hidden Mallow visible or active")
        try choose(.toggleVisibility)
        window = try visiblePanel(); try assertHome(window); try checkLabels()

        locks.post(name: DesktopEnvironment.screenLocked, object: nil)
        try require(!runtime.controlState.isVisible && !item(.toggleVisibility).isEnabled && !visibility.isEnabled,
                    "Locked session still reports a visible actionable companion")
        try choose(.bringHome)
        try require(!window.isVisible, "Bring Home bypassed system suspension")
        locks.post(name: DesktopEnvironment.screenUnlocked, object: nil)
        window = try visiblePanel(); try assertHome(window); try checkLabels()
        try choose(.toggleVisibility); try choose(.togglePause)
        available = []
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try checkLabels()
        try require(!visibility.isEnabled, "Settings permit Show without a display")
        available = [context]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(!runtime.controlState.isVisible && runtime.controlState.isPaused, "Display reconnect overrode Hide/Pause")
        try choose(.toggleVisibility)
        window = try visiblePanel(); try assertHome(window)
        try checkLabels(); try checkFocus()

        settings.close(); help.close()
        try choose(.settings); try choose(.help)
        _ = try panel(AppText.settingsTitle); _ = try panel(AppText.supportTitle)
        try checkFocus()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try require(menuBar.statusItem == nil && !window.isVisible && !settings.isVisible && !help.isVisible,
                    "Shutdown leaked a status item, settings/help or companion window")
        print("Menu-bar controls passed: state labels, Settings/Help, freeze/capture, Hide/recovery, lifecycle choices, focus and cleanup.")
    }
    static func quitControl() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--quit-probe"]
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == EXIT_SUCCESS, "Menu-bar Quit did not terminate the fixture")
        print("Menu-bar Quit passed: a separate native app exited through its real menu target.")
    }
    static func observationLifetime() throws {
        let center = NotificationCenter()
        let environment = DesktopEnvironment(applicationCenter: center, workspaceCenter: center, lockCenter: center, displays: { [] })
        var recoveries = 0
        environment.onRecoveryNeeded = { recoveries += 1 }
        for _ in 0..<4 {
            environment.start(); environment.start()
            let before = recoveries
            center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            try require(recoveries == before + 1, "Repeated start duplicated observers")
            environment.stop(); environment.stop()
            center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            try require(recoveries == before + 1, "Stopped environment retained observers")
        }
        // Register/unregister the real distributed center without sending system
        // lock broadcasts to other applications or locking this Mac.
        let realEnvironment = DesktopEnvironment()
        realEnvironment.start(); realEnvironment.stop()
        print("Observation lifetime passed: repeated start/stop and real distributed lock registration.")
    }
    static func instanceLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = try AppInstanceLease.acquire(directory: directory)
        try require(first != nil, "First launch did not acquire a lease")
        for _ in 0..<5 {
            try require(try AppInstanceLease.acquire(directory: directory) == nil, "Duplicate launch acquired a second lease")
        }
        func probe(_ expected: Int32) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--lease-probe", directory.path]
            try process.run(); process.waitUntilExit()
            try require(process.terminationStatus == expected, "Separate process did not respect the launch lease")
        }
        try probe(2)
        first = nil
        try probe(0)
        let next = try AppInstanceLease.acquire(directory: directory)
        try require(next != nil, "Exit left a stale launch lock")
        withExtendedLifetime(next) {}
        let invalid = directory.appendingPathComponent("file")
        try Data().write(to: invalid)
        do {
            _ = try AppInstanceLease.acquire(directory: invalid)
            throw ValidationFailure(description: "Unwritable launch storage was silently ignored")
        } catch is ValidationFailure { throw ValidationFailure(description: "Invalid launch storage did not report an error") }
        catch { /* Expected filesystem error. */ }
        print("Launch lease passed: duplicate rejection, release and filesystem failure.")
    }
    static func waitUntil(_ message: String, timeout: Double = 5, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { pump() }
        try require(condition(), message)
    }
    /// Optional real WindowServer test. Owns a blank fixture window, enters and
    /// leaves its fullscreen Space, then restores the previously focused app.
    static func fullscreenTransition() throws {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let fixture = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        fixture.title = "Mallow fullscreen acceptance fixture"
        fixture.isReleasedWhenClosed = false; fixture.collectionBehavior = [.fullScreenPrimary]
        let runtime = CompanionRuntime()
        defer {
            runtime.stop(); fixture.orderOut(nil); fixture.close()
            if let previousApp { NSApp.yieldActivation(to: previousApp) }
            NSApp.setActivationPolicy(.accessory)
            previousApp?.activate()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(); fixture.makeKeyAndOrderFront(nil)
        try waitUntil("Fullscreen fixture could not acquire focus; click its blank window and rerun", timeout: 30) { fixture.isKeyWindow }
        runtime.start()
        try require(fixture.isKeyWindow, "Mallow launch took the fixture's keyboard focus")
        fixture.toggleFullScreen(nil)
        do {
            try waitUntil("Fixture failed to enter its fullscreen Space", timeout: 8) { fixture.styleMask.contains(.fullScreen) }
            pump(1)
            let panel = try visiblePanel()
            try require(panel.isOnActiveSpace && panel.occlusionState.contains(.visible), "Mallow did not join the real fullscreen Space")
            try require(fixture.isKeyWindow && !panel.isKeyWindow, "Fullscreen recovery took the fixture's keyboard focus")
            try require(view(panel).snapshot.phase == .hanging && view(panel).snapshot.presence == .peek, "Fullscreen transition lost home")
            runtime.reopen()
            try require(fixture.isKeyWindow, "Reopening Mallow took fullscreen keyboard focus")
        } catch {
            if fixture.styleMask.contains(.fullScreen) {
                fixture.toggleFullScreen(nil)
                try? waitUntil("Fixture failed to leave fullscreen", timeout: 8) { !fixture.styleMask.contains(.fullScreen) }
                pump(1)
            }
            throw error
        }
        fixture.toggleFullScreen(nil)
        try waitUntil("Fixture failed to return to the desktop Space", timeout: 8) { !fixture.styleMask.contains(.fullScreen) }
        pump(1)
        let panel = try visiblePanel()
        try require(panel.isOnActiveSpace && fixture.isKeyWindow && !panel.isKeyWindow, "Returning from fullscreen lost home or focus")
        print("Real fullscreen/Spaces fixture passed: entry, visible nonkey companion, reopen and desktop return.")
    }
    static func validate(bundledFullscreen: Bool) -> Int32 {
        let resultURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fullscreen-result.txt")
        var outcome = "Fullscreen fixture did not finish."
        defer { if bundledFullscreen { try? outcome.write(to: resultURL, atomically: true, encoding: .utf8) } }
        do {
            if bundledFullscreen {
                try fullscreenTransition()
                outcome = "Passed: real fullscreen/Spaces fixture retained keyboard focus and a visible home on entry, reopen and exit."
            } else {
                guard let screen = NSScreen.screens.first else { throw ValidationFailure(description: "Native validation requires a logged-in Mac with a display") }
                try nativePicking(screen: screen)
                try nativeLifecycle(screen: screen)
                try menuBarControls(screen: screen)
                try observationLifetime()
                try instanceLease()
                try quitControl()
                print("Desktop lifecycle validation passed. Notifications/display inventory are simulated; physical lock/sleep/fullscreen transitions require device acceptance.")
            }
            return EXIT_SUCCESS
        } catch {
            outcome = "Failed: \(error)"
            FileHandle.standardError.write(Data("Desktop lifecycle validation failed: \(error)\n".utf8))
            return EXIT_FAILURE
        }
    }
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lease-probe" {
            do {
                let lease = try AppInstanceLease.acquire(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                let status: Int32 = lease == nil ? 2 : 0
                withExtendedLifetime(lease) { exit(status) }
            } catch { exit(EXIT_FAILURE) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--quit-probe" {
            let controls = AppDelegate()
            app.delegate = controls
            app.finishLaunching()
            // Command-line AppKit fixtures need explicit delegate launch delivery.
            controls.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            controls.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            DispatchQueue.main.async {
                guard let menu = controls.menuBar?.menu,
                      let quit = menu.items.first(where: { !$0.isSeparatorItem && $0.tag == AppControlAction.quit.rawValue }) else {
                    exit(EXIT_FAILURE)
                }
                menu.performActionForItem(at: menu.index(of: quit))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(EXIT_FAILURE) }
            withExtendedLifetime(controls) { app.run() }
            return
        }
        if Bundle.main.bundleIdentifier == "dev.spriglet.lifecycle-validation.fullscreen" {
            let delegate = ValidationDelegate { exit(validate(bundledFullscreen: true)) }
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            app.finishLaunching()
            exit(validate(bundledFullscreen: false))
        }
    }
}
