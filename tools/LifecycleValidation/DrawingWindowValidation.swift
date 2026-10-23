import AppKit
import CompanionCore

@MainActor private final class DrawingProbe: CompanionCanvasView {
    var dirtyRects: [NSRect] = []
    override func draw(_ dirtyRect: NSRect) {
        dirtyRects.append(dirtyRect)
        super.draw(dirtyRect)
    }
}

@MainActor enum DrawingWindowValidation {
    static func painters() -> [NSWindow] {
        NSApp.windows.filter {
            $0.isVisible && ($0.contentView as? CompanionCanvasView)?.drawsSnapshot == true
        }
    }

    static func run() throws {
        guard let screen = NSScreen.screens.first else {
            throw ValidationFailure(description: "Drawing window validation requires a display")
        }
        let context = DisplayContext(screen: screen)
        let suite = "dev.spriglet.drawing-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        var preferences = store.load()
        preferences.characterSize = .medium
        store.save(preferences)
        let introduction = IntroductionPreferences(defaults: defaults)
        introduction.recordDismissal()
        let host = CompanionWindowHost(), clock = ScreenFrameClock()
        var pointer = Point.zero
        let runtime = CompanionRuntime(environment: DesktopEnvironment(displays: { [context] }),
                                       clock: clock, host: host, introductionPreferences: introduction,
                                       preferenceStore: store, leftButtonIsDown: { true }, pointerLocation: { pointer })
        defer { runtime.stop() }
        runtime.start(); clock.stop()
        let input = try LifecycleValidation.visiblePanel()
        let view = LifecycleValidation.view(input)
        pointer = view.context.globalPoint(scene: view.snapshot.hitBounds.center)
        let originalPainters = painters()
        try LifecycleValidation.require(originalPainters.count == 1, "Expected one painter before clicking")
        let painter = originalPainters[0], size = painter.frame.size
        func check(_ stage: String, unchangedSize: Bool = true) throws {
            let current = painters()
            try LifecycleValidation.require(current.count == 1 && current[0] === painter,
                                            "\(stage) replaced the window painting Mallow")
            try LifecycleValidation.require(!unchangedSize || painter.frame.size == size, "\(stage) resized the normal animation canvas")
            try LifecycleValidation.require(try LifecycleValidation.visiblePanel() === input,
                                            "\(stage) replaced the input window")
        }
        func event(_ type: NSEvent.EventType) throws {
            let local = input.convertPoint(fromScreen: NSPoint(x: pointer.x, y: pointer.y))
            guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                                                timestamp: 0, windowNumber: input.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw ValidationFailure(description: "Could not create native pointer event")
            }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        for click in 0..<30 {
            try event(.leftMouseDown)
            try LifecycleValidation.require(!input.ignoresMouseEvents, "Click did not capture input")
            try check("mouse-down \(click)")
            for _ in 0..<3 { clock.onTick?(1 / 60.0) }
            try event(.leftMouseUp)
            try check("mouse-up \(click)")
            for _ in 0..<9 { clock.onTick?(1 / 60.0) }
        }
        try event(.leftMouseDown)
        pointer.y -= 140
        try event(.leftMouseDragged)
        for _ in 0..<120 { clock.onTick?(1 / 60.0) }
        try LifecycleValidation.require(view.snapshot.phase == .held && !input.ignoresMouseEvents,
                                        "Drag lost input capture")
        try check("held drag", unchangedSize: false)
        try CornerDragValidation.validatePresentation(snapshot: view.snapshot, context: view.context, input: input)
        try event(.leftMouseUp)
        for _ in 0..<240 { clock.onTick?(1 / 60.0) }
        try check("released drag", unchangedSize: false)
        runtime.setPaused(true)
        try LifecycleValidation.require(painters().count == 1 && painters()[0] === painter && input.ignoresMouseEvents,
                                        "Pause changed the painter or retained input")
        runtime.setVisible(false)
        try LifecycleValidation.require(painters().isEmpty && !input.isVisible, "Hide left a visible companion")
        runtime.setVisible(true)
        try check("show", unchangedSize: false)
        runtime.stop()
        try LifecycleValidation.require(painters().isEmpty && !painter.isVisible && !input.isVisible,
                                        "Stop leaked a drawing or input window")
        try partialDrawing(screen: screen)
        try adjacentCanvases(screen: screen)
        print("Stable drawing windows passed: 30 native click pairs, held/released drag, paint coverage, pause, hide/show and stop; no OS mouse events or saved app preferences were used.")
    }

