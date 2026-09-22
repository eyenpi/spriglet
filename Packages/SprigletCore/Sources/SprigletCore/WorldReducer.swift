/// Pure reduction of environment stimuli into a coherent world snapshot.
public enum WorldReducer {
    /// Applies one stimulus. Strictly older observations are ignored in full so
    /// a delayed source cannot roll back either time or facts. Equal timestamps
    /// are applied in delivery order, making replay deterministic.
    public static func reduce(
        _ snapshot: PetWorldSnapshot,
        _ stimulus: PetStimulus
    ) -> PetWorldSnapshot {
        guard stimulus.timestamp >= snapshot.timestamp else { return snapshot }

        var activityPolicy = snapshot.activityPolicy
        var isSleeping = snapshot.isSleeping
        var canWander = snapshot.canWander
        var isLowPower = snapshot.isLowPower
        var isReduceMotion = snapshot.isReduceMotion
        var isOnActiveSpace = snapshot.isOnActiveSpace
        var isInteracting = snapshot.isInteracting
        var isAnimating = snapshot.isAnimating
        var isMoving = snapshot.isMoving
        var activityLevel = snapshot.activityLevel
        var petBounds = snapshot.petBounds
        var pointer = snapshot.pointer
        var attention = snapshot.attention

        switch stimulus.event {
        case let .suspension(reason, active):
            activityPolicy.set(reason, active: active)
            if active { pointer = .empty; attention = .neutral }
        case let .sleeping(value):
            isSleeping = value
            if value { pointer = .empty; attention = .neutral }
        case let .wanderingAvailability(value):
            canWander = value
        case let .lowPower(value):
            isLowPower = value
        case let .reduceMotion(value):
            isReduceMotion = value
        case let .activeSpace(value):
            isOnActiveSpace = value
        case let .interaction(value):
            isInteracting = value
            if value { pointer = .empty; attention = .neutral }
        case let .animating(value):
            isAnimating = value
        case let .moving(value):
            isMoving = value
        case let .activityLevel(value):
            activityLevel = value
        case let .petBounds(value):
            petBounds = value.flatMap { bounds in
                guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite,
                      bounds.width > 0, bounds.height > 0 else { return nil }
                return bounds
            }
        case let .pointer(perception, value):
            if activityPolicy.allowsAnimation, !isSleeping, !isInteracting {
                pointer = perception
                attention = value
            } else {
                pointer = .empty
                attention = .neutral
            }
        }

        return PetWorldSnapshot(
            timestamp: stimulus.timestamp,
            activityPolicy: activityPolicy,
            isSleeping: isSleeping,
            canWander: canWander,
            isLowPower: isLowPower,
            isReduceMotion: isReduceMotion,
            isOnActiveSpace: isOnActiveSpace,
            isInteracting: isInteracting,
            isAnimating: isAnimating,
            isMoving: isMoving,
            activityLevel: activityLevel,
            petBounds: petBounds,
            pointer: pointer,
            attention: attention
        )
    }

    public static func replay<S: Sequence>(
        initial: PetWorldSnapshot = PetWorldSnapshot(),
        stimuli: S
    ) -> PetWorldSnapshot where S.Element == PetStimulus {
        stimuli.reduce(initial, reduce)
    }
}
