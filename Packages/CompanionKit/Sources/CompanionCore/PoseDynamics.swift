import Foundation

/// Carries the velocity of silhouette and limb changes across new pose targets.
/// Width is derived from height so blending cannot inflate or deflate the body.
struct PoseDynamics: Sendable {
    private(set) var pose = CharacterPose()
    private var height = Spring(value: 1, frequency: 14, damping: 0.9)
    private var lean = Spring(frequency: 14, damping: 0.9)
    private var arm = Spring(frequency: 14, damping: 0.9)

    mutating func step(toward target: CharacterPose, dt: Double) {
        height.step(dt, target: target.height)
        lean.step(dt, target: target.lean)
        arm.step(dt, target: target.arm)
        let blend = 1 - exp(-dt * 9)
        pose.look += (target.look - pose.look) * blend
        pose.lookY += (target.lookY - pose.lookY) * blend
        pose.walk += (target.walk - pose.walk) * blend
        pose.direction += (target.direction - pose.direction) * blend
        pose.facing += (target.facing - pose.facing) * (1 - exp(-dt * 5))
        pose.eyes += (target.eyes - pose.eyes) * (1 - exp(-dt * 28))
        pose.height = height.value
        pose.width = 1 / pose.height
        pose.lean = lean.value
        pose.arm = arm.value
        pose.gaitPhase = target.gaitPhase
    }
}
