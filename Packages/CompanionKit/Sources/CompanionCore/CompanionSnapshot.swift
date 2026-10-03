/// Immutable render data. Renderers have no reference back to the simulation.
public struct CompanionSnapshot: Sendable {
    public let scene: SceneGeometry
    public let presence: Presence
    public let phase: BodyPhase
    public let pose: CharacterPose
    public let feet: Point
    public let windowAnchor: Point
    public let rotation: Double
    public let openness: Double
    public let time: Double
    public let gesture: CharacterGesture?
    public let gestureAge: Double
    public let hitBounds: Rect
    public var clipsAtHome: Bool { phase == .hanging }
    public func contains(_ point: Point) -> Bool { hitBounds.contains(point) }
}
