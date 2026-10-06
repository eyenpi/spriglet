import AppKit
import QuartzCore
import CompanionCore
import CompanionRendering

/// Snapshot-only drawing shared by the interactive view and passive display
/// surfaces. It owns neither input, simulation state nor an animation clock.
@MainActor class CompanionCanvasView: NSView {
    var snapshot: CompanionSnapshot
    var drawingOrigin = Point.zero
    var surfaceBounds: Rect?
    var drawsSnapshot = true
    var onDraw: ((Double) -> Void)?
    private let renderer = MallowRenderer()

    init(frame: NSRect, snapshot: CompanionSnapshot) {
        self.snapshot = snapshot
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:snapshot:)") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsSnapshot else { return }
        let started = onDraw == nil ? nil : CACurrentMediaTime()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: drawingOrigin.x, yBy: drawingOrigin.y); transform.concat()
        if let surfaceBounds {
            NSBezierPath(rect: NSRect(x: surfaceBounds.x, y: surfaceBounds.y,
                                     width: surfaceBounds.width, height: surfaceBounds.height)).addClip()
        }
        renderer.draw(snapshot)
        NSGraphicsContext.restoreGraphicsState()
        if let started { onDraw?(CACurrentMediaTime() - started) }
    }
}
