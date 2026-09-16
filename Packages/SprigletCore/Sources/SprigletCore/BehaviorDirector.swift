import Foundation

/// Selects the next scheduled intent from an immutable view of the world.
/// Directors own no timer; the caller controls scheduling and eligibility.
public protocol BehaviorDirector: Sendable {
    mutating func next(
        in world: PetWorldSnapshot,
        profile: PetProfile,
        memory: PetInteractionMemory,
        now: Date
    ) -> PlannedBehavior

    /// Execution feedback is separate from a suggestion so cancellation never
    /// consumes repetition or movement-cooldown state.
    mutating func didPerform(_ intent: PetBehaviorIntent, at now: Date)

    /// Preserves the existing post-interaction quiet-observation behavior.
    mutating func resetAfterInteraction()
}

/// Places the current deterministic planner behind the behavior boundary without
/// changing its selection, delay, cooldown, or feedback semantics.
public struct LegacyBehaviorDirector: BehaviorDirector {
    private var planner: PetBehaviorPlanner

    public init(seed: UInt64) {
        planner = PetBehaviorPlanner(seed: seed)
    }

    public init(planner: PetBehaviorPlanner) {
        self.planner = planner
    }

    public mutating func next(
        in world: PetWorldSnapshot,
        profile: PetProfile = PetProfile(),
        memory: PetInteractionMemory = PetInteractionMemory(),
        now: Date = .now
    ) -> PlannedBehavior {
        planner.next(
            isSleeping: world.isSleeping,
            profile: profile,
            memory: memory,
            now: now,
            canWander: world.canWander,
            lowPower: world.isLowPower,
            activityLevel: world.activityLevel
        )
    }

    public mutating func didPerform(
        _ intent: PetBehaviorIntent,
        at now: Date = .now
    ) {
        planner.didPerform(intent, at: now)
    }

    public mutating func resetAfterInteraction() {
        planner.resetAfterInteraction()
    }
}
