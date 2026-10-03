import Foundation

/// Scene coordinates use points, with the origin at the display's top-left.
public struct Point: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func distance(to other: Point) -> Double { hypot(x - other.x, y - other.y) }
    public static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    public static func * (lhs: Point, rhs: Double) -> Point { Point(x: lhs.x * rhs, y: lhs.y * rhs) }
}

public struct Rect: Equatable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Point { Point(x: midX, y: midY) }
    public var isValid: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0 }
    public func contains(_ point: Point) -> Bool {
        point.isFinite && point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}

func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(max(value, lower), upper) }
