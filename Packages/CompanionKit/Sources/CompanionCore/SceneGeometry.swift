/// macOS supplies measurements; the simulation never queries a display itself.
public struct SceneGeometry: Equatable, Sendable {
    public let bounds: Rect
    public let home: Rect
    public let floor: Double
    public let scale: Double
    public let hasHardwareNotch: Bool
    public var homeFeet: Point { Point(x: home.midX, y: home.maxY + 60 * scale) }
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
    public static func desiredOrigin(feet: Point, display: Rect) -> Point {
        Point(x: display.minX + feet.x - width / 2,
              y: display.maxY - feet.y - (height - feetOffset))
    }
    public static func drawingOrigin(window: Rect, display: Rect) -> Point {
        Point(x: display.minX - window.minX, y: window.maxY - display.maxY)
    }
    public static func scenePoint(global: Point, display: Rect) -> Point {
        Point(x: global.x - display.minX, y: display.maxY - global.y)
    }
}
