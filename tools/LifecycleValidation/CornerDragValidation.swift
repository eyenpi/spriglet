import AppKit
import CompanionCore

/// Finite adapter test on the connected upper displays. No OS mouse events,
/// screen capture, app preferences or existing preview windows are used.
@MainActor enum CornerDragValidation {
    static func run() throws {
        _ = NSApplication.shared
        let contexts = NSScreen.screens.map { DisplayContext(screen: $0).placingHome(size: .small, location: .automatic) }
        guard let main = contexts.first else { throw Failure("No connected display") }
        let upper = contexts.filter { $0.frame.minY >= main.frame.maxY }
        guard upper.count >= 2 else { throw Failure("Corner drag validation requires two displays above the primary display") }
        for context in upper {
            try check(context: context, displays: contexts, rightCorner: context.frame.midX < main.frame.midX)
            try checkRuntimeTransfers(source: context, main: main, displays: contexts)
        }
        print("Both triangle corner native checks passed: production View input, capture, actual paint coverage, next draw, inward drag, seam travel, release and regrab. Compositor-visible output and physical mouse delivery remain unverified.")
    }

    private static func checkRuntimeTransfers(source: DisplayContext, main: DisplayContext,
                                               displays: [DisplayContext]) throws {
        let suite = "dev.spriglet.lifecycle-validation.seam.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        var preferences = store.load()
        preferences.homeDisplayID = source.persistentID; preferences.characterSize = .small
        store.save(preferences)
        let introduction = IntroductionPreferences(defaults: defaults); introduction.recordDismissal()
        let host = CompanionWindowHost(), clock = ScreenFrameClock()
        var pointer = Point.zero
        let runtime = CompanionRuntime(environment: DesktopEnvironment(displays: { displays }), clock: clock, host: host,
                                       introductionPreferences: introduction, preferenceStore: store,
                                       leftButtonIsDown: { true }, pointerLocation: { pointer })
        defer { runtime.stop() }
        runtime.start()
        var input = try LifecycleValidation.visiblePanel(), view = input.contentView as! CompanionView
        let identity = ObjectIdentifier(input)
        try validateHomeMask(snapshot: view.snapshot)
        func event(_ type: NSEvent.EventType, at global: Point) throws {
            pointer = global
            let point = input.convertPoint(fromScreen: NSPoint(x: global.x, y: global.y))
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: input.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: throw Failure("Unsupported runtime fixture event")
            }
        }
        let press = try visiblePoint(view.snapshot)
        try event(.leftMouseDown, at: view.context.globalPoint(scene: press))
        try validateHomeMask(snapshot: view.snapshot)
        let x = main.frame.midX + (source.frame.midX < main.frame.midX ? -250 : 250)
        try event(.leftMouseDragged, at: Point(x: x, y: source.frame.minY + 110))
        for _ in 0..<120 { clock.onTick?(1 / 60.0) }
        try require(view.snapshot.phase == .held, "Runtime seam fixture did not begin dragging")
        var sawBothDisplays = false
        for direction in [1, -1, 1] {
            for step in 0...60 {
                let offset = direction == 1 ? 110 - Double(step) * 220 / 60 : -110 + Double(step) * 220 / 60
                try event(.leftMouseDragged, at: Point(x: x, y: source.frame.minY + offset))
                clock.onTick?(1 / 60.0)
                try require(try LifecycleValidation.visiblePanel() === input && ObjectIdentifier(input) == identity,
                            "Vertical transfer replaced the native input window")
                try require(view.snapshot.phase == .held && !input.ignoresMouseEvents,
                            "Vertical transfer lost pointer capture")
                try require(store.load() == preferences, "Provisional vertical transfer changed saved preferences")
                if step % 10 == 0 {
                    try validatePresentation(snapshot: view.snapshot, context: view.context, input: input)
                    let passive = NSApp.windows.filter { $0.isVisible && $0.contentView is CompanionCanvasView && !($0.contentView is CompanionView) }
                    if passive.contains(where: { covers(source.frame, rect($0.frame)) })
                        && passive.contains(where: { covers(main.frame, rect($0.frame)) }) { sawBothDisplays = true }
                }
            }
            let expected = direction == 1 ? main : source
            try require(view.context.isSameLogicalDisplay(as: expected), "Runtime did not retarget across the vertical seam")
        }
        try require(sawBothDisplays, "Runtime trace never painted both sides of the seam")
        try event(.leftMouseUp, at: pointer)
        try require(store.load().homeDisplayID == main.persistentID, "Vertical release did not commit the lower display UUID")
        for _ in 0..<240 { clock.onTick?(1 / 60.0) }
        try require(NSApp.windows.allSatisfy { !$0.isVisible || !($0.contentView is CompanionCanvasView) || $0.contentView is CompanionView },
                    "Release retirement leaked a passive paint window")
        runtime.bringHome()
        try require(view.snapshot.phase == .hanging && !input.isKeyWindow, "Bring Home failed after a vertical transfer")
        // Cancellation must remove paint windows even while both displays are
        // touched; ordinary post-release cleanup does not exercise this path.
        for action in ["pause", "hide", "stop"] {
            let saved = store.load()
            let grab = try visiblePoint(view.snapshot)
            try event(.leftMouseDown, at: view.context.globalPoint(scene: grab))
            try event(.leftMouseDragged, at: Point(x: x, y: main.frame.maxY + 48))
            for _ in 0..<120 { clock.onTick?(1 / 60.0) }
            try require(view.snapshot.phase == .held && NSApp.windows.contains {
                $0.isVisible && $0.contentView is CompanionCanvasView && !($0.contentView is CompanionView)
            }, "\(action) fixture did not create active paint canvases: phase=\(view.snapshot.phase), sameInput=\(input.contentView === view), pointer=\(pointer)")
            switch action {
            case "pause": runtime.setPaused(true)
            case "hide": runtime.setVisible(false)
            default: runtime.stop()
            }
            try require(store.load() == saved, "\(action) committed a provisional display")
            try require(NSApp.windows.allSatisfy {
                !$0.isVisible || !($0.contentView is CompanionCanvasView) || $0.contentView is CompanionView
            }, "\(action) left a visible passive canvas")
            if action == "pause" { runtime.setPaused(false) }
            if action != "stop" {
                runtime.bringHome()
                // Cancelling on a provisional display restores the saved home
                // and may replace the input window after capture has ended.
                input = try LifecycleValidation.visiblePanel()
                view = input.contentView as! CompanionView
            }
        }
        try require(NSApp.windows.allSatisfy { !$0.isVisible || !($0.contentView is CompanionCanvasView) },
                    "Stopping the runtime left a visible canvas")
        print("Vertical runtime seam passed: \(source.frame) ↔ \(main.frame), mixed backing, unchanged provisional preferences, one input window, complete native crown, release UUID and canvas cleanup.")
    }

    private static func check(context: DisplayContext, displays: [DisplayContext], rightCorner: Bool) throws {
        var engine = CompanionEngine(scene: context.scene, idleSeed: 7)
        let first = try visiblePoint(engine.snapshot)
        let initial = engine.snapshot
        engine.send(.pointerPressed(first))
        let target = Point(x: rightCorner ? context.scene.rightLimit : context.scene.leftLimit, y: context.scene.floor)
        let endpoint = first + target - initial.feet
        engine.send(.pointerDragged(endpoint))
        for _ in 0..<120 { engine.advance(by: 1 / 60.0) }
        engine.send(.pointerReleased(endpoint))
        for _ in 0..<600 where engine.snapshot.phase != .grounded { engine.advance(by: 1 / 60.0) }
        try require(engine.snapshot.phase == .grounded, "Corner fixture failed to reach the floor")
        let host = CompanionWindowHost()
        defer { host.onPointerInput = nil; host.onDraw = nil; host.close() }
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        host.attach(context: context, snapshot: engine.snapshot)
        host.setVisible(true)
        guard let panel = NSApp.windows.first(where: { !previousWindows.contains(ObjectIdentifier($0)) && $0.title == AppText.companionName }),
              let view = panel.contentView as? CompanionView else { throw Failure("Missing native panel/view") }
        let identity = ObjectIdentifier(panel)
        let geometry = dragGeometry(active: context, displays: displays)
        var lastGlobal: Point?
        host.onPointerInput = { input in
            let global: Point
            switch input {
            case .pressed(let point):
                global = point; engine.send(.pointerPressed(context.scenePoint(global: point)))
                if engine.hasPointerCapture { _ = engine.beginDesktopDrag(geometry: geometry) }
            case .dragged(let point): global = point; engine.send(.pointerDragged(context.scenePoint(global: point)))
            case .released(let point): global = point; engine.send(.pointerReleased(context.scenePoint(global: point)))
            }
            lastGlobal = global
            host.update(snapshot: engine.snapshot, capturesPointer: engine.hasPointerCapture,
                        pointer: context.scenePoint(global: global))
        }
        func refresh() {
            host.update(snapshot: engine.snapshot, capturesPointer: engine.hasPointerCapture,
                        pointer: lastGlobal.map(context.scenePoint(global:)) ?? .zero)
        }
        func dispatch(_ type: NSEvent.EventType, scene point: Point) throws {
            let global = context.globalPoint(scene: point)
            let windowPoint = panel.convertPoint(fromScreen: NSPoint(x: global.x, y: global.y))
            let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: throw Failure("Unsupported fixture event")
            }
            try require(lastGlobal.map { MultiMonitorValidation.pointsWithinNativeTolerance($0, global) } == true,
                        "Production View changed the original event's global coordinate")
        }
        func checkFrame(_ stage: String, protectFullPaint: Bool) throws {
            let snapshot = engine.snapshot, d = context.frame
            let actual = rect(panel.frame)
            let requested = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: d,
                                                        scale: snapshot.scene.scale,
                                                        visibleBounds: snapshot.dragGeometry == nil ? snapshot.hitBounds
                                                            : snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded))
            try require(ObjectIdentifier(panel) == identity && panel.contentView === view,
                        "Drag replaced the input panel or view")
            try require(view.context.hasSameLayout(as: context), "Placement changed the logical display")
            try require(covers(d, actual), "Input window escaped the active display")
            try validatePresentation(snapshot: snapshot, context: context, input: panel)
            print("CORNER_DRAG stage=\(stage) display=\(d) requested=\(requested) input=\(actual) splitPaint=\(snapshot.dragGeometry != nil) fullPaint=\(protectFullPaint)")
        }

        try checkFrame("rest", protectFullPaint: false)
        let before = engine.snapshot
        let crown = before.geometry.root.apply(before.geometry.body.apply(Point(x: 0, y: -58)))
        try require(before.contains(crown), "Grounded crown is not a valid pick")
        try dispatch(.leftMouseDown, scene: crown)
        try require(engine.hasPointerCapture && !engine.isDragging && engine.snapshot.feet == before.feet
                    && engine.snapshot.pose == before.pose && engine.snapshot.rotation == before.rotation,
                    "Zero-motion press changed pose/feet or began dragging")
        try checkFrame("down", protectFullPaint: true)
        let inward = rightCorner ? -1.0 : 1.0
        try dispatch(.leftMouseDragged, scene: crown + Point(x: inward * 3, y: 0))
        try require(!engine.isDragging, "Subthreshold move began dragging")
        try checkFrame("subthreshold", protectFullPaint: true)
        try dispatch(.leftMouseDragged, scene: crown + Point(x: inward * 5, y: 0))
        engine.advance(by: 1 / 60.0); refresh()
        try require(engine.isDragging && !panel.ignoresMouseEvents, "Held motion lost pointer capture")
        try checkFrame("held", protectFullPaint: true)
        try dispatch(.leftMouseDragged, scene: crown + Point(x: inward * 35, y: 0))
        engine.advance(by: 0.1); refresh()
        try checkFrame("inward", protectFullPaint: true)
        let seam = context.scenePoint(global: Point(x: displays[0].frame.midX + 250, y: context.frame.minY + 48))
        try dispatch(.leftMouseDragged, scene: seam)
        for _ in 0..<60 { engine.advance(by: 1 / 60.0) }
        refresh()
        let seamPaint = protectedPaint(engine.snapshot, display: context.frame)
        try require(seamPaint.minY < context.frame.minY && seamPaint.maxY > context.frame.minY,
                    "Fixture did not put artwork across the true vertical seam")
        try checkFrame("vertical-seam", protectFullPaint: true)
        try dispatch(.leftMouseUp, scene: seam)
        try require(!engine.hasPointerCapture, "Release retained capture")
        try checkFrame("pending-release", protectFullPaint: true)
        for _ in 0..<600 where engine.hasPendingDragRelease { engine.advance(by: 1 / 60.0) }
        refresh(); try checkFrame("retired", protectFullPaint: false)
        let regrab = try visiblePoint(engine.snapshot)
        try dispatch(.leftMouseDown, scene: regrab)
        try require(engine.hasPointerCapture, "Visible regrab was rejected")
        try checkFrame("regrab", protectFullPaint: true)
        engine.send(.cancelInteraction); refresh()
        try require(!engine.hasPointerCapture && engine.snapshot.phase == .hanging, "Cancellation failed to restore home")
    }

    static func validatePresentation(snapshot: CompanionSnapshot, context: DisplayContext, input: NSWindow) throws {
        guard let inputView = input.contentView as? CompanionView else { throw Failure("Missing input view") }
        let passive = NSApp.windows.filter { $0.isVisible && $0.contentView is CompanionCanvasView && !($0.contentView is CompanionView) }
        let requested = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: context.frame,
                                                    scale: snapshot.scene.scale,
                                                    visibleBounds: snapshot.dragGeometry == nil ? snapshot.hitBounds
                                                        : snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded))
        let paint = protectedPaint(snapshot, display: context.frame)
        let displays = snapshot.dragGeometry?.surfaces.map { surface in
            Rect(x: context.frame.minX + surface.bounds.minX, y: context.frame.maxY - surface.bounds.maxY,
                 width: surface.bounds.width, height: surface.bounds.height)
        } ?? []
        let layout = snapshot.dragGeometry == nil ? nil
            : WindowGeometry.desktopLayout(requested: requested, paint: paint, activeDisplay: context.frame, displays: displays)
        try require(inputView.drawsSnapshot == (layout == nil), "Input view duplicates drag artwork")
        try require(passive.count == (layout?.canvases.count ?? 0), "Unexpected passive canvas count")
        var bitmaps: [(CompanionCanvasView, NSBitmapImageRep)] = []
        let windows = layout == nil ? [input] : passive
        for window in windows {
            let canvas = window.contentView as! CompanionCanvasView
            let actual = rect(window.frame)
            if layout != nil {
                guard let surface = layout?.canvases.first(where: { covers($0.display, actual) }) else {
                    throw Failure("Passive canvas straddles physical displays")
                }
                try require(covers(actual, surface.frame), "Native placement cropped the planned canvas: actual=\(actual) expected=\(surface.frame) surface=\(surface.display)")
                try require(window.ignoresMouseEvents && !window.canBecomeKey && !window.canBecomeMain,
                            "Passive canvas can intercept input or focus")
                try require(!canvas.isAccessibilityElement(), "Passive canvas duplicates accessibility")
            }
            try require(canvas.snapshot.feet == snapshot.feet && canvas.snapshot.pose == snapshot.pose
                        && canvas.snapshot.time == snapshot.time, "Canvases are drawing different simulation states")
            let crown = snapshot.geometry.root.apply(snapshot.geometry.body.apply(Point(x: 0, y: -58)))
            for point in [snapshot.feet, crown] {
                let global = Point(x: actual.minX + point.x + canvas.drawingOrigin.x,
                                   y: actual.maxY - point.y - canvas.drawingOrigin.y)
                try require(MultiMonitorValidation.pointsWithinNativeTolerance(global, context.globalPoint(scene: point)),
                            "Canvas origin moved global feet/head")
            }
            let scale = window.backingScaleFactor
            let probe = canvas.convertToBacking(NSRect(x: 0, y: 0, width: 10, height: 10))
            try require(scale.isFinite && scale > 0 && abs(probe.width - 10 * scale) < 1e-8
                        && abs(probe.height - 10 * scale) < 1e-8, "Canvas backing conversion changed")
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                throw Failure("Could not allocate native canvas bitmap")
            }
            var drew = false
            let callback = canvas.onDraw
            canvas.onDraw = { _ in drew = true }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            canvas.onDraw = callback
            try require(drew, "Next production canvas draw did not execute")
            bitmaps.append((canvas, bitmap))
        }
        var expected = 0, retained = 0
        let geometry = snapshot.geometry
        for y in stride(from: -65.0, through: -45.0, by: 5) {
            for x in stride(from: -20.0, through: 20.0, by: 5) {
                let point = geometry.root.apply(geometry.body.apply(Point(x: x, y: y)))
                guard snapshot.contains(point) else { continue }
                expected += 1
                if hasPaint(at: point, in: bitmaps) { retained += 1 }
            }
        }
        try require(expected > 0 && retained == expected, "Native display canvases lost legal crown samples: \(retained)/\(expected)")
    }

    private static func validateHomeMask(snapshot: CompanionSnapshot) throws {
        let scene = snapshot.scene
        guard scene.home.minY > scene.bounds.minY else { return }
        var bitmaps: [(CompanionCanvasView, NSBitmapImageRep)] = []
        for window in NSApp.windows where window.isVisible {
            guard let canvas = window.contentView as? CompanionCanvasView, canvas.drawsSnapshot,
                  let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            bitmaps.append((canvas, bitmap))
        }
        var crownControl = 0, leaked = 0, hiddenHits = 0, visibleFace = 0
        for y in stride(from: scene.bounds.minY + 0.5, to: scene.home.maxY, by: 2) {
            for x in stride(from: scene.home.minX + 0.5, to: scene.home.maxX, by: 2) {
                let point = Point(x: x, y: y)
                if y < scene.home.minY && snapshot.geometry.contains(point) { crownControl += 1 }
                if snapshot.contains(point) { hiddenHits += 1 }
                if hasPaint(at: point, in: bitmaps) { leaked += 1 }
            }
        }
        for y in stride(from: scene.home.maxY + 1, to: scene.home.maxY + 60, by: 2) {
            for x in stride(from: scene.home.minX + 1, to: scene.home.maxX, by: 2) {
                if hasPaint(at: Point(x: x, y: y), in: bitmaps) { visibleFace += 1 }
            }
        }
        try require(crownControl > 20 && visibleFace > 100, "Native Home mask controls are empty")
        try require(leaked == 0 && hiddenHits == 0,
                    "Home exposed crown artwork or picks above its edge: paint=\(leaked), hits=\(hiddenHits), desktopDrag=\(snapshot.dragGeometry != nil)")
    }

    private static func hasPaint(at point: Point, in bitmaps: [(CompanionCanvasView, NSBitmapImageRep)]) -> Bool {
        bitmaps.contains { canvas, bitmap in
            let local = point + canvas.drawingOrigin
            guard canvas.bounds.contains(NSPoint(x: local.x, y: local.y)) else { return false }
            let px = Int((local.x - canvas.bounds.minX) * Double(bitmap.pixelsWide) / canvas.bounds.width)
            let py = Int((local.y - canvas.bounds.minY) * Double(bitmap.pixelsHigh) / canvas.bounds.height)
            return px >= 0 && px < bitmap.pixelsWide && py >= 0 && py < bitmap.pixelsHigh
                && bitmap.colorAt(x: px, y: py)!.alphaComponent > 0
        }
    }

    private static func dragGeometry(active: DisplayContext, displays: [DisplayContext]) -> DragGeometry {
        let offsets = displays.map { DesktopDragCoordinates.translation(from: $0.frame, to: active.frame) }
        let surfaces = displays.indices.map { index in
            let context = displays[index], delta = offsets[index]
            return DragSurface(bounds: Rect(x: delta.x, y: delta.y, width: context.frame.width, height: context.frame.height),
                               housing: Rect(x: delta.x + context.scene.homeOcclusion.x, y: delta.y + context.scene.homeOcclusion.y,
                                             width: context.scene.homeOcclusion.width, height: context.scene.homeOcclusion.height))
        }
        let left = displays.indices.map { offsets[$0].x + displays[$0].scene.leftLimit }.min()!
        let right = displays.indices.map { offsets[$0].x + displays[$0].scene.rightLimit }.max()!
        let top = displays.indices.map { offsets[$0].y + displays[$0].scene.ceiling }.min()!
        let bottom = displays.indices.map { offsets[$0].y + displays[$0].scene.floor }.max()!
        return DragGeometry(surfaces: surfaces, heldBounds: Rect(x: left, y: top, width: right - left, height: bottom - top))
    }
    private static func protectedPaint(_ snapshot: CompanionSnapshot, display: Rect) -> Rect {
        let paint = snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded), margin = 4 * snapshot.scene.scale
        return Rect(x: display.minX + paint.minX - margin, y: display.maxY - paint.maxY - margin,
                    width: paint.width + 2 * margin, height: paint.height + 2 * margin)
    }
    private static func visiblePoint(_ snapshot: CompanionSnapshot) throws -> Point {
        let hit = snapshot.hitBounds
        for y in stride(from: hit.minY, through: hit.maxY, by: 1) {
            for x in stride(from: hit.minX, through: hit.maxX, by: 1) {
                let point = Point(x: x, y: y)
                // Avoid an exact silhouette/housing boundary: conversion
                // through AppKit may differ by a fraction of a logical point.
                if [point, point + Point(x: -1, y: 0), point + Point(x: 1, y: 0),
                    point + Point(x: 0, y: -1), point + Point(x: 0, y: 1)].allSatisfy(snapshot.contains) {
                    return point
                }
            }
        }
        throw Failure("Snapshot has no visible pick")
    }
    private static func rect(_ frame: NSRect) -> Rect { Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
    private static func covers(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX && inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
