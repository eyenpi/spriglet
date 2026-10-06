public struct CharacterPose: Equatable, Sendable {
    public var width = 1.0, height = 1.0, lean = 0.0
    public var look = 0.0, eyes = 1.0, arm = 0.0, walk = 0.0, direction = 1.0
    public var facing = 0.0, lookY = 0.0
    public var gaitPhase = 0.0
    public init() {}
}
