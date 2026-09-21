import SprigletCore

/// Resolves semantic conversation reactions to existing authored content,
/// only when the pet may visibly act.
public enum GesturePolicy {
    /// Waking is the only reaction to attention; an awake pet simply holds still.
    public static func attentionCommand(in world: PetWorldSnapshot) -> PetSceneCommand? {
        guard mayReact(in: world), world.isSleeping else { return nil }
        return .action(.wakeUp)
    }

    public static func command(for gesture: CompanionGesture, in world: PetWorldSnapshot) -> PetSceneCommand? {
        guard mayReact(in: world), !world.isSleeping else { return nil }
        return switch gesture {
        case .none: nil
        case .attentive, .curious: .routine(.observe)
        case .cheerful: .routine(.greet)
        }
    }

    private static func mayReact(in world: PetWorldSnapshot) -> Bool {
        !world.isSuspended
            && !world.isReduceMotion
            && !world.isInteracting
            && world.isOnActiveSpace
            && !world.isMoving
    }
}
