import AppKit
import QuartzCore
import CompanionCore
import CompanionRendering

@MainActor final class CompanionView: NSView {
    var onInput: ((CompanionInput) -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    /// Optional instrumentation owned by the finite profiling tool.
    var onDraw: ((Double) -> Void)?
    var context: DisplayContext
    var snapshot: CompanionSnapshot
    var drawingOrigin = Point.zero
    private let renderer = MallowRenderer()
    private var presenceDescription = ""
    init(context: DisplayContext, snapshot: CompanionSnapshot) {
        self.context = context; self.snapshot = snapshot
        super.init(frame: NSRect(x: 0, y: 0, width: WindowGeometry.width, height: WindowGeometry.height))
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(AppText.companionName); setAccessibilityHelp(AppText.interactionHelp)
    }
    required init?(coder: NSCoder) { fatalError("Use init(context:snapshot:)") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let started = onDraw == nil ? nil : CACurrentMediaTime()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: drawingOrigin.x, yBy: drawingOrigin.y); transform.concat()
        renderer.draw(snapshot)
        NSGraphicsContext.restoreGraphicsState()
        if let started { onDraw?(CACurrentMediaTime() - started) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return snapshot.contains(Point(x: p.x - drawingOrigin.x, y: p.y - drawingOrigin.y)) ? self : nil
    }
    override func accessibilityFrame() -> NSRect {
        let hit = snapshot.hitBounds
        return NSRect(x: context.frame.minX + hit.minX, y: context.frame.maxY - hit.maxY, width: hit.width, height: hit.height)
    }
    override func accessibilityPerformPress() -> Bool { onInput?(.activate); return true }
    func refresh(snapshot: CompanionSnapshot) {
        self.snapshot = snapshot
        let description = switch snapshot.presence {
        case .peek: AppText.restingPresence
        case .engaged: AppText.engagedPresence
        case .playing: AppText.playingPresence
        }
        if description != presenceDescription { presenceDescription = description; setAccessibilityValue(description) }
        needsDisplay = true
    }
    private func point(_ event: NSEvent) -> Point {
        if let window { return context.point(window.convertPoint(toScreen: event.locationInWindow)) }
        return context.point(NSEvent.mouseLocation)
    }
    override func mouseDown(with event: NSEvent) { onInput?(.pointerPressed(point(event))) }
    override func mouseDragged(with event: NSEvent) { onInput?(.pointerDragged(point(event))) }
    override func mouseUp(with event: NSEvent) { onInput?(.pointerReleased(point(event))) }
    override func rightMouseDown(with event: NSEvent) {
        onInput?(.command(.returnHome))
        // App-level controls are supplied by the composition root. The transient
        // menu does not make the companion panel key or activate it on reopen.
        if let menu = makeContextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
