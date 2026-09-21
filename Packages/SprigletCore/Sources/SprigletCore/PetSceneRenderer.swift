/// Commands accepted by a scene renderer. The legacy clip identifiers remain
/// confined to this migration adapter until a character supplies its own graph.
public enum PetSceneCommand: Equatable, Sendable {
    case action(PetAction)
    case transition(SampleTransitionIntent)
    case routine(PetRoutine, direction: SampleClipID = .walkLeft, stationary: Bool = false)
    case sample(walk: SampleClipID)
    case resetPose
    case suspended(Bool)
    case interactionHeld(Bool)
    case preferredFramesPerSecond(Int)
}

/// A renderer reports finite activity without exposing its view or layers.
public struct PetSceneState: Equatable, Sendable {
    public let isAnimating: Bool
    public let isSleeping: Bool
    public let hasActiveFrameClock: Bool
    public let bufferedFrameCount: Int

    public init(isAnimating: Bool, isSleeping: Bool, hasActiveFrameClock: Bool, bufferedFrameCount: Int) {
        self.isAnimating = isAnimating
        self.isSleeping = isSleeping
        self.hasActiveFrameClock = hasActiveFrameClock
        self.bufferedFrameCount = bufferedFrameCount
    }
}

/// Behavior supplies commands; the application composition root separately
/// attaches a platform view and pairs authored root motion with its window host.
@MainActor
public protocol PetSceneRenderer: AnyObject {
    var sceneState: PetSceneState { get }

    /// True means accepted, including a coalesced request; never completion.
    @discardableResult func perform(_ command: PetSceneCommand) -> Bool
}
