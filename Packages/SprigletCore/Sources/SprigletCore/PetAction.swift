/// A character action shared by the behavior planner and renderer.
public enum PetAction: String, CaseIterable, Codable, Sendable {
    case blink
    case lookAround
    case stretch
    case fallAsleep
    case wakeUp
    case react
}

/// Purposeful behavior chosen by the planner. User play remains an explicit command.
public enum PetBehaviorIntent: String, CaseIterable, Codable, Sendable {
    case observe, greet, explore, nap, wake
}

/// One suggestion for the app's scheduler; this value starts no work itself.
public struct PlannedBehavior: Equatable, Sendable {
    public let intent: PetBehaviorIntent
    public let delaySeconds: Double
    private let legacyActionOverride: PetAction?

    /// Compatibility for probes and callers that still preview individual assets.
    public var action: PetAction {
        if let legacyActionOverride { return legacyActionOverride }
        return switch intent {
        case .observe: .blink
        case .greet: .lookAround
        case .explore: .stretch
        case .nap: .fallAsleep
        case .wake: .wakeUp
        }
    }

    public init(intent: PetBehaviorIntent, delaySeconds: Double) {
        self.intent = intent
        self.delaySeconds = delaySeconds
        legacyActionOverride = nil
    }

    public init(action: PetAction, delaySeconds: Double) {
        intent = switch action {
        case .blink: .observe
        case .lookAround, .react: .greet
        case .stretch: .explore
        case .fallAsleep: .nap
        case .wakeUp: .wake
        }
        self.delaySeconds = delaySeconds
        legacyActionOverride = action == .react ? action : nil
    }
}
