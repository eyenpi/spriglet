/// A character action shared by the behavior planner and renderer.
public enum PetAction: String, CaseIterable, Codable, Sendable {
    case blink
    case lookAround
    case stretch
    case fallAsleep
    case wakeUp
    case react
}

/// One suggestion for the app's scheduler; this value starts no work itself.
public struct PlannedBehavior: Equatable, Sendable {
    public let action: PetAction
    public let delaySeconds: Double

    public init(action: PetAction, delaySeconds: Double) {
        self.action = action
        self.delaySeconds = delaySeconds
    }
}
