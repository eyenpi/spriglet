import Foundation

/// Generic context facts with no app identity, title, document, or history.
public enum GenericContextStimulus: Hashable, Sendable {
    case appChanged
    case spaceChanged
    case displayWoke
    case sessionActivated
}

/// Coarse buckets derived only from elapsed time since real combined-session
/// input. They never infer a nap from randomness or elapsed app runtime.
public enum UserActivityBucket: Equatable, Sendable {
    case recent
    case idle
    case napEligible
}

/// A safe value summary of one explicit input-idle read.
public struct UserActivityEvaluation: Equatable, Sendable {
    public let idleDuration: TimeInterval
    public let bucket: UserActivityBucket
    /// A one-shot recheck delay for the nap threshold. `nil` means the caller
    /// has no activity deadline to schedule.
    public let nextIdleDeadlineSeconds: TimeInterval?

    public var shouldWake: Bool { bucket == .recent }
    public var allowsNap: Bool { bucket == .napEligible }
}

/// Product-configurable thresholds for deterministic user-activity policy.
public struct UserActivityPolicy: Equatable, Sendable {
    public static let standard = UserActivityPolicy(
        recentInputThreshold: 12,
        napThreshold: 300
    )!

    public let recentInputThreshold: TimeInterval
    public let napThreshold: TimeInterval

    public init?(recentInputThreshold: TimeInterval, napThreshold: TimeInterval) {
        guard recentInputThreshold.isFinite, napThreshold.isFinite,
              recentInputThreshold >= 0, napThreshold >= recentInputThreshold else { return nil }
        self.recentInputThreshold = recentInputThreshold
        self.napThreshold = napThreshold
    }

    public func evaluate(idleDuration: TimeInterval, isSleeping: Bool = false) -> UserActivityEvaluation? {
        guard idleDuration.isFinite, idleDuration >= 0 else { return nil }
        let bucket: UserActivityBucket
        if idleDuration <= recentInputThreshold {
            bucket = .recent
        } else if idleDuration >= napThreshold {
            bucket = .napEligible
        } else {
            bucket = .idle
        }
        let nextIdleDeadlineSeconds = !isSleeping && idleDuration < napThreshold
            ? napThreshold - idleDuration
            : nil
        return UserActivityEvaluation(
            idleDuration: idleDuration,
            bucket: bucket,
            nextIdleDeadlineSeconds: nextIdleDeadlineSeconds
        )
    }
}
