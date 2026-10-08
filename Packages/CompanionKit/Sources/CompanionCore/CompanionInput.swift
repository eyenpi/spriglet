/// A future capability can ask for an action without accessing windows,
/// drawing state, pointer monitoring, or the animation clock.
public enum CompanionCommand: CaseIterable, Sendable {
    case greet, swing, stretch, returnHome, walk, hop
    case idleWander, idleNap, idleDoodle, idleFidget
}

public enum CompanionInput: Sendable {
    case pointerMoved(Point)
    case pointerPressed(Point)
    case pointerDragged(Point)
    case pointerReleased(Point)
    case cancelInteraction
    case outsidePressed
    case activate
    case command(CompanionCommand)
}

public enum Presence: String, Sendable { case peek = "Curious peek", engaged = "Invited out", playing = "Playing" }
public enum BodyPhase: String, Sendable { case hanging, held, falling, catching, preparingJump, jumping, grounded }
public enum CharacterGesture: Sendable { case hello, swing, stretch }
