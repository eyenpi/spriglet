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
    /// Current attachment point for the hands at the home edge.
    public let homeAttachment: Point
    /// Present only during an accepted desktop drag and its pending release.
    public let dragGeometry: DragGeometry?
    public let time: Double
    public let gesture: CharacterGesture?
    /// Uses the held target, exactly as release does, even while the body follows.
    public let canCatch: Bool
    public var geometry: MallowGeometry { MallowGeometry(self) }
    /// A bounding box for accessibility and broad-phase checks, never a pick shape.
    public var hitBounds: Rect {
        let bounds = geometry.bounds
        if let dragGeometry {
            let visible = dragGeometry.visibleRectangles.compactMap { surface -> Rect? in
                let x = max(bounds.minX, surface.minX), y = max(bounds.minY, surface.minY)
                let right = min(bounds.maxX, surface.maxX), bottom = min(bounds.maxY, surface.maxY)
                guard right > x, bottom > y else { return nil }
                return Rect(x: x, y: y, width: right - x, height: bottom - y)
            }
            guard !visible.isEmpty else { return Rect(x: 0, y: 0, width: 0, height: 0) }
            let left = visible.map(\.minX).min()!, top = visible.map(\.minY).min()!
            let right = visible.map(\.maxX).max()!, bottom = visible.map(\.maxY).max()!
            return Rect(x: left, y: top, width: right - left, height: bottom - top)
        }
        let top = bounds.minX >= scene.home.minX && bounds.maxX <= scene.home.maxX
            ? max(bounds.minY, scene.home.maxY) : bounds.minY
        let left = max(bounds.minX, scene.bounds.minX), right = min(bounds.maxX, scene.bounds.maxX)
        let bottom = min(bounds.maxY, scene.bounds.maxY), clippedTop = max(top, scene.bounds.minY)
        return Rect(x: left, y: clippedTop, width: max(0, right - left), height: max(0, bottom - clippedTop))
    }
    public func contains(_ point: Point) -> Bool {
        guard geometry.contains(point) else { return false }
        if let dragGeometry {
            return dragGeometry.visibleRectangles.contains { $0.contains(point) }
        }
        return scene.bounds.contains(point) && !scene.homeOcclusion.contains(point)
    }
    public init(scene: SceneGeometry, presence: Presence, phase: BodyPhase, pose: CharacterPose,
                feet: Point, windowAnchor: Point, rotation: Double, openness: Double,
                homeGrip: Double, homeAttachment: Point? = nil, dragGeometry: DragGeometry? = nil,
                time: Double, gesture: CharacterGesture?, canCatch: Bool) {
        self.scene = scene; self.presence = presence; self.phase = phase; self.pose = pose
        self.feet = feet; self.windowAnchor = windowAnchor; self.rotation = rotation
        self.openness = openness; self.homeGrip = homeGrip
        self.homeAttachment = homeAttachment ?? Point(x: scene.home.midX, y: scene.home.maxY)
        self.dragGeometry = dragGeometry; self.time = time; self.gesture = gesture; self.canCatch = canCatch
    }
}
