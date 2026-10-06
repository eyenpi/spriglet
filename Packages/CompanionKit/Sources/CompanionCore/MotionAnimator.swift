import Foundation

enum Motion: CaseIterable, Sendable { case idle, walkLeft, walkRight, stretch, wave }

/// Authors deliberate gestures and gait over the natural idle pose.
/// PoseDynamics owns blending; selecting a motion never resets the presented
/// pose or its velocity.
struct MotionAnimator: Sendable {
    private(set) var motion = Motion.idle
    private(set) var targetPose = CharacterPose()
    private var began = 0.0
    mutating func select(_ motion: Motion, at time: Double) { self.motion = motion; began = time }
    mutating func advance(to time: Double, dt: Double, walkingAmount: Double, idlePose: CharacterPose) {
        let age = max(0, time - began)
        var target = idlePose
        switch motion {
        case .idle: break
        case .walkLeft, .walkRight:
            let direction = motion == .walkLeft ? -1.0 : 1.0
            target.walk = 1; target.direction = direction; target.look = direction * 2
            target.facing = direction; target.lean = direction * 0.06
            let step = sin(targetPose.gaitPhase * 4 * .pi)
            target.height = 1 + step * 0.018
        case .stretch:
            let reach = pow(max(0, sin(min(age / 3.4, 1) * .pi)), 0.65)
            target.height = 1 + reach * 0.23
            target.arm = reach; target.eyes *= 1 - reach * 0.70
        case .wave:
            target.arm = 0.7 + sin(age * 7) * 0.22; target.lean = -0.035
        }
        target.width = 1 / target.height
        target.gaitPhase = targetPose.gaitPhase
        if walkingAmount > 0.005 {
            target.gaitPhase = (target.gaitPhase + dt / SimulationTuning.walkingStride).truncatingRemainder(dividingBy: 1)
        }
        targetPose = target
    }
}
