/// Turns reduced world facts into bounded semantic scene commands. Sources
/// publish facts only; direct interaction and macro ownership always win.
public enum PointerIntentDirector {
    public static func commands(in world: PetWorldSnapshot) -> [PetSceneCommand] {
        guard !world.isSuspended, !world.isSleeping, world.isOnActiveSpace,
              !world.isInteracting, !world.isAnimating, !world.isMoving,
              !world.isReduceMotion else { return [] }
        let attention = world.attention
        let lean = world.isLowPower ? 0 : attention.lean * attention.gaze.dx
        return [
            // Platform perception is Y-up; layered character coordinates are Y-down.
            .procedural(semanticID: "gaze", value: .init(x: attention.gaze.dx, y: -attention.gaze.dy)),
            .procedural(semanticID: "lean", value: .init(x: lean, y: 0)),
            .procedural(semanticID: "secondaryMotion", value: .init(x: lean, y: 0))
        ]
    }
}
