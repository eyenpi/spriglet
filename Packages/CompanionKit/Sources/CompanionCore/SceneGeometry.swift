/// macOS supplies measurements; the simulation never queries a display itself.
public struct SceneGeometry: Equatable, Sendable {
    public let bounds: Rect
    public let home: Rect
    public let floor: Double
    public let scale: Double
    public let hasHardwareNotch: Bool
    public var homeFeet: Point { Point(x: home.midX, y: home.maxY + 60 * scale) }
    /// Free motion keeps enough of the body below the display and housing to
    /// remain reachable. The resting peek can be grabbed without a position jump.
    public var ceiling: Double {
        min(homeFeet.y - 30 * scale, max(bounds.minY + 60 * scale, home.maxY + 12 * scale))
    }
    public var leftLimit: Double { bounds.minX + min(55 * scale, bounds.width / 4) }
    public var rightLimit: Double { bounds.maxX - min(55 * scale, bounds.width / 4) }
    public init(bounds: Rect, home: Rect, floor: Double, scale: Double = 1, hasHardwareNotch: Bool = true) {
        precondition(bounds.isValid && bounds.width > 0 && bounds.height > 0)
        precondition(home.isValid && home.width > 0 && home.height > 0)
        precondition(scale.isFinite && scale > 0 && floor.isFinite && floor > home.maxY && floor <= bounds.maxY)
        self.bounds = bounds; self.home = home; self.floor = floor; self.scale = scale
        self.hasHardwareNotch = hasHardwareNotch
    }
    public static let preview = SceneGeometry(
        bounds: Rect(x: 0, y: 0, width: 720, height: 420),
        home: Rect(x: 260, y: 0, width: 200, height: 54), floor: 365, scale: 1.05
    )
}

/// Coordinates shared by the host and tests. The actual window may be clamped
/// by macOS, so derive the drawing origin from its final frame.
public enum WindowGeometry {
    public static let width = 220.0
    public static let height = 180.0
    public static let feetOffset = 110.0
    public static func desiredFrame(feet: Point, display: Rect, scale: Double = 1, visibleBounds: Rect? = nil) -> Rect {
        var left = feet.x - width * scale / 2, top = feet.y - feetOffset * scale
        var right = left + width * scale, bottom = top + height * scale
        // A grab can briefly stretch the attached hands beyond the body canvas.
        // Include the painted silhouette while keeping the normal decoration margins.
        if let visibleBounds {
            let padding = 4 * scale
            left = min(left, visibleBounds.minX - padding); top = min(top, visibleBounds.minY - padding)
            right = max(right, visibleBounds.maxX + padding); bottom = max(bottom, visibleBounds.maxY + padding)
        }
        return Rect(x: display.minX + left, y: display.maxY - bottom, width: right - left, height: bottom - top)
    }
    /// Keeps a requested panel rectangle inside one logical display. Oversized
    /// axes are reduced only as much as needed; invalid rectangles are left to
    /// the existing window-server behavior.
    public static func containedFrame(_ requested: Rect, in display: Rect) -> Rect {
        guard requested.hasFinitePositiveEdges, display.hasFinitePositiveEdges else { return requested }
        let width = min(requested.width, display.width)
        let height = min(requested.height, display.height)
        let x = min(max(requested.minX, display.minX), display.maxX - width)
        let y = min(max(requested.minY, display.minY), display.maxY - height)
        let contained = Rect(x: x, y: y, width: width, height: height)
        return contained.hasFinitePositiveEdges ? contained : requested
    }
    /// Remove off-display padding independently on each axis, keeping the
    /// complete unmasked paint envelope on the canvas. An axis with artwork
    /// crossing a display seam must remain free for continuous desktop dragging.
    public static func axisContainedFrame(_ requested: Rect, in display: Rect, protecting paint: Rect) -> Rect {
        guard requested.hasFinitePositiveEdges, display.hasFinitePositiveEdges,
              paint.hasFinitePositiveEdges, requested.covers(paint) else { return requested }
        let contained = containedFrame(requested, in: display)
        let constrainX = paint.minX >= display.minX && paint.maxX <= display.maxX
            && paint.minX >= contained.minX && paint.maxX <= contained.maxX
        let constrainY = paint.minY >= display.minY && paint.maxY <= display.maxY
            && paint.minY >= contained.minY && paint.maxY <= contained.maxY
        let frame = Rect(x: constrainX ? contained.x : requested.x,
                         y: constrainY ? contained.y : requested.y,
                         width: constrainX ? contained.width : requested.width,
                         height: constrainY ? contained.height : requested.height)
        return frame.hasFinitePositiveEdges && frame.covers(paint) ? frame : requested
    }
    public static func drawingOrigin(window: Rect, display: Rect) -> Point {
        Point(x: display.minX - window.minX, y: window.maxY - display.maxY)
    }
    public static func scenePoint(global: Point, display: Rect) -> Point {
        Point(x: global.x - display.minX, y: display.maxY - global.y)
    }
}

private extension Rect {
    func covers(_ other: Rect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }
    var hasFinitePositiveEdges: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0 && minX.isFinite && minY.isFinite
            && maxX.isFinite && maxY.isFinite
    }
}
