import AppKit
import CompanionCore

@MainActor private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // These borderless desktop canvases deliberately use the full display.
    // AppKit's title-bar safety constraint would move a seam tile below the
    // menu bar and discard the very pixels that belong at the display edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns one native canvas and caches requested placement independently of any
/// adjustment by AppKit. It has no input dispatch, simulation or display clock.
@MainActor private final class CompanionWindowSurface {
    let panel: NSPanel
    let canvas: CompanionCanvasView
    private var requestedFrame: Rect?
    private var retainedFrame: Rect?

    init(canvas: CompanionCanvasView, acceptsPointer: Bool) {
        self.canvas = canvas
        panel = CompanionPanel(contentRect: canvas.bounds, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true; panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.title = acceptsPointer ? AppText.companionName : "Spriglet display canvas"
        panel.contentView = canvas; panel.ignoresMouseEvents = true
        if !acceptsPointer { panel.setAccessibilityElement(false) }
    }
    func update(frame: Rect, surface: Rect, context: DisplayContext, snapshot: CompanionSnapshot) {
        if requestedFrame.map({ abs(frame.x - $0.x) > 0.05 || abs(frame.y - $0.y) > 0.05
            || abs(frame.width - $0.width) > 0.05 || abs(frame.height - $0.height) > 0.05 }) ?? true {
            panel.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            requestedFrame = frame
        }
        let actual = panel.frame
        let origin = WindowGeometry.drawingOrigin(
            window: Rect(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height), display: context.frame)
        let bounds = Rect(x: surface.minX - context.frame.minX, y: context.frame.maxY - surface.maxY,
                          width: surface.width, height: surface.height)
        canvas.present(snapshot: snapshot, origin: origin, surface: bounds)
    }
    func paint(frame: DisplayWindowFrame, context: DisplayContext, snapshot: CompanionSnapshot) {
        let retained = WindowGeometry.retainedCanvasFrame(covering: frame.frame, in: frame.display,
                                                         scale: snapshot.scene.scale, previous: retainedFrame)
        update(frame: retained, surface: frame.display, context: context, snapshot: snapshot)
        retainedFrame = retained
    }
    func setVisible(_ visible: Bool, restoringOrder: Bool = false) {
        guard restoringOrder || panel.isVisible != visible else { return }
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    func close() {
        canvas.onDraw = nil
        panel.orderOut(nil); panel.close()
    }
}

/// Input capture never changes which window paints a physical display.
/// Click-through canvases survive pointer transactions and draw in global space.
@MainActor final class CompanionWindowHost {
    private struct DisplaySurface {
        let display: Rect
        let window: CompanionWindowSurface
        var isPainting: Bool
    }
    var onInput: ((CompanionInput) -> Void)?
    var onPointerInput: ((DesktopPointerInput) -> Void)?
    var onControlAction: ((AppControlAction) -> Void)?
    var onDraw: ((Double) -> Void)?
    private var input: CompanionWindowSurface?
    private var surfaces: [DisplaySurface] = []
    // Release snapshots can outlive a display. The runtime's inventory stays
    // authoritative across window teardown and reattachment.
    private var connectedDisplays: [Rect]?
    private var visible = false

    func attach(context: DisplayContext, snapshot: CompanionSnapshot) {
        close()
        let view = CompanionView(context: context, snapshot: snapshot)
        view.onInput = { [weak self] input in self?.onInput?(input) }
        view.onPointerInput = { [weak self] input in self?.onPointerInput?(input) }
        view.onControlAction = { [weak self] in self?.onControlAction?($0) }
        view.drawsSnapshot = false
        input = CompanionWindowSurface(canvas: view, acceptsPointer: true)
        update(snapshot: snapshot, capturesPointer: false, pointer: context.point(NSEvent.mouseLocation))
    }
    /// Retargeting never replaces the input view or ends native pointer capture.
    func retarget(context: DisplayContext) {
        (input?.canvas as? CompanionView)?.retarget(context: context)
    }
    func update(snapshot: CompanionSnapshot, capturesPointer: Bool, pointer: Point,
                acceptsInput: Bool = true, isPaused: Bool = false) {
        guard let input, let view = input.canvas as? CompanionView else { return }
        let context = view.context
        let paint = snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded)
        let requested = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: context.frame,
                                                    scale: snapshot.scene.scale,
                                                    visibleBounds: snapshot.dragGeometry == nil ? snapshot.inputBounds : paint)
        let padding = 4 * snapshot.scene.scale
        let protectedPaint = Rect(x: context.frame.minX + paint.minX - padding,
                                  y: context.frame.maxY - paint.maxY - padding,
                                  width: paint.width + 2 * padding, height: paint.height + 2 * padding)
        let displays = snapshot.dragGeometry?.surfaces.map { surface in
            Rect(x: context.frame.minX + surface.bounds.minX, y: context.frame.maxY - surface.bounds.maxY,
                 width: surface.bounds.width, height: surface.bounds.height)
        } ?? []
        guard let layout = WindowGeometry.desktopLayout(requested: requested, paint: protectedPaint,
                                                        activeDisplay: context.frame, displays: displays) else {
            preconditionFailure("A companion snapshot must have finite display and paint bounds")
        }
        input.update(frame: layout.inputFrame,
                       surface: context.frame, context: context, snapshot: snapshot)
        let passThrough = !acceptsInput || (!capturesPointer && !snapshot.contains(pointer))
        if input.panel.ignoresMouseEvents != passThrough { input.panel.ignoresMouseEvents = passThrough }
        view.refresh(snapshot: snapshot, acceptsInput: acceptsInput, isPaused: isPaused)
        updateCanvases(layout.canvases, context: context, snapshot: snapshot)
    }
    private func updateCanvases(_ frames: [DisplayWindowFrame], context: DisplayContext, snapshot: CompanionSnapshot) {
        for index in surfaces.indices { surfaces[index].isPainting = false }
        for frame in frames where connectedDisplays?.contains(frame.display) ?? true {
            let window: CompanionWindowSurface
            if let index = surfaces.firstIndex(where: { $0.display == frame.display }) {
                window = surfaces[index].window
                surfaces[index].isPainting = true
            } else {
                let canvas = CompanionCanvasView(frame: NSRect(x: 0, y: 0, width: frame.frame.width,
                                                               height: frame.frame.height), snapshot: snapshot)
                canvas.onDraw = onDraw
                window = CompanionWindowSurface(canvas: canvas, acceptsPointer: false)
                surfaces.append(DisplaySurface(display: frame.display, window: window, isPainting: true))
            }
            window.paint(frame: frame, context: context, snapshot: snapshot)
        }
        for surface in surfaces { surface.window.setVisible(visible && surface.isPainting) }
    }
    func updateDisplays(_ displays: [Rect]) {
        connectedDisplays = displays
        surfaces.removeAll { surface in
            guard !displays.contains(surface.display) else { return false }
            surface.window.close()
            return true
        }
    }
    func setVisible(_ visible: Bool, restoringOrder: Bool = false) {
        self.visible = visible
        input?.setVisible(visible, restoringOrder: restoringOrder)
        for surface in surfaces { surface.window.setVisible(visible && surface.isPainting, restoringOrder: restoringOrder) }
    }
    func close() {
        if let view = input?.canvas as? CompanionView {
            view.onInput = nil; view.onPointerInput = nil; view.onControlAction = nil
        }
        for surface in surfaces { surface.window.close() }
        surfaces = []; input?.close(); input = nil; visible = false
    }
}
