import AppKit
import CompanionCore
import Darwin

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

enum SubprocessFailure: Error, CustomStringConvertible {
    case timedOut(seconds: Double)
    case cleanupFailed
    var description: String {
        switch self {
        case .timedOut(let seconds): "Subprocess did not exit within \(seconds) seconds"
        case .cleanupFailed: "Timed-out subprocess could not be stopped"
        }
    }
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
        let suite = "dev.spriglet.lifecycle-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                       preferenceStore: PreferenceStore(defaults: defaults), leftButtonIsDown: { buttonDown })
        let delegate = AppDelegate(runtime: runtime, launchAtLogin: LaunchAtLoginController(service: FakeLoginService()))
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
    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    static func introductionWindow() throws -> NSWindow {
        let windows = NSApp.windows.filter {
            $0.isVisible && $0.contentView.map { descendants(of: $0).contains { $0 is IntroductionDemoView } } == true
        }
        try require(windows.count == 1, "Expected one introduction, found \(windows.count)")
        return windows[0]
    }
    static func introductionView(_ window: NSWindow) throws -> IntroductionDemoView {
        guard let view = window.contentView.flatMap({ descendants(of: $0).compactMap { $0 as? IntroductionDemoView }.first }) else {
            throw ValidationFailure(description: "Introduction demo view missing")
        }
        return view
    }
    static func press(_ title: String, in window: NSWindow) throws {
        guard let button = window.contentView.flatMap({ descendants(of: $0).compactMap { $0 as? NSButton }.first { $0.title == title } }) else {
            throw ValidationFailure(description: "Introduction control missing: \(title)")
        }
        button.performClick(nil)
    }
    static let introductionTabTitles = [AppText.introductionHoverTab, AppText.introductionInviteTab, AppText.introductionDragTab,
                                        AppText.introductionCatchTab, AppText.introductionHomeTab]
    static func assertIntroductionSelection(_ step: IntroductionStep, in window: NSWindow) throws {
        let buttons = window.contentView.map { descendants(of: $0).compactMap { $0 as? NSButton }.filter { introductionTabTitles.contains($0.title) } } ?? []
        try require(buttons.count == IntroductionStep.allCases.count && buttons.allSatisfy {
            $0.state == ($0.tag == step.rawValue ? .on : .off)
        }, "Introduction selection does not match the displayed step \(step)")
        try require(window.title.hasSuffix("\(step.rawValue + 1) / \(IntroductionStep.allCases.count)"), "Introduction title and selected step disagree")
    }
    static func assertIntroductionLayout(_ window: NSWindow, step: IntroductionStep, reducedMotion: Bool) throws {
        guard let content = window.contentView else { throw ValidationFailure(description: "Introduction content missing") }
        content.layoutSubtreeIfNeeded()
        let views = descendants(of: content)
        let contentBounds = content.bounds
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: content) }
        func top(_ view: NSView) -> CGFloat { contentBounds.maxY - rect(view).maxY }
        func identified(_ name: String) -> NSView? { views.first { $0.identifier?.rawValue == name } }
        func field(_ value: String, minimumWidth: CGFloat = 0) -> NSTextField? {
            views.compactMap { $0 as? NSTextField }.first { $0.stringValue == value && rect($0).width >= minimumWidth }
        }
        guard let card = identified("introduction.card"), let markerRow = identified("introduction.markers"),
              let controls = identified("introduction.controls") else {
            throw ValidationFailure(description: "Postcard card, lesson markers or footer are missing")
        }
        let demo = try introductionView(window)
        let cardRect = rect(card), demoRect = rect(demo), markerRowRect = rect(markerRow), controlsRect = rect(controls)
        try require(abs(contentBounds.width - 620) < 1 && abs(contentBounds.height - 570) < 1,
                    "Introduction content is not the fixed 620 × 570 Postcard layout")
        try require(abs(cardRect.minX - 16) < 1 && abs(cardRect.width - 588) < 1 && abs(cardRect.height - 434) < 1 && abs(top(card) - 16) < 1,
                    "Postcard card is not positioned at 16 points with a 434-point height")
        try require(abs(demoRect.width - 564) < 1 && abs(demoRect.height - 282) < 1 && abs(demoRect.width / demoRect.height - 2) < 0.01 && abs(top(demo) - 28) < 1,
                    "Production demo is not the complete 564 × 282 (2:1) scene at the top of the card")

        let stepButtons = views.compactMap { $0 as? NSButton }.filter { introductionTabTitles.contains($0.title) }
        try require(stepButtons.count == 5 && stepButtons.map(\.title) == introductionTabTitles,
                    "Introduction does not contain the five same-title lesson controls")
        try require(stepButtons.allSatisfy { contentBounds.contains(rect($0)) }, "An introduction lesson control is clipped")
        try assertIntroductionSelection(step, in: window)

        let lessonTitles = [AppText.introductionHoverTitle, AppText.introductionInviteTitle,
                            AppText.introductionDragTitle, AppText.introductionCatchTitle,
                            AppText.introductionHomeTitle]
        let lessonBodies = [AppText.introductionHoverBody, AppText.introductionInviteBody,
                            AppText.introductionDragBody, AppText.introductionCatchBody,
                            AppText.introductionHomeBody]
        let expectedEyebrow = String(format: "%02d / %@", step.rawValue + 1, introductionTabTitles[step.rawValue])
        guard let eyebrow = field(expectedEyebrow, minimumWidth: 548),
              let heading = field(lessonTitles[step.rawValue], minimumWidth: 548),
              let body = field(lessonBodies[step.rawValue], minimumWidth: 548),
              let note = field(AppText.introductionReducedMotion, minimumWidth: 548) else {
            throw ValidationFailure(description: "Postcard eyebrow, headline, body or motion note is missing")
        }
        let eyebrowRect = rect(eyebrow), headingRect = rect(heading), bodyRect = rect(body), noteRect = rect(note)
        for label in [eyebrow, heading, body, note] {
            try require(cardRect.contains(rect(label)), "A Postcard label is clipped by the card")
        }
        for (label, name) in [(body, "lesson body"), (note, "motion note")] {
            guard let cell = label.cell else { throw ValidationFailure(description: "Introduction \(name) has no text cell") }
            try require(cell.cellSize(forBounds: label.bounds).height <= label.bounds.height + 1,
                        "Postcard \(name) wraps beyond its reserved height at step \(step)")
        }
        try require(abs(top(eyebrow) - 322) < 1 && abs(eyebrowRect.height - 16) < 1 &&
                    abs(top(heading) - 342) < 1 && abs(headingRect.height - 32) < 1 &&
                    abs(top(body) - 380) < 1 && abs(bodyRect.height - 40) < 1 &&
                    abs(top(note) - 424) < 1 && abs(noteRect.height - 18) < 1,
                    "Postcard caption typography or vertical rhythm does not match the fixed card budget")
        try require(!demoRect.intersects(eyebrowRect) && !eyebrowRect.intersects(headingRect) &&
                    !headingRect.intersects(bodyRect) && !bodyRect.intersects(noteRect),
                    "Postcard demo, caption or reduced-motion note overlap")
        try require(abs(top(markerRow) - 462) < 1 && abs(markerRowRect.height - 52) < 1 &&
                    abs(markerRowRect.minX - 16) < 1 && abs(markerRowRect.width - 588) < 1,
                    "Five lesson markers are not below the card in their shared 52-point row")
        let markerViews = (0..<IntroductionStep.allCases.count).compactMap { identified("introduction.marker.\($0)") }
        try require(markerViews.count == 5 && markerViews.allSatisfy { abs(rect($0).width - 24) < 1 && abs(rect($0).height - 24) < 1 },
                    "Postcard does not show five 24-point numbered markers")
        let orderedButtons = stepButtons.sorted { rect($0).midX < rect($1).midX }
        try require(orderedButtons.map(\.title) == introductionTabTitles && orderedButtons.allSatisfy {
            abs(top($0) - 490) < 1 && abs(rect($0).height - 24) < 1 && contentBounds.contains(rect($0))
        }, "Postcard lesson buttons are missing, clipped or not below their number markers")
        try require(zip(markerViews, orderedButtons).allSatisfy { abs(rect($0.0).midX - rect($0.1).midX) < 1 },
                    "Postcard lesson number markers and labels are misaligned")

        guard let primary = identified("introduction.primary"),
              let skip = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == AppText.introductionSkip }),
              let back = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == AppText.introductionBack }),
              let next = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == (step == .returnHome ? AppText.introductionDone : AppText.introductionNext) }) else {
            throw ValidationFailure(description: "Introduction footer controls are missing")
        }
        let footerRects = [rect(skip), rect(back), rect(next)]
        try require(abs(top(controls) - 522) < 1 && abs(controlsRect.height - 32) < 1 &&
                    abs(controlsRect.minX - 20) < 1 && abs(controlsRect.maxX - 600) < 1,
                    "Postcard footer control band is not anchored beneath the marker row")
        try require(footerRects.allSatisfy { abs($0.height - 32) < 1 && contentBounds.contains($0) },
                    "Postcard footer controls are clipped or not 32 points tall")
        try require(footerRects.allSatisfy { abs($0.midY - footerRects[0].midY) < 1 },
                    "Postcard footer controls do not share one control band")
        try require(abs((controlsRect.minY - contentBounds.minY) - 16) < 1,
                    "Postcard footer does not finish 16 points above the content bottom")
        try require(abs(skip.frame.minX - controls.bounds.minX) < 1 && abs(rect(primary).maxX - controlsRect.maxX) < 1 &&
                    abs(rect(primary).minY - controlsRect.minY) < 1 && abs(rect(primary).minX - rect(back).maxX - 10) < 1 &&
                    abs(rect(next).minX - rect(primary).minX - 14) < 1 && abs(rect(primary).maxX - rect(next).maxX - 14) < 1,
                    "Postcard footer control geometry is incorrect: skip \(skip.frame.minX)/\(controls.bounds.minX), surface \(rect(primary)), back \(rect(back)), next \(rect(next))")
        try require((step == .hover) == !back.isEnabled, "Postcard Back enabled state is wrong for \(step)")
        try require(next.title == (step == .returnHome ? AppText.introductionDone : AppText.introductionNext),
                    "Postcard final step does not show Done")
        try require(note.isHidden == !reducedMotion, "Postcard reduced-motion note visibility does not match the current policy")
        try require(views.allSatisfy { !$0.hasAmbiguousLayout }, "Postcard layout is ambiguous at step \(step)")
    }
    static func checkPanelLayout(_ window: NSWindow) throws {
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
    static func checkIntroductionTrajectory(_ step: IntroductionStep) throws {
        var demo = IntroductionDemo(step: step)
        let initialPointer = demo.pointer
        let initialTime = demo.snapshot.time
        for _ in 0..<20 { demo.advance(by: 0.05) }
        try require(demo.elapsed >= 0.9 && demo.pointer != initialPointer && demo.snapshot.time > initialTime,
                    "The production \(step) demonstration did not enter its scripted trajectory")
        for _ in 0..<78 { demo.advance(by: 0.05) }
        try require(demo.elapsed >= 4.8 && demo.elapsed < IntroductionDemo.duration,
                    "The production \(step) demonstration did not cover a full five-second trajectory")
        demo.advance(by: 0.2)
        try require(demo.elapsed < 0.2,
                    "The production \(step) demonstration did not restart cleanly after five seconds")
        var still = IntroductionDemo(step: step, motionPolicy: .reduced)
        let stillTime = still.snapshot.time, stillElapsed = still.elapsed, stillPointer = still.pointer
        still.advance(by: 5)
        try require(still.elapsed == stillElapsed && still.snapshot.time == stillTime && still.pointer == stillPointer,
                    "The reduced-motion \(step) demonstration did not remain a still")
    }
    static func nativeIntroduction(screen: NSScreen) throws {
        let suite = "dev.spriglet.introduction-validation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ValidationFailure(description: "Could not isolate introduction preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IntroductionPreferences(defaults: defaults)
        let application = NotificationCenter(), workspace = NotificationCenter(), locks = NotificationCenter()
        let original = DisplayContext(screen: screen)
        var displays = [original]
        let environment = DesktopEnvironment(applicationCenter: application, workspaceCenter: workspace, lockCenter: locks, displays: { displays })
        let clock = ScreenFrameClock(), host = CompanionWindowHost(), introductionHost = IntroductionWindowHost()
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                       introductionHost: introductionHost, introductionPreferences: preferences,
                                       preferenceStore: PreferenceStore(defaults: defaults))
        let delegate = AppDelegate(runtime: runtime, launchAtLogin: LaunchAtLoginController(service: FakeLoginService()))
        let previousMenu = NSApp.mainMenu, previousHelp = NSApp.helpMenu
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = previousMenu; NSApp.helpMenu = previousHelp
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let companion = try visiblePanel(), window = try introductionWindow(), demo = try introductionView(window)
        try require(preferences.shouldPresentOnLaunch, "Showing an introduction incorrectly persisted dismissal")
        try require(!window.isKeyWindow && window.styleMask.contains(.nonactivatingPanel), "First-launch introduction acquired keyboard focus")
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Introduction activated the app")
        try assertHome(companion)
        guard let content = window.contentView,
              let lightAppearance = NSAppearance(named: .aqua),
              let darkAppearance = NSAppearance(named: .darkAqua) else {
            throw ValidationFailure(description: "Postcard appearance validation setup failed")
        }
        let originalAppearance = window.appearance
        var conditions = RuntimeConditions()
        for (appearanceIndex, appearance) in [lightAppearance, darkAppearance].enumerated() {
            window.appearance = appearance
            for policy in [MotionPolicy.full, .reduced] {
                conditions.reduceMotion = policy == .reduced
                environment.onConditionsChanged?(conditions)
                for step in IntroductionStep.allCases {
                    try press(introductionTabTitles[step.rawValue], in: window)
                    content.layoutSubtreeIfNeeded()
                    try assertIntroductionLayout(window, step: step, reducedMotion: policy == .reduced)
                    if policy == .full && appearanceIndex == 0 { try checkIntroductionTrajectory(step) }
                }
            }
        }
        window.appearance = originalAppearance
        conditions.reduceMotion = false; environment.onConditionsChanged?(conditions)
        for policy in [MotionPolicy.full, .reduced] {
            conditions.reduceMotion = policy == .reduced
            environment.onConditionsChanged?(conditions)
            for step in IntroductionStep.allCases {
                try press(introductionTabTitles[step.rawValue], in: window)
                try assertIntroductionSelection(step, in: window)
                try assertIntroductionLayout(window, step: step, reducedMotion: policy == .reduced)
                for _ in 0..<2 {
                    // AppKit toggles a push-on/push-off button before its action.
                    // Reselect through the real control, not the host callback.
                    try press(introductionTabTitles[step.rawValue], in: window)
                    try assertIntroductionSelection(step, in: window)
                    let replayTime = demo.snapshot.time
                    for _ in 0..<4 {
                        clock.onTick?(0.05)
                        try assertIntroductionSelection(step, in: window)
                    }
                    try require(policy == .full ? demo.snapshot.time > replayTime : demo.snapshot.time == replayTime,
                                "Reselecting a step changed its playback policy")
                }
            }
        }
        conditions.reduceMotion = false; environment.onConditionsChanged?(conditions)
        introductionHost.onStepSelected?(.hover)
        let before = demo.snapshot.time
        clock.onTick?(0.1)
        try require(demo.snapshot.time > before, "Introduction did not share the runtime clock")
        try press(AppText.introductionNext, in: window)
        try require(window.title.hasSuffix("2 / 5"), "Next did not navigate the introduction")
        try press(AppText.introductionBack, in: window)
        try require(window.title.hasSuffix("1 / 5"), "Back did not navigate the introduction")
        try press(AppText.introductionCatchTab, in: window)
        clock.onTick?(0.1)
        try require(window.title.hasSuffix("4 / 5"), "Direct step selection failed")
        conditions.reduceMotion = true
        environment.onConditionsChanged?(conditions)
        let stillTime = demo.snapshot.time
        clock.onTick?(0.2)
        try require(demo.snapshot.canCatch && demo.snapshot.time == stillTime,
                    "Reduce Motion did not replace the current demo with a useful still")
        conditions.reduceMotion = false; environment.onConditionsChanged?(conditions)
        try require(demo.snapshot.time < stillTime, "Disabling Reduce Motion retained a frozen demo")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        try require(!window.isVisible && !companion.isVisible, "Sleep did not hide both windows")
        let suspended = demo.snapshot.time
        clock.onTick?(3600)
        try require(demo.snapshot.time == suspended, "Suspended introduction advanced")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(try introductionWindow() === window && demo.snapshot.time == suspended, "Wake duplicated or fast-forwarded the introduction")
        displays = []
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(!window.isVisible, "No-display state retained the introduction")
        displays = [original]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(try introductionWindow() === window, "Display recovery duplicated the introduction")
        runtime.showIntroduction(); runtime.showIntroduction()
        try require(try introductionWindow() === window && window.title.hasSuffix("1 / 5"), "Replay duplicated the window or retained progress")
        try press(AppText.introductionSkip, in: window)
        try require(!window.isVisible && !preferences.shouldPresentOnLaunch, "Skip failed to close and persist dismissal")
        try require(!IntroductionPreferences(defaults: defaults).shouldPresentOnLaunch, "A new launch would forget dismissal")
        runtime.showIntroductionIfNeeded()
        try require(!introductionHost.isVisible, "Later launch reopened a dismissed introduction")
        guard let replay = NSApp.helpMenu?.items.first, let action = replay.action else { throw ValidationFailure(description: "Help replay action missing") }
        try require(NSApp.sendAction(action, to: replay.target, from: replay), "Help replay action could not be delivered")
        var replayWindow = try introductionWindow()
        try press(AppText.introductionHomeTab, in: replayWindow)
        try press(AppText.introductionDone, in: replayWindow)
        try require(!replayWindow.isVisible, "Done did not dismiss")
        let replayAction = view(try visiblePanel()).accessibilityCustomActions()?.first { $0.name == AppText.introductionMenu }
        try require(replayAction?.handler?() == true, "Mallow has no accessible introduction replay action")
        replayWindow = try introductionWindow(); replayWindow.performClose(nil)
        try require(!replayWindow.isVisible, "Window close did not dismiss")
        runtime.showIntroduction(); replayWindow = try introductionWindow()
        guard let escape = replayWindow.contentView.flatMap({ descendants(of: $0).compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\u{1b}" } }) else {
            throw ValidationFailure(description: "Escape dismissal missing")
        }
        escape.performClick(nil)
        try require(!replayWindow.isVisible, "Escape-bound action did not dismiss")
        runtime.showIntroduction(); replayWindow = try introductionWindow()
        environment.onEscapePressed?()
        try require(!replayWindow.isVisible, "App-scoped Escape monitor did not dismiss")
        host.onInput?(.activate); environment.onEscapePressed?()
        try require(view(try visiblePanel()).snapshot.presence == .peek, "Escape stopped returning the everyday character home")
        // Help replay shares the clock gate without resetting session controls.
        runtime.setPaused(true); runtime.setVisible(false)
        delegate.perform(.help)
        guard let help = NSApp.windows.first(where: { $0.isVisible && $0.title == AppText.supportTitle }) else {
            throw ValidationFailure(description: "Offline Help panel missing")
        }
        try checkPanelLayout(help)
        try require(!help.canBecomeKey && !help.canBecomeMain, "Offline Help can take keyboard focus")
        try press(AppText.introductionMenu, in: help)
        replayWindow = try introductionWindow()
        // Explicit native button interaction may give the introduction keyboard
        // focus. Measure passive recovery against the state after that input,
        // independently of the first-launch nonactivation assertion above.
        let recoveryFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let replayDemo = try introductionView(replayWindow)
        let pausedTime = replayDemo.snapshot.time
        clock.onTick?(3600)
        try require(replayDemo.snapshot.time == pausedTime && !runtime.controlState.isVisible && runtime.controlState.isPaused,
                    "Help replay advanced while hidden/paused or reset session controls")
        var saved = runtime.preferences
        saved.characterSize = .small; saved.movementIntensity = .gentle; saved.homeLocation = .left
        runtime.updatePreferences(saved)
        try require(PreferenceStore(defaults: defaults).load() == saved, "Introduction replay broke saved preferences")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        clock.onTick?(3600)
        try require(!replayWindow.isVisible && replayDemo.snapshot.time == pausedTime, "Hidden/paused introduction advanced during sleep")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(try introductionWindow() === replayWindow && !runtime.controlState.isVisible && runtime.controlState.isPaused,
                    "Wake reset Hide/Pause or duplicated the introduction")
        runtime.bringHome(); clock.onTick?(3600)
        try require(runtime.controlState.isVisible && runtime.controlState.isPaused && replayDemo.snapshot.time == pausedTime,
                    "Bring Home cleared Pause or advanced the introduction")
        runtime.setPaused(false); clock.onTick?(0.1)
        try require(replayDemo.snapshot.time > pausedTime, "Resume failed to advance the introduction")
        runtime.setVisible(false)
        let hiddenTime = replayDemo.snapshot.time
        clock.onTick?(3600)
        try require(replayDemo.snapshot.time == hiddenTime, "Hide did not freeze the introduction")
        displays = []; application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        clock.onTick?(3600)
        displays = [original]; application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(try introductionWindow() === replayWindow && !runtime.controlState.isVisible && replayDemo.snapshot.time == hiddenTime,
                    "Display reconnect reset Hide or advanced the introduction")
        runtime.reopen(); clock.onTick?(0.1)
        try require(runtime.controlState.isVisible && replayDemo.snapshot.time > hiddenTime, "Finder recovery failed to resume an unpaused introduction")
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == recoveryFrontmost, "Passive introduction recovery took application focus")
        help.close()
        runtime.showIntroduction(); replayWindow = try introductionWindow()
        runtime.stop()
        try require(!replayWindow.isVisible && introductionHost.onDismiss == nil && introductionHost.onStepSelected == nil && host.onControlAction == nil,
                    "Stop retained introduction resources or callbacks")
        try require(!preferences.shouldPresentOnLaunch, "Stopping reset persisted dismissal")
        print("Native introduction passed: first launch, shared clock, navigation, Hide/Pause, saved edits, sleep/display recovery, persisted dismissal, Help replay and cleanup.")
    }
    static func menuBarControls(screen: NSScreen) throws {
        let application = NotificationCenter(), workspace = NotificationCenter(), locks = NotificationCenter()
        let context = DisplayContext(screen: screen)
        var available = [context]
        let environment = DesktopEnvironment(applicationCenter: application, workspaceCenter: workspace,
                                             lockCenter: locks, displays: { available })
        let host = CompanionWindowHost(), clock = ScreenFrameClock()
        let suite = "dev.spriglet.menu-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        let introductionPreferences = IntroductionPreferences(defaults: defaults)
        introductionPreferences.recordDismissal()
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                       introductionPreferences: introductionPreferences,
                                       preferenceStore: store, leftButtonIsDown: { true })
        let delegate = AppDelegate(runtime: runtime, launchAtLogin: LaunchAtLoginController(service: FakeLoginService()))
        let previousMenu = NSApp.mainMenu, previousHelp = NSApp.helpMenu
        let previousApp = NSWorkspace.shared.frontmostApplication
        var expectedFrontmost = previousApp?.processIdentifier
        var expectedKeyWindow = NSApp.keyWindow
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = previousMenu; NSApp.helpMenu = previousHelp
            if let previousApp { NSApp.yieldActivation(to: previousApp); previousApp.activate() }
        }
        guard let menuBar = delegate.menuBar else { throw ValidationFailure(description: "Menu bar was not installed") }
        let statusMenu = menuBar.menu, fullMenu = menuBar.makeMenu()
        let statusIdentity = menuBar.statusItem
        func item(_ action: AppControlAction) -> NSMenuItem {
            fullMenu.items.first { !$0.isSeparatorItem && $0.tag == action.rawValue }!
        }
        func checkStatusMenu() throws {
            menuBar.menuNeedsUpdate(statusMenu)
            let items = statusMenu.items
            try require(items.count == 2 && items.map(\.tag) == [AppControlAction.settings.rawValue, AppControlAction.quit.rawValue],
                        "Leaf menu did not contain only Settings and Quit in order")
            try require(items.map(\.title) == [AppText.settingsMenu, AppText.quitApp]
                        && items.allSatisfy { $0.action != nil && $0.target === menuBar && $0.isEnabled && !$0.isHidden && $0.submenu == nil },
                        "Leaf menu labels or typed targets changed")
            try require(items[0].keyEquivalent == "," && items[0].keyEquivalentModifierMask == .command
                        && items[1].keyEquivalent == "q" && items[1].keyEquivalentModifierMask == .command,
                        "Leaf menu lost Command-comma Settings or Command-Q Quit")
            try require(menuBar.statusItem === statusIdentity && menuBar.statusItem?.menu === statusMenu,
                        "Leaf refresh replaced or detached the status item")
        }
        func choose(_ action: AppControlAction) throws {
            let menu: NSMenu
            if action == .settings || action == .quit {
                try checkStatusMenu()
                menu = statusMenu
            } else {
                menuBar.menuNeedsUpdate(fullMenu)
                menu = fullMenu
            }
            guard let selected = menu.items.first(where: { !$0.isSeparatorItem && $0.tag == action.rawValue }) else {
                throw ValidationFailure(description: "Selected menu omitted \(action)")
            }
            menu.performActionForItem(at: menu.index(of: selected))
            if action == .settings {
                // Settings is the one explicit action that requests activation.
                pump(0.05)
                expectedFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                expectedKeyWindow = NSApp.keyWindow
            }
            try checkFocus()
        }
        func checkLabels() throws {
            try checkStatusMenu()
            menuBar.menuNeedsUpdate(fullMenu)
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
            try checkStatusMenu()
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmost,
                        "A control/recovery action changed the frontmost app")
            try require(NSApp.keyWindow === expectedKeyWindow, "A control/recovery action changed keyboard focus")
            try require(NSApp.windows.filter { $0.contentView is CompanionView || $0.title == AppText.supportTitle }
                        .allSatisfy { !$0.isKeyWindow && !$0.isMainWindow }, "The companion or Help took keyboard focus")
        }
        menuBar.menuNeedsUpdate(fullMenu)
        try require(fullMenu.items.filter { $0.action != nil }.count == AppControlAction.allCases.count, "Full menu is missing a required control")
        try require(item(.quit).action != nil && item(.quit).target === menuBar, "Context-menu Quit is not routed through the menu action boundary")
        try require(menuBar.statusItem != nil && !menuBar.statusItem!.behavior.contains(.removalAllowed),
                    "Recovery entry can be removed")
        try checkStatusMenu()
        menuBar.start()
        try require(menuBar.statusItem === statusIdentity, "Idempotent start replaced the status item")
        try checkLabels()
        var window = try visiblePanel()
        host.onInput?(.activate); clock.onTick?(0.05)
        try choose(.togglePause)
        let frozen = view(window).snapshot
        pump(0.12); clock.onTick?(3600); host.onInput?(.activate)
        try require(view(window).snapshot.time == frozen.time && view(window).snapshot.presence == frozen.presence
                    && view(window).snapshot.pose == frozen.pose && view(window).snapshot.feet == frozen.feet,
                    "Pause did not freeze animation and ignore interaction")
        try require(window.ignoresMouseEvents, "Paused Mallow intercepts desktop clicks")
        try checkLabels()

        try choose(.settings); try choose(.settings); try choose(.help); try choose(.help)
        let settings = try panel(AppText.settingsTitle), help = try panel(AppText.supportTitle)
        try require(settings.canBecomeKey && !help.canBecomeKey && !help.canBecomeMain,
                    "Settings lost native keyboard support or Help can take focus")
        // Character, accessibility and Command-comma all route to this same window.
        host.onControlAction?(.settings); pump(0.05)
        let mainSettings = NSApp.mainMenu!.items[0].submenu!.items.first { $0.keyEquivalent == "," }!
        NSApp.sendAction(mainSettings.action!, to: mainSettings.target, from: mainSettings)
        pump(0.05)
        try require(try panel(AppText.settingsTitle) === settings, "Settings entry points opened unrelated windows")
        expectedFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        expectedKeyWindow = NSApp.keyWindow
        try checkPanelLayout(settings); try checkPanelLayout(help)
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        let buttons = descendants(of: settings.contentView!).compactMap { $0 as? NSButton }
        let visibility = buttons.first { $0.title == AppText.showMallow }!
        let animation = buttons.first { $0.title == AppText.animateMallow }!
        try require(visibility.state == .on && animation.state == .off, "Settings do not reflect paused visible state")
        try choose(.toggleVisibility)
        try require(!window.isVisible && visibility.state == .off && menuBar.statusItem != nil,
                    "Hide lost the recovery entry or settings synchronization")
        try choose(.settings)
        try require(try panel(AppText.settingsTitle) === settings && !window.isVisible,
                    "Leaf Settings was unavailable while Mallow was hidden")
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(!window.isVisible && runtime.controlState.isPaused, "Lifecycle recovery overrode Hide/Pause")
        let popups = descendants(of: settings.contentView!).compactMap { $0 as? NSPopUpButton }
        var edited = runtime.preferences
        for (label, selection) in [(AppText.characterSize, 0), (AppText.movementIntensity, 2), (AppText.homeLocation, 1)] {
            let popup = popups.first { $0.accessibilityLabel() == label }!
            popup.selectItem(at: selection)
            NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        }
        edited.characterSize = .small; edited.movementIntensity = .lively; edited.homeLocation = .left
        try require(runtime.preferences == edited && store.load() == edited, "Menu Settings did not apply and save preferences")
        try require(!runtime.controlState.isVisible && runtime.controlState.isPaused && visibility.state == .off && animation.state == .off,
                    "Saved edits overrode Hide/Pause or left stale Settings controls")
        try require(NSApp.windows.allSatisfy { !($0.contentView is CompanionView) || !$0.isVisible },
                    "Hidden preference edit made Mallow visible")
        try checkLabels()
        try choose(.bringHome)
        window = try visiblePanel(); try assertHome(window)
        try require(runtime.controlState.isPaused && animation.state == .off, "Bring Home cleared Pause")
        try require(view(window).snapshot.scene.scale == 0.8 && view(window).snapshot.scene.home.minX == 20,
                    "Recovery discarded saved size/home")
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
        menuBar.menuNeedsUpdate(fullMenu)
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
        try choose(.settings)
        try require(try panel(AppText.settingsTitle) === settings && !window.isVisible,
                    "Leaf Settings was unavailable without a display")
        try require(!visibility.isEnabled, "Settings permit Show without a display")
        try require(!visibility.accessibilityPerformPress(), "Accessible Show bypassed missing display protection")
        available = [context]
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(!runtime.controlState.isVisible && runtime.controlState.isPaused, "Display reconnect overrode Hide/Pause")
        try choose(.toggleVisibility)
        window = try visiblePanel(); try assertHome(window)
        try checkLabels(); try checkFocus()

        settings.close(); help.close()
        expectedKeyWindow = NSApp.keyWindow
        try choose(.settings); try choose(.help)
        _ = try panel(AppText.settingsTitle); _ = try panel(AppText.supportTitle)
        try checkFocus()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try require(menuBar.statusItem == nil && !window.isVisible && !settings.isVisible && !help.isVisible,
                    "Shutdown leaked a status item, settings/help or companion window")
        try require(statusMenu.items.count == 2 && statusMenu.items.map(\.tag) == [AppControlAction.settings.rawValue, AppControlAction.quit.rawValue],
                    "Stopping removed or changed the reusable leaf menu")
        print("Menu-bar controls passed: state labels, Settings/Help, freeze/capture, Hide/recovery, lifecycle choices, focus and cleanup.")
    }
    static func productionWallSnapshots() throws {
        let scene = SceneGeometry.preview
        func impact(side: Double, policy: MotionPolicy) throws -> CompanionSnapshot {
            var engine = CompanionEngine(scene: scene)
            engine.setMotionPolicy(policy)
            let initial = engine.snapshot, pointerStart = initial.hitBounds.center
            engine.send(.pointerPressed(pointerStart))
            let wall = side < 0 ? scene.leftLimit : scene.rightLimit
            let targetFeet = Point(x: wall + side * 100 * scene.scale, y: scene.floor - 80 * scene.scale)
            let pointerTarget = pointerStart + (targetFeet - initial.feet)
            var impactFrame: CompanionSnapshot?
            for _ in 0..<180 {
                engine.send(.pointerDragged(pointerTarget))
                engine.advance(by: 1 / 120)
                let frame = engine.snapshot
                let reachedWall = abs(frame.windowAnchor.x - wall) < 0.01
                let visibleImpact = policy == .reduced || (frame.pose.width < 0.99 && frame.pose.height > 1)
                if reachedWall && visibleImpact { impactFrame = frame; break }
            }
            guard let impactFrame else {
                throw ValidationFailure(description: "Production engine did not emit a \(policy) snapshot for the \(side < 0 ? "left" : "right") wall impact")
            }
            return impactFrame
        }

        for side in [-1.0, 1.0] {
            let full = try impact(side: side, policy: .full)
            try require(full.pose.width < 0.99 && full.pose.height > 1
                        && abs(full.pose.width * full.pose.height - 1) < 0.02,
                        "Production snapshot lost proportional wall squash at the \(side < 0 ? "left" : "right") wall")
            let reduced = try impact(side: side, policy: .reduced)
            try require(reduced.pose.width == 1 && reduced.pose.height == 1,
                        "Reduced Motion exposed wall deformation at the \(side < 0 ? "left" : "right") wall")
        }

        var cornerEngine = CompanionEngine(scene: scene)
        let initial = cornerEngine.snapshot, pointerStart = initial.hitBounds.center
        cornerEngine.send(.pointerPressed(pointerStart))
        let pointerTarget = pointerStart + (Point(x: scene.rightLimit + 100 * scene.scale,
                                                  y: scene.floor + 100 * scene.scale) - initial.feet)
        var reachedCorner = false
        for _ in 0..<180 {
            cornerEngine.send(.pointerDragged(pointerTarget))
            cornerEngine.advance(by: 1 / 120)
            let frame = cornerEngine.snapshot
            if abs(frame.windowAnchor.x - scene.rightLimit) < 0.01
                && abs(frame.windowAnchor.y - scene.floor) < 0.01 {
                reachedCorner = true; break
            }
        }
        try require(reachedCorner, "Production engine did not reach the right/floor corner")
        // Let the held wall response recover while the wall-contact latch stays
        // set, then release at the corner. The floor contact must own this axis.
        cornerEngine.advance(by: 3)
        let beforeFloorContact = cornerEngine.snapshot
        cornerEngine.send(.pointerReleased(pointerTarget))
        cornerEngine.advance(by: 1 / 120)
        let corner = cornerEngine.snapshot
        try require(abs(corner.feet.x - scene.rightLimit) < 0.01 && abs(corner.feet.y - scene.floor) < 0.01,
                    "Production corner snapshot left the scene bounds")
        try require(corner.pose.height < beforeFloorContact.pose.height
                    && corner.pose.width > beforeFloorContact.pose.width,
                    "Production corner snapshot did not favor floor-axis squash over wall-axis squash")
        print("Production wall snapshots passed: left/right full and reduced motion, plus floor-priority corner response.")
    }
    static func quitControl() throws {
        for mode in ["resting", "held", "falling", "catching", "paused", "hidden", "introduction", "settings"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--quit-probe", mode]
            try process.run()
            // The child's main-queue watchdog cannot run if launch or AppKit stalls.
            try waitForSubprocessExit(process, timeout: 5)
            try require(process.terminationStatus == EXIT_SUCCESS, "Menu-bar Quit failed during \(mode)")
        }
        print("Menu-bar Quit passed: real menu target and resource cleanup during rest, grab, fall, catch, pause, hide, introduction and Settings.")
    }
    static func waitForSubprocessExit(_ process: Process, timeout: Double) throws {
        func wait(_ seconds: Double) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while process.isRunning {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return false }
                pump(min(0.02, remaining))
            }
            return true
        }
        guard !wait(timeout) else { return }
        process.terminate()
        if !wait(0.25) {
            _ = kill(process.processIdentifier, SIGKILL)
            guard wait(1) else { throw SubprocessFailure.cleanupFailed }
        }
        throw SubprocessFailure.timedOut(seconds: timeout)
    }
    static func subprocessTimeoutValidation() throws {
        for mode in ["exit", "terminate", "stall"] {
            let process = Process()
            let readiness = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--quit-wait-fixture", mode]
            process.standardOutput = readiness
            try process.run()
            defer {
                try? readiness.fileHandleForWriting.close()
                try? readiness.fileHandleForReading.close()
                if process.isRunning { try? waitForSubprocessExit(process, timeout: 0.1) }
            }
            try readiness.fileHandleForWriting.close()
            if mode == "exit" {
                try waitForSubprocessExit(process, timeout: 2)
                try require(process.terminationStatus == EXIT_SUCCESS, "Headless exit fixture failed")
            } else {
                // Wait for the SIGTERM policy before testing timeout cleanup.
                // A bounded poll avoids another blocking wait in this fixture.
                var descriptor = pollfd(fd: readiness.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                try require(poll(&descriptor, 1, 2_000) == 1 && descriptor.revents & Int16(POLLIN) != 0,
                            "Headless timeout fixture did not become ready")
                try require(readiness.fileHandleForReading.readData(ofLength: 1) == Data([1]), "Invalid headless readiness signal")
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    try waitForSubprocessExit(process, timeout: 0.1)
                    throw ValidationFailure(description: "Stalled child bypassed the subprocess deadline")
                } catch SubprocessFailure.timedOut {
                    let expectedSignal = mode == "stall" ? SIGKILL : SIGTERM
                    try require(!process.isRunning && process.terminationReason == .uncaughtSignal
                                && process.terminationStatus == expectedSignal, "Timeout did not clean up its child")
                    try require(ProcessInfo.processInfo.systemUptime - started < 3, "Subprocess timeout cleanup was not bounded")
                }
            }
        }
        print("Subprocess bounds passed: normal exit, timeout termination and SIGTERM-resistant cleanup.")
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
        func probe(_ expected: Int32, storage: URL = directory) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--lease-probe", storage.path]
            try process.run(); try waitForSubprocessExit(process, timeout: 5)
            try require(process.terminationStatus == expected, "Separate process did not respect the launch lease")
        }
        try probe(2)
        first = nil
        try probe(0)
        let next = try AppInstanceLease.acquire(directory: directory)
        try require(next != nil, "Exit left a stale launch lock")
        withExtendedLifetime(next) {}

        let overlapping = directory.appendingPathComponent("overlapping", isDirectory: true)
        let ready = overlapping.appendingPathComponent("ready")
        let contenders = (0..<8).map { _ in Process() }
        defer {
            for process in contenders where process.isRunning { process.terminate(); try? waitForSubprocessExit(process, timeout: 2) }
        }
        for process in contenders {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--lease-holder", overlapping.path]
            try process.run()
        }
        try waitUntil("Overlapping launches did not elect exactly one owner") {
            FileManager.default.fileExists(atPath: ready.path) && contenders.filter(\.isRunning).count == 1
        }
        for process in contenders where !process.isRunning {
            try require(process.terminationStatus == 2, "Overlapping launch did not exit as a duplicate")
        }
        guard let owner = contenders.first(where: \.isRunning) else {
            throw ValidationFailure(description: "Overlapping launch owner disappeared")
        }
        try probe(2, storage: overlapping)
        try require(kill(owner.processIdentifier, SIGKILL) == 0, "Could not stop the fixture lock owner")
        try waitForSubprocessExit(owner, timeout: 2)
        try probe(0, storage: overlapping)
        let invalid = directory.appendingPathComponent("file")
        try Data().write(to: invalid)
        do {
            _ = try AppInstanceLease.acquire(directory: invalid)
            throw ValidationFailure(description: "Unwritable launch storage was silently ignored")
        } catch is ValidationFailure { throw ValidationFailure(description: "Invalid launch storage did not report an error") }
        catch { /* Expected filesystem error. */ }
        print("Launch lease passed: duplicate rejection, eight overlapping processes, crash recovery, release and filesystem failure.")
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
    static func validate(bundledFullscreen: Bool, appOnly: Bool = false) -> Int32 {
        let resultURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fullscreen-result.txt")
        var outcome = "Fullscreen fixture did not finish."
        defer { if bundledFullscreen { try? outcome.write(to: resultURL, atomically: true, encoding: .utf8) } }
        do {
            if bundledFullscreen {
                try fullscreenTransition()
                outcome = "Passed: real fullscreen/Spaces fixture retained keyboard focus and a visible home on entry, reopen and exit."
            } else if appOnly {
                try MultiMonitorValidation.verifyFrameComparisonTolerance()
                try productionWallSnapshots()
                try launchAtLogin()
                try loginSettings()
                try instanceLease()
                try SettingsValidation.preferences()
                print("App validation passed without showing windows, activating apps or changing macOS login registration.")
            } else {
                guard let screen = NSScreen.screens.first else { throw ValidationFailure(description: "Native validation requires a logged-in Mac with a display") }
                try nativePicking(screen: screen)
                try nativeLifecycle(screen: screen)
                try BoredomValidation.run(screen: screen)
                try nativeIntroduction(screen: screen)
                try menuBarControls(screen: screen)
                try AccessibilityValidation.run(screen: screen)
                try observationLifetime()
                try launchAtLogin()
                try loginSettings()
                try instanceLease()
                try SettingsValidation.preferences()
                try SettingsValidation.runtime(screen: screen)
                try SettingsValidation.window(screen: screen)
                try subprocessTimeoutValidation()
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
    static func multiMonitorValidation() -> Int32 {
        do { try MultiMonitorValidation.run(); return EXIT_SUCCESS }
        catch {
            FileHandle.standardError.write(Data("Multi-display validation failed: \(error)\n".utf8))
            return EXIT_FAILURE
        }
    }
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lease-holder" {
            do {
                let storage = URL(fileURLWithPath: CommandLine.arguments[2])
                guard let lease = try AppInstanceLease.acquire(directory: storage) else { exit(2) }
                try Data().write(to: storage.appendingPathComponent("ready"))
                withExtendedLifetime(lease) { while true { Thread.sleep(forTimeInterval: 0.05) } }
            } catch { exit(EXIT_FAILURE) }
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--preferences-probe" {
            guard let defaults = UserDefaults(suiteName: CommandLine.arguments[2]) else { exit(EXIT_FAILURE) }
            exit(PreferenceStore(defaults: defaults).load() == SettingsValidation.savedPreferences ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-preferences" {
            do { try SettingsValidation.preferences(); exit(EXIT_SUCCESS) }
            catch {
                FileHandle.standardError.write(Data("Preferences validation failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-multi-monitor" {
            exit(multiMonitorValidation())
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-placement-frame" {
            do { try MultiMonitorValidation.runPlacementFrame(); exit(EXIT_SUCCESS) }
            catch {
                FileHandle.standardError.write(Data("Placement frame validation failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-corner-drag" {
            do { try CornerDragValidation.run(); exit(EXIT_SUCCESS) }
            catch {
                FileHandle.standardError.write(Data("Corner drag validation failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        // These fixtures stay headless, including while another app is fullscreen.
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--quit-wait-fixture" {
            if CommandLine.arguments[2] == "exit" { exit(EXIT_SUCCESS) }
            let mode = CommandLine.arguments[2]
            guard mode == "terminate" || mode == "stall" else { exit(EXIT_FAILURE) }
            signal(SIGTERM, mode == "stall" ? SIG_IGN : SIG_DFL)
            FileHandle.standardOutput.write(Data([1]))
            while true { _ = pause() }
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-quit-timeout" {
            do { try subprocessTimeoutValidation(); exit(EXIT_SUCCESS) }
            catch {
                FileHandle.standardError.write(Data("Subprocess timeout validation failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lease-probe" {
            do {
                let lease = try AppInstanceLease.acquire(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                let status: Int32 = lease == nil ? 2 : 0
                withExtendedLifetime(lease) { exit(status) }
            } catch { exit(EXIT_FAILURE) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if ["dev.spriglet.lifecycle-validation.introduction", "dev.spriglet.lifecycle-validation.daily-use"].contains(Bundle.main.bundleIdentifier ?? "") {
            let suite = "dev.spriglet.introduction-preview.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { exit(EXIT_FAILURE) }
            let introduction = IntroductionPreferences(defaults: defaults)
            if Bundle.main.bundleIdentifier?.hasSuffix("daily-use") == true { introduction.recordDismissal() }
            let runtime = CompanionRuntime(introductionPreferences: introduction,
                                           preferenceStore: PreferenceStore(defaults: defaults))
            let delegate = AppDelegate(runtime: runtime, launchAtLogin: LaunchAtLoginController(service: FakeLoginService()))
            app.delegate = delegate
            let cleanup = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: app, queue: .main) { _ in
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { app.terminate(nil) }
            withExtendedLifetime((delegate, cleanup)) { app.run() }
            NotificationCenter.default.removeObserver(cleanup)
            defaults.removePersistentDomain(forName: suite)
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--quit-probe" {
            let mode = CommandLine.arguments[2]
            let suite = "dev.spriglet.quit-validation.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { exit(EXIT_FAILURE) }
            let introductionPreferences = IntroductionPreferences(defaults: defaults)
            introductionPreferences.recordDismissal()
            let host = CompanionWindowHost(), clock = ScreenFrameClock()
            let runtime = CompanionRuntime(clock: clock, host: host, introductionPreferences: introductionPreferences,
                                           preferenceStore: PreferenceStore(defaults: defaults), leftButtonIsDown: { true })
            let controls = AppDelegate(runtime: runtime,
                                       launchAtLogin: LaunchAtLoginController(service: FakeLoginService()))
            let cleanup = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: app, queue: .main) { _ in
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
            app.delegate = controls
            app.finishLaunching()
            // Command-line AppKit fixtures need explicit delegate launch delivery.
            controls.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            controls.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            DispatchQueue.main.async {
                do {
                    let panel = try visiblePanel()
                    if ["held", "falling", "catching", "paused"].contains(mode) {
                        let start = view(panel).snapshot.hitBounds.center
                        let destination = mode == "catching" ? start + Point(x: 20, y: 10) : Point(x: 500, y: 250)
                        host.onInput?(.pointerPressed(start)); host.onInput?(.pointerDragged(destination)); clock.onTick?(0.05)
                        try require(view(panel).snapshot.phase == .held, "Quit fixture did not grab Mallow")
                        if mode == "falling" || mode == "catching" {
                            host.onInput?(.pointerReleased(destination))
                            try require(view(panel).snapshot.phase == (mode == "catching" ? .catching : .falling), "Quit fixture has the wrong release phase")
                        }
                    }
                    if mode == "paused" { runtime.setPaused(true) }
                    if mode == "hidden" { runtime.setVisible(false) }
                    if mode == "introduction" { controls.perform(.introduction) }
                    if mode == "settings" { controls.perform(.settings) }
                } catch {
                    FileHandle.standardError.write(Data("Quit fixture failed: \(error)\n".utf8)); exit(EXIT_FAILURE)
                }
                guard let menu = controls.menuBar?.menu,
                      menu.items.count == 2,
                      menu.items.map(\.tag) == [AppControlAction.settings.rawValue, AppControlAction.quit.rawValue],
                      let quit = menu.items.first(where: { $0.tag == AppControlAction.quit.rawValue }),
                      quit.target === controls.menuBar else {
                    exit(EXIT_FAILURE)
                }
                menu.performActionForItem(at: menu.index(of: quit))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(EXIT_FAILURE) }
            withExtendedLifetime((controls, cleanup)) { app.run() }
            guard controls.menuBar == nil, host.onInput == nil, host.onControlAction == nil, clock.onTick == nil,
                  NSApp.windows.allSatisfy({ !$0.isVisible }) else { exit(EXIT_FAILURE) }
            NotificationCenter.default.removeObserver(cleanup)
            defaults.removePersistentDomain(forName: suite)
            return
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-introduction" {
            app.finishLaunching()
            do {
                guard let screen = NSScreen.screens.first else { throw ValidationFailure(description: "Introduction validation requires a display") }
                try nativeIntroduction(screen: screen)
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("Introduction validation failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if Bundle.main.bundleIdentifier == "dev.spriglet.lifecycle-validation.fullscreen" {
            let delegate = ValidationDelegate { exit(validate(bundledFullscreen: true)) }
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            app.finishLaunching()
            exit(validate(bundledFullscreen: false, appOnly: CommandLine.arguments.contains("--app-only")))
        }
    }
}
