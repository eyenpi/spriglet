/// Produces calm, deterministic suggestions without owning clocks or persistence.
///
/// The app schedules each suggestion only while its activity policy permits it.
/// Passing `isSleeping` describes the renderer's settled state, not a pending
/// action. The planner never chooses the user-initiated `react` action.
public struct PetBehaviorPlanner: Sendable {
    private var random: SplitMix64
    private var previousAction: PetAction?
    private var interactionCooldown = false

    public init(seed: UInt64) {
        random = SplitMix64(state: seed)
    }

    /// Awake suggestions wait 20–75 seconds; a sleeping pet wakes in 60–180.
    /// Repeated non-blink awake choices become a blink to avoid a visible loop.
    public mutating func next(isSleeping: Bool) -> PlannedBehavior {
        if isSleeping {
            previousAction = .wakeUp
            return PlannedBehavior(action: .wakeUp, delaySeconds: delay(in: 60...180))
        }

        if interactionCooldown {
            interactionCooldown = false
            previousAction = .blink
            return PlannedBehavior(action: .blink, delaySeconds: delay(in: 45...75))
        }

        let selection = random.next() % 100
        var action: PetAction
        switch selection {
        case 0..<60: action = .blink
        case 60..<90: action = .lookAround
        case 90..<98: action = .stretch
        default: action = .fallAsleep
        }
        if action != .blink, action == previousAction {
            action = .blink
        }
        previousAction = action
        return PlannedBehavior(action: action, delaySeconds: delay(in: 20...75))
    }

    /// Gives the next awake suggestion a quiet 45–75-second pause and a blink.
    ///
    /// This does not wake a sleeping pet, rewind the random sequence, or cancel
    /// a task already owned by the app. A sleeping wake suggestion preserves the
    /// cooldown for the next awake suggestion. Repeated calls are idempotent.
    public mutating func resetAfterInteraction() {
        interactionCooldown = true
    }

    private mutating func delay(in range: ClosedRange<UInt64>) -> Double {
        Double(range.lowerBound + random.next() % (range.upperBound - range.lowerBound + 1))
    }
}

/// Deterministic integer sequence; a zero seed is valid.
/// Adapted from Sebastiano Vigna's public-domain SplitMix64 reference:
/// https://prng.di.unimi.it/splitmix64.c
private struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
