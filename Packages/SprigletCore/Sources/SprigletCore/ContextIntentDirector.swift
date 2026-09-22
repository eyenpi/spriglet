/// Pure arbitration for generic context facts. Platform sources report facts;
/// this director decides whether they are meaningful in the current world.
public enum ContextualBehaviorIntent: Equatable, Sendable {
    case wake
    case nap
    case appGlance
}

public enum ContextIntentDirector {
    public static func intent(
        for fact: UserActivityContextFact,
        in world: PetWorldSnapshot,
        automaticMomentsEnabled: Bool
    ) -> ContextualBehaviorIntent? {
        guard !world.isSuspended, world.isOnActiveSpace,
              !world.isInteracting, !world.isAnimating, !world.isMoving else { return nil }
        switch fact.kind {
        case .wakeRequested:
            return world.isSleeping ? .wake : nil
        case .napEligible:
            return automaticMomentsEnabled && !world.isSleeping ? .nap : nil
        case .appGlance:
            return automaticMomentsEnabled && !world.isSleeping ? .appGlance : nil
        }
    }
}
