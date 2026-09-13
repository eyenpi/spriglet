/// Independent reasons the app must stop scheduling character animation.
public enum SuspensionReason: String, CaseIterable, Sendable {
    case userPaused
    case hidden
    case occluded
    case systemAsleep
    case displayAsleep
    case sessionInactive
    case thermalPressure
}

/// Combines suspension causes without letting one resume event override another.
///
/// This value determines eligibility only. It owns no timers, starts no work, and
/// does not request a new animation when the last suspension reason is removed.
/// The renderer decides whether an existing, explicit animation should continue.
public struct ActivityPolicy: Equatable, Sendable {
    public private(set) var reasons: Set<SuspensionReason>

    public init(reasons: Set<SuspensionReason> = []) {
        self.reasons = reasons
    }

    public var allowsAnimation: Bool {
        reasons.isEmpty
    }

    /// Applies one cause; repeated notifications are intentionally idempotent.
    public mutating func set(_ reason: SuspensionReason, active: Bool) {
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
    }
}
