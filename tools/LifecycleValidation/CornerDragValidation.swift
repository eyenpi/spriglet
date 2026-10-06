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
        }
        print("Both triangle corner native checks passed: production View input, capture, actual paint coverage, next draw, inward drag, seam travel, release and regrab. Compositor-visible output and physical mouse delivery remain unverified.")
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
        var draws = 0
        host.onDraw = { _ in draws += 1 }
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        host.attach(context: context, snapshot: engine.snapshot)
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
                                                        scale: snapshot.scene.scale, visibleBounds: snapshot.hitBounds)
            let paint = protectedPaint(snapshot, display: d)
            let expected = !engine.hasPointerCapture && snapshot.phase != .held && snapshot.dragGeometry == nil
                ? WindowGeometry.containedFrame(requested, in: d)
                : WindowGeometry.axisContainedFrame(requested, in: d, protecting: paint)
            try require(ObjectIdentifier(panel) == identity && panel.contentView === view,
                        "Drag replaced the panel or view")
            try require(view.context.hasSameLayout(as: context), "Placement changed the logical display")
            if protectFullPaint {
                try require(covers(actual, paint), "Actual native window clips protected paint at \(stage): A=\(actual), G=\(paint)")
                let viewPaint = Rect(x: paint.x - actual.minX, y: actual.maxY - paint.maxY,
                                     width: paint.width, height: paint.height)
                try require(covers(rect(view.bounds), viewPaint), "Actual content-view bounds clip paint at \(stage)")
                if paint.minX >= d.minX && paint.maxX <= d.maxX {
                    try require(actual.minX >= d.minX && actual.maxX <= d.maxX, "Native X containment failed")
                }
                if paint.minY >= d.minY && paint.maxY <= d.maxY {
                    try require(actual.minY >= d.minY && actual.maxY <= d.maxY, "Native Y containment failed")
                }
            }
            for point in [snapshot.feet, snapshot.geometry.root.apply(snapshot.geometry.body.apply(Point(x: 0, y: -58)))] {
                let origin = view.drawingOrigin
                let actualGlobal = Point(x: actual.minX + point.x + origin.x, y: actual.maxY - point.y - origin.y)
                try require(MultiMonitorValidation.pointsWithinNativeTolerance(actualGlobal, context.globalPoint(scene: point)),
                            "Actual-frame compensation moved feet/head")
            }
            let scale = panel.backingScaleFactor, probe = view.convertToBacking(NSRect(x: 0, y: 0, width: 10, height: 10))
            try require(scale.isFinite && scale > 0 && abs(probe.width - 10 * scale) < 1e-8
                        && abs(probe.height - 10 * scale) < 1e-8, "Native view backing conversion changed")
            let oldDraws = draws
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("Could not allocate native draw bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try require(draws > oldDraws, "Next production View draw did not execute")
            var paintedCrownSamples = 0
            let geometry = snapshot.geometry
            for y in stride(from: -70.0, through: -45.0, by: 5) {
                for x in stride(from: -25.0, through: 25.0, by: 5) {
                    let point = geometry.root.apply(geometry.body.apply(Point(x: x, y: y)))
                    guard snapshot.contains(point) else { continue }
                    let local = point + view.drawingOrigin
                    let pixelX = Int((local.x - view.bounds.minX) * Double(bitmap.pixelsWide) / view.bounds.width)
                    let pixelY = Int((local.y - view.bounds.minY) * Double(bitmap.pixelsHigh) / view.bounds.height)
                    if pixelX >= 0 && pixelX < bitmap.pixelsWide && pixelY >= 0 && pixelY < bitmap.pixelsHigh,
                       bitmap.colorAt(x: pixelX, y: pixelY)!.alphaComponent > 0 { paintedCrownSamples += 1 }
                }
            }
            try require(paintedCrownSamples > 0, "Next native View draw has no visible crown pixels at \(stage)")
            print("CORNER_DRAG stage=\(stage) display=\(d) R=\(requested) H=\(expected) A=\(actual) paint=\(paint) origin=\(view.drawingOrigin) backing=\(scale) screen=\(String(describing: panel.screen?.frame)) fullPaint=\(protectFullPaint) nextDraw=true")
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

    private static func dragGeometry(active: DisplayContext, displays: [DisplayContext]) -> DragGeometry {
        let offsets = displays.map { DesktopDragCoordinates.translation(from: $0.frame, to: active.frame) }
        let surfaces = displays.indices.map { index in
            let context = displays[index], delta = offsets[index]
            return DragSurface(bounds: Rect(x: delta.x, y: delta.y, width: context.frame.width, height: context.frame.height),
                               housing: Rect(x: delta.x + context.scene.home.x, y: delta.y + context.scene.home.y,
                                             width: context.scene.home.width, height: context.scene.home.height))
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
                if snapshot.contains(point) { return point }
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
