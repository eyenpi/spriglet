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
            let target = notch ? Point(x: area.midX, y: view.snapshot.scene.home.maxY - 4)
                : Point(x: area.maxX - 3, y: area.maxY - 3)
            try LifecycleValidation.require(view.snapshot.containsHoverTarget(target) && !view.snapshot.contains(target),
                                            "Lower-notch or notchless hover target did not stay click-through")
            pointer = context.globalPoint(scene: target)
            func picks(_ point: Point) -> Bool {
                let local = NSPoint(x: point.x + view.drawingOrigin.x, y: point.y + view.drawingOrigin.y)
                return view.hitTest(view.convert(local, to: view.superview)) === view
            }
            clock.onTick?(0.05)
            try LifecycleValidation.require(view.snapshot.homeTuck == 1 && panel.ignoresMouseEvents && !picks(target),
                                            "A single passing-pointer sample revealed Mallow or intercepted empty space")
            let outside = Point(x: area.maxX + 80, y: area.midY)
            pointer = context.globalPoint(scene: outside); clock.onTick?(0.05)
            try LifecycleValidation.require(view.snapshot.homeTuck == 1, "Crossing toward another display revealed Mallow")
            pointer = context.globalPoint(scene: target)
            for _ in 0..<14 { clock.onTick?(0.05) }
            try LifecycleValidation.require(view.snapshot.homeTuck == 0 && view.snapshot.hitBounds.height > 24,
                                            "Peek did not reveal the normal face")
            let corner = Point(x: view.snapshot.hitBounds.minX + 1, y: view.snapshot.hitBounds.maxY - 1)
            pointer = context.globalPoint(scene: corner); clock.onTick?(1 / 120.0)
            try LifecycleValidation.require(panel.ignoresMouseEvents && !picks(corner), "Empty space around the peek intercepted clicks")
            let face = view.snapshot.hitBounds.center
            pointer = context.globalPoint(scene: face); clock.onTick?(1 / 120.0)
            try LifecycleValidation.require(!panel.ignoresMouseEvents && picks(face), "Visible face was not immediately pickable")
            let above = Point(x: area.midX, y: area.minY - 1)
            try LifecycleValidation.require(!picks(above) && !picks(outside), "Painted target covered housing or unrelated empty space")
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                let local = NSPoint(x: face.x + view.drawingOrigin.x, y: face.y + view.drawingOrigin.y)
                guard let event = NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw ValidationFailure(description: "Could not construct compensated hover events")
                }
                return event
            }
            view.mouseDown(with: try event(.leftMouseDown))
            view.mouseUp(with: try event(.leftMouseUp))
            try LifecycleValidation.require(view.snapshot.presence == .engaged && view.snapshot.homeHoverBounds == nil,
                                            "Native click on the revealed face did not invite Mallow")
            runtime.bringHome()
            panel = try LifecycleValidation.visiblePanel(); view = LifecycleValidation.view(panel)
            for _ in 0..<14 { clock.onTick?(0.05) }
            try LifecycleValidation.require(view.snapshot.homeTuck == 0, "Home did not peek when the pointer remained nearby")
            runtime.setPaused(true)
            try LifecycleValidation.require(panel.ignoresMouseEvents && !picks(face), "Pause retained pointer input")
            runtime.setPaused(false)
            pointer = context.globalPoint(scene: outside)
            clock.onTick?(0.1)
            try LifecycleValidation.require(view.snapshot.homeTuck == 0 && panel.ignoresMouseEvents,
                                            "Brief pointer exit reversed the peek or retained input capture")
            for _ in 0..<24 { clock.onTick?(0.05) }
            try LifecycleValidation.require(view.snapshot.homeTuck == 1 && view.snapshot.hitBounds.height < 4 && panel.ignoresMouseEvents,
                                            "Leaving did not restore the tiny resting grip")
            preferences.characterSize = .medium; runtime.updatePreferences(preferences)
            view = LifecycleValidation.view(try LifecycleValidation.visiblePanel())
            try LifecycleValidation.require(view.snapshot.homeHoverBounds == nil, "Medium inherited the broad target")
        }
        print("Home hover passed: both display types, quiet pass-through, deliberate face peek, click-through empty space, compensated face click, pause/recovery and gentle exit.")
    }
}
