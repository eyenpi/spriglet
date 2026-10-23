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
}

extension CompanionSnapshot {
    public var tuckedBoat: TuckedBoatPresentation? {
        guard scene.form == .fingertipGrip, phase == .hanging, presence == .peek, homeTuck == 1,
              let moment = idleMoment, moment.form == .fingertipGrip,
              moment.moment == .boat(.fiddle) else { return nil }
        return TuckedBoatPresentation(frame: moment)
    }
}
