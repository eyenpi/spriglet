import Foundation

/// The vector artwork and its transforms are shared by drawing and picking.
/// All coordinates are scene points; decorative shadows are excluded.
public struct CharacterTransform: Sendable {
    public let origin: Point
    public let rotation: Double
    public let scaleX: Double
    public let scaleY: Double
    public init(origin: Point, rotation: Double, scaleX: Double, scaleY: Double) {
        self.origin = origin; self.rotation = rotation; self.scaleX = scaleX; self.scaleY = scaleY
    }
    public func apply(_ point: Point) -> Point {
        let x = point.x * scaleX, y = point.y * scaleY
        return origin + Point(x: x * cos(rotation) - y * sin(rotation), y: x * sin(rotation) + y * cos(rotation))
    }
    func inverse(_ point: Point) -> Point {
        let p = point - origin
        return Point(x: (p.x * cos(rotation) + p.y * sin(rotation)) / scaleX,
                     y: (-p.x * sin(rotation) + p.y * cos(rotation)) / scaleY)
    }
}

public struct CharacterCurve: Sendable {
    public let start: Point
    public let control1: Point
    public let control2: Point
    public let end: Point
    public func point(at t: Double) -> Point {
        let u = 1 - t
        return start * (u * u * u) + control1 * (3 * u * u * t) + control2 * (3 * u * t * t) + end * (t * t * t)
    }
    fileprivate var outline: [Point] { (0...24).map { point(at: Double($0) / 24) } }
}

public struct CharacterHand: Sendable {
    public let arm: CharacterCurve
    public let palm: Rect
}

public struct MallowGeometry: Sendable {
    public static let bodyCurves: [CharacterCurve] = [
        CharacterCurve(start: Point(x: -49, y: 0), control1: Point(x: -66, y: -1), control2: Point(x: -66, y: -16), end: Point(x: -61, y: -31)),
        CharacterCurve(start: Point(x: -61, y: -31), control1: Point(x: -57, y: -56), control2: Point(x: -42, y: -76), end: Point(x: -22, y: -77)),
        CharacterCurve(start: Point(x: -22, y: -77), control1: Point(x: -4, y: -89), control2: Point(x: 16, y: -85), end: Point(x: 29, y: -74)),
        CharacterCurve(start: Point(x: 29, y: -74), control1: Point(x: 46, y: -65), control2: Point(x: 58, y: -48), end: Point(x: 60, y: -30)),
        CharacterCurve(start: Point(x: 60, y: -30), control1: Point(x: 67, y: -12), control2: Point(x: 64, y: -1), end: Point(x: 49, y: 0)),
        CharacterCurve(start: Point(x: 49, y: 0), control1: Point(x: 23, y: 5), control2: Point(x: -23, y: 5), end: Point(x: -49, y: 0)),
    ]
    // Sub-point approximation of the immutable cubic outline, sampled once.
    private static let bodyOutline = bodyCurves.flatMap { $0.outline.dropLast() }
    private static let bodyStroke = bodyOutline + [bodyOutline[0]]
    private static let bodyBounds = boundingRect(bodyOutline, padding: 1.15)
    public let root: CharacterTransform
    public let body: CharacterTransform
    public let feet: [Rect]
    public let hands: [CharacterHand]
    private let scale: Double

