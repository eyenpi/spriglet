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
    /// Continuous attachment of the hands to the home edge, independent of phase.
    public let homeGrip: Double
    public let time: Double
    public let gesture: CharacterGesture?
    public let hitBounds: Rect
    public func contains(_ point: Point) -> Bool { hitBounds.contains(point) && !scene.home.contains(point) }
}
