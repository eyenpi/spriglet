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
    public let idleMoment: IdleMomentFrame?
    /// Continuous, deliberate hover response. The body stays hidden while the
    /// fingertips move slightly together; it does not invite the character.
    public let gripSqueeze: Double
    /// Hands transition independently while the original body emerges intact.
    public var fingertipGrip: Double {
        guard scene.form == .fingertipGrip else { return 0 }
        let reveal = clamp((openness - 0.6) / 0.4, 0, 1)
        return (1 - reveal * reveal * (3 - 2 * reveal)) * clamp(homeGrip, 0, 1)
    }
    public let homeHoverArmed: Bool
    /// The resting invitation target is independent of the painted silhouette.
    /// Keep it below the menu bar/housing so it cannot cover menu controls.
    public var homeHoverBounds: Rect? {
        guard scene.form == .fingertipGrip, phase == .hanging, presence == .peek else { return nil }
        let width = min(scene.hasHardwareNotch ? scene.home.width : 96, scene.bounds.width)
        let x = clamp(scene.home.midX - width / 2, scene.bounds.minX, scene.bounds.maxX - width)
        let top = max(scene.home.maxY, scene.bounds.minY)
        let height = min(20, scene.bounds.maxY - top)
        guard height > 0 else { return nil }
        return Rect(x: x, y: top, width: width, height: height)
    }
    public var inputBounds: Rect {
        guard let hover = homeHoverBounds else { return hitBounds }
        let paint = hitBounds
        let left = min(hover.minX, paint.minX), top = min(hover.minY, paint.minY)
        return Rect(x: left, y: top, width: max(hover.maxX, paint.maxX) - left,
                    height: max(hover.maxY, paint.maxY) - top)
    }
    public func containsHoverTarget(_ point: Point) -> Bool {
        contains(point) || (point.isFinite && homeHoverBounds?.contains(point) == true)
    }
    public func acceptsPress(_ point: Point) -> Bool {
        contains(point) || (homeHoverArmed && point.isFinite && homeHoverBounds?.contains(point) == true)
    }
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
                time: Double, gesture: CharacterGesture?, canCatch: Bool, idleMoment: IdleMomentFrame? = nil, gripSqueeze: Double = 0, homeHoverArmed: Bool = false) {
        self.scene = scene; self.presence = presence; self.phase = phase; self.pose = pose
        self.feet = feet; self.windowAnchor = windowAnchor; self.rotation = rotation
        self.openness = openness; self.homeGrip = homeGrip
        self.homeAttachment = homeAttachment ?? Point(x: scene.home.midX, y: scene.home.maxY)
        self.homeHoverArmed = homeHoverArmed
        self.gripSqueeze = gripSqueeze
        self.idleMoment = idleMoment
        self.dragGeometry = dragGeometry; self.time = time; self.gesture = gesture; self.canCatch = canCatch
    }
}
