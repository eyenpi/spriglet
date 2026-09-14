import Foundation

/// Deterministic intentions with explicit execution feedback; this owns no timer.
public struct PetBehaviorPlanner: Sendable {
    public static let movementCooldownSeconds: TimeInterval = 180

    private var random: SplitMix64
    private var previousPerformedIntent: PetBehaviorIntent?
    private var lastExploreAt: Date?
    private var interactionQuietPending = false

    public init(seed: UInt64) {
        random = SplitMix64(state: seed)
    }

    /// Suggestions never update executed history. The caller must recheck its
    /// activity policy and available room when a scheduled intention actually runs.
    public mutating func next(
        isSleeping: Bool,
        profile: PetProfile = PetProfile(),
        memory: PetInteractionMemory = PetInteractionMemory(),
        now: Date = .now,
        canWander: Bool = false,
        lowPower: Bool = false,
        activityLevel: PetActivityLevel = .balanced
    ) -> PlannedBehavior {
        let recent = memory.values(at: now)
        if isSleeping {
            return planned(.wake, range: 180...420, quiet: recent.quietSecondsRemaining, lowPower: lowPower, activityLevel: activityLevel)
        }
        if interactionQuietPending {
            return planned(.observe, range: 90...180, quiet: max(90, recent.quietSecondsRemaining), lowPower: lowPower, activityLevel: activityLevel)
        }

        let traits = profile.traits
        let canExplore = canWander && !lowPower && movementCooldownHasElapsed(at: now)
        var weights: [(PetBehaviorIntent, Int)] = [
            (.observe, 50 + Int((1 - traits.playfulness) * 15) + Int(recent.relocation * 10) + (lowPower ? 20 : 0)),
            (.greet, 14 + Int(traits.sociability * 12) + Int(recent.affection * 8)),
            (.explore, canExplore ? 6 + Int(traits.curiosity * 12) + Int(traits.playfulness * 4) - Int(recent.relocation * 6) : 0),
            (.nap, 3 + Int((1 - traits.playfulness) * 4) + Int(recent.play * 6) + (lowPower ? 4 : 0))
        ]
        for index in weights.indices where weights[index].0 != .observe && weights[index].0 == previousPerformedIntent {
            weights[index].1 = 0
        }
        var ticket = Int(random.next() % UInt64(weights.reduce(0) { $0 + $1.1 }))
        var intent: PetBehaviorIntent = .observe
        for (candidate, weight) in weights {
            if ticket < weight { intent = candidate; break }
            ticket -= weight
        }
        let range: ClosedRange<UInt64> = switch intent {
        case .observe: 90...240
        case .greet: 60...180
        case .explore: 180...360
        case .nap: 240...480
        case .wake: 180...420
        }
        return planned(intent, range: range, quiet: recent.quietSecondsRemaining, lowPower: lowPower, activityLevel: activityLevel)
    }

    /// Call only after the runtime accepts a routine, never merely when scheduled.
    public mutating func didPerform(_ intent: PetBehaviorIntent, at now: Date = .now) {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return }
        previousPerformedIntent = intent
        if intent == .explore { lastExploreAt = now }
        if intent != .wake { interactionQuietPending = false }
    }

    /// Compatibility for existing runtime callers. Cancellation does not consume
    /// this quiet observation; a performed awake intention clears it.
    public mutating func resetAfterInteraction() {
        interactionQuietPending = true
    }

    private mutating func movementCooldownHasElapsed(at now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let lastExploreAt else { return true }
        let elapsed = now.timeIntervalSince(lastExploreAt)
        if !elapsed.isFinite || elapsed < 0 {
            // A backwards clock restarts one bounded cooldown instead of leaving
            // a far-future timestamp that suppresses movement indefinitely.
            self.lastExploreAt = now
            return false
        }
        return elapsed >= Self.movementCooldownSeconds
    }

    private mutating func planned(
        _ intent: PetBehaviorIntent, range: ClosedRange<UInt64>, quiet: Double, lowPower: Bool,
        activityLevel: PetActivityLevel
    ) -> PlannedBehavior {
        let lower = max(range.lowerBound, UInt64(ceil(quiet)))
        let upper = max(lower, range.upperBound)
        let delay = lower + random.next() % (upper - lower + 1)
        let normalDelay = min(480, Double(delay) + (lowPower ? 60 : 0))
        let adjusted = min(720, max(60, quiet, normalDelay * activityLevel.delayMultiplier))
        return PlannedBehavior(intent: intent, delaySeconds: adjusted)
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