    public static func bodyTransform(for pose: CharacterPose) -> CharacterTransform {
        CharacterTransform(origin: Point(x: pose.lean * 26, y: 0), rotation: pose.lean,
                           scaleX: pose.width * (1 - abs(pose.facing) * 0.07), scaleY: pose.height)
    }
    public static func feet(for pose: CharacterPose) -> [Rect] {
        [-1.0, 1.0].map { side in
            let phase = (pose.gaitPhase + (side < 0 ? 0.5 : 0)).truncatingRemainder(dividingBy: 1)
            let swing = max(0, (phase - 0.6) / 0.4)
            let step = phase < 0.6 ? 11 - phase / 0.6 * 22 : -11 + (1 - cos(swing * .pi)) * 11
            let x = side * (28 - abs(pose.facing) * 9) + step * pose.walk * pose.direction
            return Rect(x: x - 10, y: -sin(swing * .pi) * 10 * pose.walk - 5, width: 20, height: 13)
        }
    }
    public init(_ frame: CompanionSnapshot) {
        let s = frame.scene.scale, pose = frame.pose, grip = frame.homeGrip
        scale = s
        let root = CharacterTransform(origin: frame.feet - Point(x: 0, y: 7 * s), rotation: frame.rotation, scaleX: s, scaleY: s)
        let body = Self.bodyTransform(for: pose)
        self.root = root; self.body = body; feet = Self.feet(for: pose)
        let reveal = clamp((frame.openness - 0.6) / 0.4, 0, 1)
        let emergence = reveal * reveal * (3 - 2 * reveal)
        func bodyPoint(_ x: Double, _ y: Double) -> Point { root.apply(body.apply(Point(x: x, y: y))) }
        func blend(_ free: Point, _ home: Point) -> Point { free + (home - free) * grip }
        hands = [-1.0, 1.0].map { side in
            let gait = sin(pose.gaitPhase * 2 * .pi + (side < 0 ? .pi : 0)) * pose.walk * 6
            let raise = pose.arm * (side > 0 ? 29 : 12) + gait
            let shoulder = bodyPoint(side * 47, -29)
            let wave = side > 0 ? max(0, pose.arm - 0.4) * 28 * emergence : 0
            let homeHand = Point(x: frame.homeAttachment.x + side * 43 * s,
                                 y: frame.homeAttachment.y + (-8 + emergence * 10 + wave) * s)
            let hand = blend(bodyPoint(side * 34, -15 - raise * 0.6), homeHand)
            return CharacterHand(arm: CharacterCurve(
                start: blend(bodyPoint(side * 47, -29 - raise), shoulder),
                control1: blend(bodyPoint(side * (56 + pose.arm * 6), -14 - raise), shoulder + Point(x: side * 8 * s, y: -9 * s)),
                control2: blend(bodyPoint(side * 46, -9 - raise * 0.5), homeHand + Point(x: side * 6 * s, y: 12 * s)), end: hand),
                palm: Rect(x: hand.x - 5 * s, y: hand.y - 3 * s, width: 10 * s, height: 8 * s))
        }
    }
    public func contains(_ point: Point) -> Bool {
        guard point.isFinite else { return false }
        let local = root.inverse(point), bodyPoint = body.inverse(local)
        if Self.bodyBounds.contains(bodyPoint),
           polygonContains(bodyPoint, Self.bodyOutline) || strokeContains(bodyPoint, Self.bodyStroke, radius: 1.15) { return true }
        if feet.contains(where: { ellipseContains(local, $0, outline: 0.95) }) { return true }
        return hands.contains { hand in
            if ellipseContains(point, hand.palm, outline: 0.95 * scale) { return true }
            let armBounds = boundingRect([hand.arm.start, hand.arm.control1, hand.arm.control2, hand.arm.end], padding: scale)
            return armBounds.contains(point) && strokeContains(point, hand.arm.outline, radius: scale)
        }
    }
    public var bounds: Rect {
        // Include the painted outlines after both body and scene transforms.
        let padding = 1.15 * max(abs(body.scaleX), abs(body.scaleY)) * scale
        let bodyBounds = boundingRect(Self.bodyOutline.map { root.apply(body.apply($0)) }, padding: padding)
        let footBounds = feet.map { boundingRect(corners($0).map(root.apply), padding: 0.95 * scale) }
        let handBounds = hands.flatMap { [boundingRect([$0.arm.start, $0.arm.control1, $0.arm.control2, $0.arm.end], padding: scale),
                                        boundingRect(corners($0.palm), padding: 0.95 * scale)] }
        return boundingRect(([bodyBounds] + footBounds + handBounds).flatMap(corners))
    }
}

private func ellipseContains(_ point: Point, _ rect: Rect, outline: Double) -> Bool {
    let x = (point.x - rect.midX) / (rect.width / 2 + outline)
    let y = (point.y - rect.midY) / (rect.height / 2 + outline)
    return x * x + y * y <= 1
}
private func polygonContains(_ point: Point, _ outline: [Point]) -> Bool {
    var inside = false, previous = outline.last!
    for next in outline {
        if (next.y > point.y) != (previous.y > point.y),
           point.x < (previous.x - next.x) * (point.y - next.y) / (previous.y - next.y) + next.x { inside.toggle() }
        previous = next
    }
    return inside
}
private func strokeContains(_ point: Point, _ outline: [Point], radius: Double) -> Bool {
    for (a, b) in zip(outline, outline.dropFirst()) {
        let delta = b - a, offset = point - a
        let lengthSquared = delta.x * delta.x + delta.y * delta.y
        let t = lengthSquared > 0 ? clamp((offset.x * delta.x + offset.y * delta.y) / lengthSquared, 0, 1) : 0
        if point.distance(to: a + delta * t) <= radius { return true }
    }
    return false
}
private func corners(_ rect: Rect) -> [Point] {
    [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
     Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
}
private func boundingRect(_ points: [Point], padding: Double = 0) -> Rect {
    let minX = points.map(\.x).min()! - padding, minY = points.map(\.y).min()! - padding
    return Rect(x: minX, y: minY, width: points.map(\.x).max()! + padding - minX, height: points.map(\.y).max()! + padding - minY)
}
