import Foundation

public enum DesktopDragCoordinates {
    /// AppKit's global bottom-left points to destination scene top-left points.
    public static func globalToLocal(_ point: Point, display: Rect) -> Point {
        Point(x: point.x - display.minX, y: display.maxY - point.y)
    }
    /// Translation that preserves a character's global position across scenes.
    public static func translation(from oldFrame: Rect, to newFrame: Rect) -> Point {
        Point(x: oldFrame.minX - newFrame.minX, y: newFrame.maxY - oldFrame.maxY)
    }
}

/// A display's drawable rectangle and the home housing that occludes it.
public struct DragSurface: Equatable, Sendable {
    public let bounds: Rect
    public let housing: Rect
    public init(bounds: Rect, housing: Rect) {
        self.bounds = bounds; self.housing = housing
    }
    public var isValid: Bool {
        bounds.isValid && bounds.width > 0 && bounds.height > 0
            && bounds.maxX.isFinite && bounds.maxY.isFinite && housing.isValid
            && housing.maxX.isFinite && housing.maxY.isFinite
    }
}

/// Shared clipping, picking and held-body limits while the pointer crosses displays.
public struct DragGeometry: Equatable, Sendable {
    public let surfaces: [DragSurface]
    public let heldBounds: Rect
    public init(surfaces: [DragSurface], heldBounds: Rect) {
        self.surfaces = surfaces; self.heldBounds = heldBounds
    }
    public var isValid: Bool {
        !surfaces.isEmpty && surfaces.allSatisfy(\.isValid)
            && heldBounds.isValid && heldBounds.width > 0 && heldBounds.height > 0
            && heldBounds.maxX.isFinite && heldBounds.maxY.isFinite
    }
    public func translated(by delta: Point) -> DragGeometry {
        DragGeometry(surfaces: surfaces.map {
            DragSurface(bounds: Rect(x: $0.bounds.x + delta.x, y: $0.bounds.y + delta.y,
                                     width: $0.bounds.width, height: $0.bounds.height),
                        housing: Rect(x: $0.housing.x + delta.x, y: $0.housing.y + delta.y,
                                      width: $0.housing.width, height: $0.housing.height))
        }, heldBounds: Rect(x: heldBounds.x + delta.x, y: heldBounds.y + delta.y,
                            width: heldBounds.width, height: heldBounds.height))
    }
    /// Nonoverlapping tiling of display-surface union minus housing union.
    public var visibleRectangles: [Rect] {
        guard isValid else { return [] }
        let xs = Set(surfaces.flatMap { [$0.bounds.minX, $0.bounds.maxX, $0.housing.minX, $0.housing.maxX] }).sorted()
        guard xs.count > 1 else { return [] }
        var output: [Rect] = []
        for (left, right) in zip(xs, xs.dropFirst()) where right > left {
            let mid = left + (right - left) / 2
            let outer = merge(surfaces.filter { mid >= $0.bounds.minX && mid < $0.bounds.maxX }
                .map { ($0.bounds.minY, $0.bounds.maxY) })
            let holes = merge(surfaces.filter { mid >= $0.housing.minX && mid < $0.housing.maxX }
                .map { (max($0.bounds.minY, $0.housing.minY), min($0.bounds.maxY, $0.housing.maxY)) }
                .filter { $0.1 > $0.0 })
            for interval in subtract(holes, from: outer) where interval.1 > interval.0 {
                output.append(Rect(x: left, y: interval.0, width: right - left, height: interval.1 - interval.0))
            }
        }
        return output
    }
}

private func merge(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
    let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
    var result: [(Double, Double)] = []
    for interval in sorted {
        if let last = result.last, interval.0 <= last.1 {
            result[result.count - 1] = (last.0, max(last.1, interval.1))
        } else { result.append(interval) }
    }
    return result
}

private func subtract(_ holes: [(Double, Double)], from outer: [(Double, Double)]) -> [(Double, Double)] {
    var result: [(Double, Double)] = []
    for interval in outer {
        var pieces = [interval]
        for hole in holes {
            pieces = pieces.flatMap { piece -> [(Double, Double)] in
                guard hole.0 < piece.1 && hole.1 > piece.0 else { return [piece] }
                var remainder: [(Double, Double)] = []
                if hole.0 > piece.0 { remainder.append((piece.0, hole.0)) }
                if hole.1 < piece.1 { remainder.append((hole.1, piece.1)) }
                return remainder
            }
        }
        result.append(contentsOf: pieces)
    }
    return result
}
