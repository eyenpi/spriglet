import Foundation

enum Motion: CaseIterable, Sendable { case idle, walkLeft, walkRight, stretch, wave }

/// Authors pose targets and blink/gait timing. PoseDynamics owns blending;
/// selecting a motion never resets the presented pose or its velocity.
struct MotionAnimator: Sendable {
    private(set) var motion = Motion.idle
    private(set) var targetPose = CharacterPose()
    private var began = 0.0
    private var nextBlink = 2.3
    private var blinkBegan = -100.0
    private var blinkCount = 0
    mutating func select(_ motion: Motion, at time: Double) { self.motion = motion; began = time }
    mutating func advance(to time: Double, dt: Double, walkingAmount: Double) {
        let age = max(0, time - began)
        let breath = sin(time * 2.15)
        var target = CharacterPose()
        target.height = 1 + breath * 0.015
        target.lean = sin(time * 0.55) * 0.012
        if time >= nextBlink {
            blinkBegan = time; blinkCount += 1
            nextBlink = time + 3.1 + (sin(Double(blinkCount) * 2.399963) * 0.5 + 0.5) * 2.6
        }
        var blinkAge = time - blinkBegan
        if blinkCount % 4 == 0 && blinkAge >= 0.32 { blinkAge -= 0.32 }
        if blinkAge >= 0 && blinkAge < 0.23 {
            target.eyes = blinkAge < 0.06 ? 1 - blinkAge / 0.06 : blinkAge < 0.14 ? 0 : (blinkAge - 0.14) / 0.09
        }
        switch motion {
        case .idle: target.look = sin(time * 0.42) * 1.3
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
            target.arm = 0.7 + sin(age * 7) * 0.22; target.lean = -0.035; target.sparkle = 0.3
        }
        target.width = 1 / target.height
        target.gaitPhase = targetPose.gaitPhase
        if walkingAmount > 0.005 {
            target.gaitPhase = (target.gaitPhase + dt / SimulationTuning.walkingStride).truncatingRemainder(dividingBy: 1)
        }
        targetPose = target
    }
}
