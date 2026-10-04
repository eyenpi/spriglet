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
    /// Uses the held target, exactly as release does, even while the body follows.
    public let canCatch: Bool
    public var geometry: MallowGeometry { MallowGeometry(self) }
    /// A bounding box for accessibility and broad-phase checks, never a pick shape.
    public var hitBounds: Rect {
        let bounds = geometry.bounds
        let top = bounds.minX >= scene.home.minX && bounds.maxX <= scene.home.maxX
            ? max(bounds.minY, scene.home.maxY) : bounds.minY
        let left = max(bounds.minX, scene.bounds.minX), right = min(bounds.maxX, scene.bounds.maxX)
        let bottom = min(bounds.maxY, scene.bounds.maxY), clippedTop = max(top, scene.bounds.minY)
        return Rect(x: left, y: clippedTop, width: max(0, right - left), height: max(0, bottom - clippedTop))
    }
    public func contains(_ point: Point) -> Bool {
        scene.bounds.contains(point) && !scene.home.contains(point) && geometry.contains(point)
    }
}
