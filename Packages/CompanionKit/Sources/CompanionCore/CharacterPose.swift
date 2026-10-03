import Foundation

public struct CharacterPose: Equatable, Sendable {
    public var width = 1.0, height = 1.0, lean = 0.0
    public var look = 0.0, eyes = 1.0, arm = 0.0, walk = 0.0, direction = 1.0
    public var sparkle = 0.0
    public var facing = 0.0, lookY = 0.0
    public var gaitPhase = 0.0
    public init() {}
    mutating func approach(_ p: CharacterPose, dt: Double) {
        let a = 1 - exp(-dt * 9)
        width += (p.width - width) * a; height += (p.height - height) * a
        lean += (p.lean - lean) * a
        look += (p.look - look) * a; eyes += (p.eyes - eyes) * (1 - exp(-dt * 28))
        arm += (p.arm - arm) * a; walk += (p.walk - walk) * a
        direction += (p.direction - direction) * a
        sparkle += (p.sparkle - sparkle) * a
        facing += (p.facing - facing) * (1 - exp(-dt * 5))
        lookY += (p.lookY - lookY) * a
    }
}
