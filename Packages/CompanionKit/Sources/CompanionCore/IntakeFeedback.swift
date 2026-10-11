import Foundation

public enum IntakeFeedback: String, Sendable {
    case ready, caught, analyzing, uncertain, happy
    public var label: String {
        switch self {
        case .ready: "Ready to catch a reminder"
        case .caught: "Caught your item"
        case .analyzing: "Reading your item on this Mac"
        case .uncertain: "Unsure what to remind you about"
        case .happy: "Reminder added"
        }
    }
}
extension CompanionSnapshot {
    /// Intake presentation is orthogonal to play physics and uses the runtime's clock.
    public func presentingIntake(_ feedback: IntakeFeedback?, age: Double, reducedMotion: Bool, pocketCount: Int) -> CompanionSnapshot {
        var pose = pose, feet = feet
        if let feedback {
            pose.look = 0; pose.lookY += 5
            if !reducedMotion {
                switch feedback {
                case .ready: pose.arm = 0.95; pose.eyes = 1.12; feet.y += 12 * scene.scale
                case .caught:
                    let catchAmount = max(0, 1 - age / 0.3)
                    pose.height *= 1 - 0.15 * catchAmount; feet.y += 12 * scene.scale * catchAmount
                case .analyzing: pose.height *= 1 + sin(age * 12) * 0.025; pose.eyes *= 0.85
                case .uncertain: pose.arm = 0.55; pose.lean = 0.06
                case .happy: feet.y -= max(0, sin(min(age / 0.7, 1) * .pi)) * 12 * scene.scale; pose.arm = 0.8
                }
                pose.width = 1 / pose.height
            }
        }
        return CompanionSnapshot(scene: scene, presence: presence, phase: phase, pose: pose, feet: feet,
            windowAnchor: windowAnchor, rotation: rotation, openness: openness, homeGrip: feedback == .ready ? 0 : homeGrip,
            homeAttachment: homeAttachment, dragGeometry: dragGeometry, time: time, gesture: gesture,
            canCatch: canCatch, idleMoment: feedback == nil ? idleMoment : nil, intakeFeedback: feedback, pocketCount: pocketCount)
    }
}
