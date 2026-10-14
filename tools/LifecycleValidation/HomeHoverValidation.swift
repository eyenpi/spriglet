import AppKit
import CompanionCore

@MainActor enum HomeHoverValidation {
    static func run(screen: NSScreen) throws {
        for notch in [true, false] {
            let base = DisplayContext(screen: screen)
            let scene = SceneGeometry(bounds: base.scene.bounds,
                                      home: Rect(x: base.scene.bounds.midX - 92.5, y: 0, width: 185, height: 32),
                                      floor: base.scene.floor, hasHardwareNotch: notch)
            let context = DisplayContext(screen: screen, id: base.id, frame: base.frame, scene: scene)
            let events = NotificationCenter()
            let suite = "dev.spriglet.hover-validation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = PreferenceStore(defaults: defaults)
            var preferences = CompanionPreferences(); preferences.characterSize = .small
            store.save(preferences)
            let environment = DesktopEnvironment(applicationCenter: events, workspaceCenter: events,
                                                 lockCenter: events, displays: { [context] })
            let host = CompanionWindowHost(), clock = ScreenFrameClock()
            var pointer = Point(x: base.frame.midX, y: base.frame.maxY - 48)
            let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                           preferenceStore: store, leftButtonIsDown: { true }, pointerLocation: { pointer })
            defer { runtime.stop() }
            runtime.start()
            var panel = try LifecycleValidation.visiblePanel()
            var view = LifecycleValidation.view(panel)
            guard let area = view.snapshot.homeHoverBounds else { throw ValidationFailure(description: "Small has no hover area") }
            let target = Point(x: area.maxX - 3, y: area.maxY - 3)
            pointer = context.globalPoint(scene: target)
            func picks(_ point: Point) -> Bool {
                let local = NSPoint(x: point.x + view.drawingOrigin.x, y: point.y + view.drawingOrigin.y)
                return view.hitTest(view.convert(local, to: view.superview)) === view
            }
            clock.onTick?(0.2)
            try LifecycleValidation.require(panel.ignoresMouseEvents && !picks(target), "Unarmed transparent target intercepted clicks")
            for _ in 0..<8 { clock.onTick?(0.05) }
            try LifecycleValidation.require(view.snapshot.homeHoverArmed && !panel.ignoresMouseEvents && picks(target),
                                            "Broad hover did not arm native picking")
            try LifecycleValidation.require(panel.frame.contains(NSPoint(x: pointer.x, y: pointer.y)),
                                            "Native canvas clipped the larger target")
            let above = Point(x: area.midX, y: area.minY - 1)
            let outside = Point(x: area.maxX + 2, y: area.midY)
            try LifecycleValidation.require(!picks(above) && !picks(outside), "Armed target covered housing or unrelated empty space")
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                let local = NSPoint(x: target.x + view.drawingOrigin.x, y: target.y + view.drawingOrigin.y)
                guard let event = NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw ValidationFailure(description: "Could not construct compensated hover events")
                }
                return event
            }
            view.mouseDown(with: try event(.leftMouseDown))
            view.mouseUp(with: try event(.leftMouseUp))
            try LifecycleValidation.require(view.snapshot.presence == .engaged && !view.snapshot.homeHoverArmed,
                                            "Native click in empty target space did not invite Mallow")
            runtime.bringHome()
            panel = try LifecycleValidation.visiblePanel(); view = LifecycleValidation.view(panel)
            for _ in 0..<8 { clock.onTick?(0.05) }
            try LifecycleValidation.require(view.snapshot.homeHoverArmed, "Home did not rearm after a fresh dwell")
            runtime.setPaused(true); runtime.setPaused(false)
            try LifecycleValidation.require(!view.snapshot.homeHoverArmed && panel.ignoresMouseEvents,
                                            "Pause/resume retained an armed invisible target")
            for _ in 0..<8 { clock.onTick?(0.05) }
            pointer = context.globalPoint(scene: outside); clock.onTick?(0.05)
            try LifecycleValidation.require(!view.snapshot.homeHoverArmed && panel.ignoresMouseEvents,
                                            "Leaving the hover area retained native capture")
            preferences.characterSize = .medium; runtime.updatePreferences(preferences)
            view = LifecycleValidation.view(try LifecycleValidation.visiblePanel())
            try LifecycleValidation.require(view.snapshot.homeHoverBounds == nil, "Medium inherited the broad target")
        }
        print("Home hover passed: both display types, delayed native capture, compensated empty-space click, pause/recovery and exit.")
    }
}
