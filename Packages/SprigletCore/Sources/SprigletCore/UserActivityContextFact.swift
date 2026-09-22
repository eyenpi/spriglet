import Foundation

/// A coordinate-free consequence of a context or aggregate input-idle read.
/// These values deliberately contain no application identity, input event, or
/// duration and can be routed through a pure world reducer later.
public struct UserActivityContextFact: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case wakeRequested
        case napEligible
        case appGlance
    }

    public let timestamp: MonotonicTimestamp
    public let kind: Kind

    public init(timestamp: MonotonicTimestamp, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}
