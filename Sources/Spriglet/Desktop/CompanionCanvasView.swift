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
    func present(snapshot: CompanionSnapshot, origin: Point, surface: Rect) {
        let previous = drawsSnapshot ? localPaintBounds : .null
        self.snapshot = snapshot; drawingOrigin = origin; surfaceBounds = surface
        guard drawsSnapshot else { return }
        setNeedsDisplay(previous.union(localPaintBounds).intersection(bounds))
    }
    private var localPaintBounds: NSRect {
        let paint = snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded)
        let padding = 4 * snapshot.scene.scale
        var rect = NSRect(x: paint.x - padding, y: paint.y - padding,
                          width: paint.width + 2 * padding, height: paint.height + 2 * padding)
        if let surfaceBounds {
            rect = rect.intersection(NSRect(x: surfaceBounds.x, y: surfaceBounds.y,
                                            width: surfaceBounds.width, height: surfaceBounds.height))
        }
        return rect.offsetBy(dx: drawingOrigin.x, dy: drawingOrigin.y)
    }
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
