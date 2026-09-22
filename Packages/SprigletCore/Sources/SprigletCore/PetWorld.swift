import Foundation

/// Seconds from a monotonic clock such as `ProcessInfo.systemUptime`.
///
/// This is deliberately unrelated to wall-clock time. A wall-clock correction
/// therefore cannot reorder environment observations.
public struct MonotonicTimestamp: Equatable, Hashable, Comparable, Sendable {
    public static let zero = MonotonicTimestamp(uncheckedSeconds: 0)

    public let seconds: TimeInterval

    public init?(seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        self.seconds = seconds
    }

    private init(uncheckedSeconds: TimeInterval) {
        seconds = uncheckedSeconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

/// A bounded, value-only observation that can change the pet's view of its
/// environment. Platform event and window objects never enter this type.
public struct PetStimulus: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case suspension(reason: SuspensionReason, active: Bool)
        case sleeping(Bool)
        case wanderingAvailability(Bool)
        case lowPower(Bool)
        case reduceMotion(Bool)
        case activeSpace(Bool)
        case interaction(Bool)
        case animating(Bool)
        case moving(Bool)
        case activityLevel(PetActivityLevel)
        case petBounds(CGRect?)
        case pointer(perception: PointerPerception, attention: PointerAttentionState)
    }

    public let timestamp: MonotonicTimestamp
    public let event: Event

    public init(timestamp: MonotonicTimestamp, event: Event) {
        self.timestamp = timestamp
        self.event = event
    }
}

/// The coherent world state used for behavior decisions.
///
/// All stored properties are immutable. Apply a `PetStimulus` with
/// `WorldReducer` to produce the next snapshot.
public struct PetWorldSnapshot: Equatable, Sendable {
    public let timestamp: MonotonicTimestamp
    public let activityPolicy: ActivityPolicy
    public let isSleeping: Bool
    public let canWander: Bool
    public let isLowPower: Bool
    public let isReduceMotion: Bool
    public let isOnActiveSpace: Bool
    public let isInteracting: Bool
    public let isAnimating: Bool
    public let isMoving: Bool
    public let activityLevel: PetActivityLevel
    public let petBounds: CGRect?
    public let pointer: PointerPerception
    public let attention: PointerAttentionState

    public init(
        timestamp: MonotonicTimestamp = .zero,
        activityPolicy: ActivityPolicy = ActivityPolicy(),
        isSleeping: Bool = false,
        canWander: Bool = false,
        isLowPower: Bool = false,
        isReduceMotion: Bool = false,
        isOnActiveSpace: Bool = true,
        isInteracting: Bool = false,
        isAnimating: Bool = false,
        isMoving: Bool = false,
        activityLevel: PetActivityLevel = .balanced,
        petBounds: CGRect? = nil,
        pointer: PointerPerception = .empty,
        attention: PointerAttentionState = .neutral
    ) {
        self.timestamp = timestamp
        self.activityPolicy = activityPolicy
        self.isSleeping = isSleeping
        self.canWander = canWander
        self.isLowPower = isLowPower
        self.isReduceMotion = isReduceMotion
        self.isOnActiveSpace = isOnActiveSpace
        self.isInteracting = isInteracting
        self.isAnimating = isAnimating
        self.isMoving = isMoving
        self.activityLevel = activityLevel
        self.petBounds = petBounds
        self.pointer = pointer
        self.attention = attention
    }

    public var isSuspended: Bool {
        !activityPolicy.allowsAnimation
    }

    /// Whether an already-idle runtime may schedule personality behavior.
    /// Direct interaction and explicit wake handling are separate paths.
    public var allowsAutonomousBehavior: Bool {
        !isSuspended
            && !isReduceMotion
            && isOnActiveSpace
            && !isInteracting
            && !isAnimating
            && !isMoving
    }
}
