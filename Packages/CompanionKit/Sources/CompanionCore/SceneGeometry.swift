/// macOS supplies measurements; the simulation never queries a display itself.
public struct SceneGeometry: Equatable, Sendable {
    public let bounds: Rect
    public let home: Rect
    public let floor: Double
    public let scale: Double
    public let hasHardwareNotch: Bool
    /// Hide artwork behind Home all the way to the display's top edge. A
    /// synthetic Home may start below that edge to sit beneath the menu bar;
    /// its attachment geometry must not leave a visible strip above it.
    public var homeOcclusion: Rect {
        let top = min(bounds.minY, home.minY)
        return Rect(x: home.x, y: top, width: home.width, height: home.maxY - top)
    }
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
    /// A persistent input window and independent, display-contained paint
    /// canvases. The input rectangle and paint envelope are independent, so
    /// presentation ownership never switches with pointer ownership.
    public static func desktopLayout(requested: Rect, paint: Rect, activeDisplay: Rect,
                                     displays: [Rect]) -> DesktopWindowLayout? {
        guard requested.hasFinitePositiveEdges, activeDisplay.hasFinitePositiveEdges,
              paint.hasFinitePositiveEdges else { return nil }
        var frames: [DisplayWindowFrame] = []
        for display in [activeDisplay] + displays where display.hasFinitePositiveEdges {
            guard !frames.contains(where: { $0.display == display }) else { continue }
            let left = max(paint.minX, display.minX), right = min(paint.maxX, display.maxX)
            let bottom = max(paint.minY, display.minY), top = min(paint.maxY, display.maxY)
            guard right > left && top > bottom else { continue }
            // Round outward to whole logical points so native pixel alignment
            // cannot trim a fractional tile edge. Never extend onto a neighbor.
            let x = max(left.rounded(.down), display.minX), y = max(bottom.rounded(.down), display.minY)
            let frame = Rect(x: x, y: y, width: min(right.rounded(.up), display.maxX) - x,
                             height: min(top.rounded(.up), display.maxY) - y)
            if frame.hasFinitePositiveEdges { frames.append(DisplayWindowFrame(display: display, frame: frame)) }
        }
        return DesktopWindowLayout(inputFrame: containedFrame(requested, in: activeDisplay), canvases: frames)
    }
    public static func drawingOrigin(window: Rect, display: Rect) -> Point {
        Point(x: display.minX - window.minX, y: window.maxY - display.maxY)
    }
    public static func scenePoint(global: Point, display: Rect) -> Point {
        Point(x: global.x - display.minX, y: display.maxY - global.y)
    }
}

public struct DisplayWindowFrame: Equatable, Sendable {
    public let display: Rect
    public let frame: Rect
    public init(display: Rect, frame: Rect) { self.display = display; self.frame = frame }
}

public struct DesktopWindowLayout: Equatable, Sendable {
    public let inputFrame: Rect
    public let canvases: [DisplayWindowFrame]
    public init(inputFrame: Rect, canvases: [DisplayWindowFrame]) { self.inputFrame = inputFrame; self.canvases = canvases }
}

private extension Rect {
    var hasFinitePositiveEdges: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0 && minX.isFinite && minY.isFinite
            && maxX.isFinite && maxY.isFinite
    }
}