    private static func adjacentCanvases(screen: NSScreen) throws {
        // Two logical surfaces share the connected screen's backing scale.
        // This exercises transfers without claiming physical seam acceptance.
        let bounds = screen.frame, width = (bounds.width / 2).rounded(.down)
        let left = Rect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let right = Rect(x: left.maxX, y: bounds.minY, width: bounds.width - width, height: bounds.height)
        func context(_ frame: Rect) -> DisplayContext {
            let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: frame.width, height: frame.height),
                                      home: Rect(x: frame.width - 210, y: 0, width: 180, height: 20),
                                      floor: frame.height - 40, scale: 0.8, hasHardwareNotch: false)
            return DisplayContext(screen: screen, id: 0, frame: frame, scene: scene)
        }
        let origin = context(left), destination = context(right)
        let geometry = DragGeometry(surfaces: [
            DragSurface(bounds: origin.scene.bounds, housing: origin.scene.homeOcclusion),
            DragSurface(bounds: Rect(x: width, y: 0, width: right.width, height: right.height),
                        housing: Rect(x: width + destination.scene.homeOcclusion.x, y: 0,
                                      width: destination.scene.home.width, height: destination.scene.home.maxY)),
        ], heldBounds: Rect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        var engine = CompanionEngine(scene: origin.scene)
        let host = CompanionWindowHost()
        defer { host.close() }
        host.attach(context: origin, snapshot: engine.snapshot); host.setVisible(true)
        let input = try LifecycleValidation.visiblePanel(), leftPainter = painters()[0]
        let start = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(start))
        try LifecycleValidation.require(engine.beginDesktopDrag(geometry: geometry), "Synthetic seam grab was rejected")
        engine.send(.pointerDragged(start + Point(x: width - engine.snapshot.feet.x, y: 150 - engine.snapshot.feet.y)))
        for _ in 0..<120 { engine.advance(by: 1 / 60.0) }
        func refresh() {
            host.update(snapshot: engine.snapshot, capturesPointer: engine.hasPointerCapture, pointer: engine.snapshot.hitBounds.center)
        }
        refresh()
        let seamPainters = painters()
        try LifecycleValidation.require(seamPainters.count == 2 && seamPainters.contains { $0 === leftPainter },
                                        "Straddling paint did not retain the first display's painter")
        let identities = Set(seamPainters.map(ObjectIdentifier.init))
        try CornerDragValidation.validatePresentation(snapshot: engine.snapshot, context: origin, input: input)
        try LifecycleValidation.require(engine.transferDrag(scene: destination.scene, translation: Point(x: -width, y: 0),
                                                             geometry: geometry.translated(by: Point(x: -width, y: 0))),
                                        "Synthetic seam transfer was rejected")
        host.retarget(context: destination); refresh()
        try LifecycleValidation.require(Set(painters().map(ObjectIdentifier.init)) == identities,
                                        "Pointer transfer replaced a display's painter")
        try LifecycleValidation.require(try LifecycleValidation.visiblePanel() === input && !input.ignoresMouseEvents,
                                        "Pointer transfer replaced the input window or lost capture")
        try CornerDragValidation.validatePresentation(snapshot: engine.snapshot, context: destination, input: input)
        engine.send(.cancelInteraction); refresh()
        try LifecycleValidation.require(painters().count == 1 && !leftPainter.isVisible,
                                        "Cancellation left artwork visible on the other display")
        engine.reconfigure(scene: origin.scene); host.retarget(context: origin); refresh()
        host.setVisible(false); host.setVisible(true)
        try LifecycleValidation.require(painters().count == 1 && painters()[0] === leftPainter,
                                        "Revisiting a display replaced its painter or showed an inactive canvas")
        host.updateDisplays([right])
        try LifecycleValidation.require(painters().isEmpty && !leftPainter.isVisible,
                                        "Disconnect left a display's painter visible")
        print("Adjacent logical surfaces passed: complete seam paint, unchanged painters/input during transfer, cancellation, reuse, visibility and disconnect. One physical display/backing scale was used.")
    }

    private static func partialDrawing(screen: NSScreen) throws {
        func snapshot(x: Double) -> CompanionSnapshot {
            CompanionSnapshot(scene: .preview, presence: .playing, phase: .grounded, pose: CharacterPose(),
                              feet: Point(x: x, y: 250), windowAnchor: Point(x: x, y: 250), rotation: 0,
                              openness: 1, homeGrip: 0, time: 0, gesture: nil, canCatch: false)
        }
        let first = snapshot(x: 150), next = snapshot(x: 180)
        let canvas = DrawingProbe(frame: NSRect(x: 0, y: 0, width: 600, height: 400), snapshot: first)
        let window = NSPanel(contentRect: NSRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                                                width: 600, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true; window.contentView = canvas
        defer { window.orderOut(nil); window.close() }
        window.orderFrontRegardless()
        LifecycleValidation.pump()
        canvas.display()
        canvas.dirtyRects = []
        canvas.present(snapshot: next, origin: .zero, surface: Rect(x: 0, y: 0, width: 600, height: 400))
        canvas.displayIfNeeded()
        guard let dirty = canvas.dirtyRects.first else {
            throw ValidationFailure(description: "Moving paint did not redraw the native canvas: frame=\(canvas.frame), bounds=\(canvas.bounds), visible=\(window.isVisible), dirty=\(canvas.needsDisplay)")
        }
        try LifecycleValidation.require(dirty.width * dirty.height < canvas.bounds.width * canvas.bounds.height / 2,
                                        "Moving paint invalidated the entire large canvas")
        for frame in [first, next] {
            let paint = frame.geometry.paintBounds(drawShadow: true)
            try LifecycleValidation.require(dirty.contains(NSRect(x: paint.x, y: paint.y, width: paint.width, height: paint.height)),
                                            "Dirty region omitted old or new artwork/shadow")
        }

        func bitmap() throws -> NSBitmapImageRep {
            guard let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw ValidationFailure(description: "Could not allocate retained-paint bitmap")
            }
            memset(result.bitmapData!, 0, result.bytesPerRow * result.pixelsHigh)
            return result
        }
        func draw(_ frame: CompanionSnapshot, into bitmap: NSBitmapImageRep, dirty: NSRect) throws {
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw ValidationFailure(description: "Could not create retained-paint context")
            }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let cg = context.cgContext
            cg.translateBy(x: 0, y: 400); cg.scaleBy(x: 1, y: -1); cg.clip(to: dirty)
            // Standalone bitmap contexts lack the window's transparent
            // background pass that precedes an on-screen view draw.
            cg.clear(dirty)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            canvas.snapshot = frame
            canvas.draw(dirty)
        }
        let retained = try bitmap(), expected = try bitmap()
        try draw(first, into: retained, dirty: canvas.bounds)
        try draw(next, into: retained, dirty: dirty)
        try draw(next, into: expected, dirty: canvas.bounds)
        try LifecycleValidation.require(memcmp(retained.bitmapData!, expected.bitmapData!, retained.bytesPerRow * retained.pixelsHigh) == 0,
                                        "Partial drawing left old body/shadow pixels or cropped new artwork")
        print("Partial drawing passed: native dirty region covers old/new artwork and a retained bitmap matches a fresh full render exactly.")
    }
}
