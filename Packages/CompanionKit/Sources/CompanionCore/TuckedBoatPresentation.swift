import Foundation

/// One seven-second hand gesture, anchored to Home while the body stays tucked.
public struct TuckedBoatPresentation: Sendable {
    public let boat: BoatPresentation
    public let extensionAmount: Double

    init(frame: IdleMomentFrame) {
        let age = frame.progress * frame.duration
        let t = clamp(min(age / 1.5, (frame.duration - age) / 2), 0, 1)
        extensionAmount = t * t * (3 - 2 * t)
        let adjustment = clamp((age - 1.5) / 3, 0, 1)
        boat = BoatPresentation(center: Point(x: 0, y: -12 + 22 * extensionAmount),
                                rotation: sin(adjustment * 2 * .pi) * 0.07 * frame.movementAmount,
                                opacity: 1)
    }
    public var transform: CharacterTransform {
        CharacterTransform(origin: boat.center, rotation: boat.rotation, scaleX: 1, scaleY: 1)
    }
    var handOffsets: TuckedHandOffsets {
        func offset(_ side: Double) -> Point {
            (transform.apply(Point(x: side * 15, y: 1)) - Point(x: side * 18, y: -1.5)) * extensionAmount
        }
        return TuckedHandOffsets(left: offset(-1), right: offset(1))
    }
}

/// Home-relative offsets from the resting palm caps, before scene scaling.
public struct TuckedHandOffsets: Sendable {
    public let left: Point
    public let right: Point
    public static let zero = Self(left: .zero, right: .zero)
}

/// Follow the authored grip exactly, then retain its position and velocity when
/// the habit ends. These springs share the engine's normal simulation step.
struct TuckedHandDynamics: Sendable {
    private struct Hand: Sendable {
        var x = Spring(frequency: 18, damping: 1)
        var y = Spring(frequency: 18, damping: 1)
        var offset: Point { Point(x: x.value, y: y.value) }
        mutating func step(_ dt: Double, target: Point?) {
            if let target {
                x.speed = (target.x - x.value) / dt; x.value = target.x
                y.speed = (target.y - y.value) / dt; y.value = target.y
            } else { x.step(dt); y.step(dt) }
        }
    }
    private var left = Hand(), right = Hand()
    var offsets: TuckedHandOffsets { TuckedHandOffsets(left: left.offset, right: right.offset) }
    mutating func step(_ dt: Double, target: TuckedHandOffsets?) {
        left.step(dt, target: target?.left); right.step(dt, target: target?.right)
    }
}

extension CompanionSnapshot {
    public var tuckedHandOffsets: TuckedHandOffsets { tuckedBoat?.handOffsets ?? returningHandOffsets }
    public var tuckedBoat: TuckedBoatPresentation? {
        guard scene.form == .fingertipGrip, phase == .hanging, presence == .peek, homeTuck == 1,
              let moment = idleMoment, moment.form == .fingertipGrip,
              moment.moment == .boat(.fiddle) else { return nil }
        return TuckedBoatPresentation(frame: moment)
    }
}
