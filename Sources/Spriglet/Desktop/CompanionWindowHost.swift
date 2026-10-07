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
        canvas.drawingOrigin = WindowGeometry.drawingOrigin(
            window: Rect(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height), display: context.frame)
        canvas.surfaceBounds = Rect(x: surface.minX - context.frame.minX, y: context.frame.maxY - surface.maxY,
                                    width: surface.width, height: surface.height)
        canvas.snapshot = snapshot; canvas.needsDisplay = true
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

/// One persistent input panel and temporary, click-through canvases on touched
/// displays. Drag presentation stays on physical displays as pointer ownership
/// changes; every canvas draws the same immutable snapshot in global space.
@MainActor final class CompanionWindowHost {
    private struct PassiveSurface {
        let display: Rect
        let window: CompanionWindowSurface
    }
    var onInput: ((CompanionInput) -> Void)?
    var onPointerInput: ((DesktopPointerInput) -> Void)?
    var onControlAction: ((AppControlAction) -> Void)?
    var onDraw: ((Double) -> Void)?
    private var primary: CompanionWindowSurface?
    private var passive: [PassiveSurface] = []
    private var visible = false

    func attach(context: DisplayContext, snapshot: CompanionSnapshot) {
        close()
        let view = CompanionView(context: context, snapshot: snapshot)
        view.onInput = { [weak self] input in self?.onInput?(input) }
        view.onPointerInput = { [weak self] input in self?.onPointerInput?(input) }
        view.onControlAction = { [weak self] in self?.onControlAction?($0) }
        view.onDraw = onDraw
        primary = CompanionWindowSurface(canvas: view, acceptsPointer: true)
        update(snapshot: snapshot, capturesPointer: false, pointer: context.point(NSEvent.mouseLocation))
    }
    /// Retargeting never replaces the input view or ends native pointer capture.
    func retarget(context: DisplayContext) {
        (primary?.canvas as? CompanionView)?.retarget(context: context)
    }
    func update(snapshot: CompanionSnapshot, capturesPointer: Bool, pointer: Point,
                acceptsInput: Bool = true, isPaused: Bool = false) {
        guard let primary, let view = primary.canvas as? CompanionView else { return }
        let context = view.context
        let paint = snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded)
        let requested = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: context.frame,
                                                    scale: snapshot.scene.scale,
                                                    visibleBounds: snapshot.dragGeometry == nil ? snapshot.hitBounds : paint)
        let padding = 4 * snapshot.scene.scale
        let protectedPaint = Rect(x: context.frame.minX + paint.minX - padding,
                                  y: context.frame.maxY - paint.maxY - padding,
                                  width: paint.width + 2 * padding, height: paint.height + 2 * padding)
        let displays = snapshot.dragGeometry?.surfaces.map { surface in
            Rect(x: context.frame.minX + surface.bounds.minX, y: context.frame.maxY - surface.bounds.maxY,
                 width: surface.bounds.width, height: surface.bounds.height)
        } ?? []
        let layout = snapshot.dragGeometry == nil ? nil
            : WindowGeometry.desktopLayout(requested: requested, paint: protectedPaint,
                                            activeDisplay: context.frame, displays: displays)
        view.drawsSnapshot = layout == nil
        primary.update(frame: layout?.inputFrame ?? WindowGeometry.containedFrame(requested, in: context.frame),
                       surface: context.frame, context: context, snapshot: snapshot)
        let passThrough = !acceptsInput || (!capturesPointer && !snapshot.contains(pointer))
        if primary.panel.ignoresMouseEvents != passThrough { primary.panel.ignoresMouseEvents = passThrough }
        view.refresh(snapshot: snapshot, acceptsInput: acceptsInput, isPaused: isPaused)
        updatePassive(layout?.canvases ?? [], context: context, snapshot: snapshot)
    }
    private func updatePassive(_ frames: [DisplayWindowFrame], context: DisplayContext, snapshot: CompanionSnapshot) {
        // Keep canvases on their physical display when the logical scene changes.
        // A drag can reverse across a seam without churning those native windows.
        var next: [PassiveSurface] = []
        for frame in frames {
            let window: CompanionWindowSurface
            if let index = passive.firstIndex(where: { $0.display == frame.display }) {
                window = passive.remove(at: index).window
            } else {
                let canvas = CompanionCanvasView(frame: NSRect(x: 0, y: 0, width: frame.frame.width,
                                                               height: frame.frame.height), snapshot: snapshot)
                canvas.onDraw = onDraw
                window = CompanionWindowSurface(canvas: canvas, acceptsPointer: false)
            }
            window.update(frame: frame.frame, surface: frame.display, context: context, snapshot: snapshot)
            window.setVisible(visible)
            next.append(PassiveSurface(display: frame.display, window: window))
        }
        for surface in passive { surface.window.close() }
        passive = next
    }
    func setVisible(_ visible: Bool, restoringOrder: Bool = false) {
        self.visible = visible
        primary?.setVisible(visible, restoringOrder: restoringOrder)
        for surface in passive { surface.window.setVisible(visible, restoringOrder: restoringOrder) }
    }
    func close() {
        if let view = primary?.canvas as? CompanionView {
            view.onInput = nil; view.onPointerInput = nil; view.onControlAction = nil
        }
        for surface in passive { surface.window.close() }
        passive = []; primary?.close(); primary = nil; visible = false
    }
}
