import Testing
@testable import CompanionCore

@Suite("Display transfer") struct DisplayTransferTests {
    @Test("Global point and transfer deltas match independent display oracles", arguments: [
        (Rect(x: 0, y: 0, width: 1440, height: 900), Rect(x: 1440, y: -200, width: 1920, height: 1080),
         Point(x: 1500, y: 700), Point(x: 60, y: 180), Point(x: -1440, y: -20)),
        (Rect(x: 0, y: 0, width: 1440, height: 900), Rect(x: -1280, y: 100, width: 1280, height: 800),
         Point(x: -100, y: 600), Point(x: 1180, y: 300), Point(x: 1280, y: 0)),
        (Rect(x: 0, y: 0, width: 1440, height: 900), Rect(x: 200, y: 900, width: 1600, height: 1000),
         Point(x: 500, y: 1000), Point(x: 300, y: 900), Point(x: -200, y: 1000)),
        (Rect(x: 0, y: 0, width: 1440, height: 900), Rect(x: -200, y: -900, width: 1200, height: 900),
         Point(x: 100, y: -100), Point(x: 300, y: 100), Point(x: 200, y: -900)),
    ])
    func independentCoordinates(old: Rect, new: Rect, global: Point, local: Point, delta: Point) {
        #expect(DesktopDragCoordinates.globalToLocal(global, display: new) == local)
        #expect(DesktopDragCoordinates.translation(from: old, to: new) == delta)
    }

    @Test("A rapid cross-display transfer preserves capture, pose and motion history", arguments: [0.8, 1.0, 1.2])
    func transferKeepsContinuousHeldState(scale: Double) {
        let source = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                   home: Rect(x: 260, y: 0, width: 200, height: 54),
                                   floor: 365, scale: scale)
        var engine = CompanionEngine(scene: source)
        let initial = engine.snapshot
        let surfaceA = DragSurface(bounds: initial.scene.bounds, housing: initial.scene.home)
        let held = Rect(x: initial.scene.leftLimit, y: initial.scene.ceiling,
                        width: initial.scene.rightLimit - initial.scene.leftLimit,
                        height: initial.scene.floor - initial.scene.ceiling)
        let captured = engine.sendAndCapture(at: initial.hitBounds.center,
                                             geometry: DragGeometry(surfaces: [surfaceA], heldBounds: held))
        #expect(captured)
        engine.send(.pointerDragged(Point(x: 610, y: 220)))
        engine.advance(by: 1 / 120)
        let before = engine.snapshot

        let destination = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 900, height: 600),
                                        home: Rect(x: 710, y: 10, width: 150, height: 24),
                                        floor: 565, scale: scale, hasHardwareNotch: false)
        let delta = Point(x: -720, y: -40)
        let translatedGeometry = DragGeometry(
            surfaces: [DragSurface(bounds: destination.bounds, housing: destination.home)],
            heldBounds: Rect(x: destination.leftLimit, y: destination.ceiling,
                             width: destination.rightLimit - destination.leftLimit,
                             height: destination.floor - destination.ceiling))
        let transferred = engine.transferDrag(scene: destination, translation: delta, geometry: translatedGeometry)
        #expect(transferred)
        let after = engine.snapshot
        #expect(engine.isDragging && engine.hasPointerCapture)
        #expect(after.scene == destination)
        #expect(after.windowAnchor == before.windowAnchor + delta)
        #expect(after.pose == before.pose)
        #expect(after.dragGeometry == translatedGeometry)
        #expect(after.homeAttachment == before.homeAttachment + delta)
        let reverse = DragGeometry(surfaces: [surfaceA], heldBounds: held)
        let returned = engine.transferDrag(scene: source, translation: Point(x: -delta.x, y: -delta.y), geometry: reverse)
        #expect(returned)
        #expect(engine.snapshot.windowAnchor == before.windowAnchor)
        #expect(engine.snapshot.homeAttachment == before.homeAttachment)
        #expect(engine.isDragging && engine.hasPointerCapture)
    }

    @Test("Invalid geometry and nonheld transfer are rejected without changing state")
    func invalidAndUnheldTransfers() {
        var engine = CompanionEngine(scene: .preview)
        let before = engine.snapshot
        let invalid = DragGeometry(surfaces: [], heldBounds: Rect(x: 0, y: 0, width: .infinity, height: 4))
        let began = engine.beginDesktopDrag(geometry: invalid)
        let transferred = engine.transferDrag(scene: .preview, translation: .zero, geometry: invalid)
        #expect(!began)
        #expect(!transferred)
        #expect(engine.snapshot.windowAnchor == before.windowAnchor && !engine.hasPointerCapture)
    }

    @Test("Shared drag surfaces allow both displays, reject gaps and housing")
    func sharedSurfacePicking() {
        let scene = SceneGeometry.preview
        var pose = CharacterPose(); pose.arm = 0.8
        let geometry = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 0, y: 0, width: 300, height: 420), housing: Rect(x: 250, y: 0, width: 50, height: 35)),
            DragSurface(bounds: Rect(x: 420, y: 0, width: 300, height: 420), housing: Rect(x: 500, y: 0, width: 100, height: 35)),
        ], heldBounds: Rect(x: 55, y: 40, width: 610, height: 300))
        let frame = CompanionSnapshot(scene: scene, presence: .playing, phase: .held, pose: pose,
                                      feet: Point(x: 450, y: 230), windowAnchor: .zero, rotation: 0,
                                      openness: 1, homeGrip: 0, dragGeometry: geometry,
                                      time: 0, gesture: nil, canCatch: false)
        #expect(frame.dragGeometry == geometry)
        #expect(!frame.contains(Point(x: 350, y: 200)))
        #expect(!frame.contains(Point(x: 540, y: 20)))
        #expect(frame.hitBounds.width <= 720)
        let overlapping = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 0, y: 0, width: 400, height: 100), housing: Rect(x: 0, y: 0, width: 40, height: 20)),
            DragSurface(bounds: Rect(x: 300, y: 0, width: 400, height: 100), housing: Rect(x: 500, y: 0, width: 40, height: 20)),
        ], heldBounds: Rect(x: 0, y: 0, width: 700, height: 100))
        let visibleArea = overlapping.visibleRectangles.reduce(0.0) { $0 + $1.width * $1.height }
        #expect(abs(visibleArea - (700 * 100 - 40 * 20 - 40 * 20)) < 0.001)
        #expect(overlapping.visibleRectangles.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    @Test("Crossing an internal seam at a corner keeps the held engine pose continuous")
    func seamAndCornerDoNotBecomeWalls() {
        let source = SceneGeometry.preview
        let destination = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                        home: Rect(x: 260, y: 0, width: 200, height: 54),
                                        floor: 365, scale: source.scale)
        var engine = CompanionEngine(scene: source)
        let all = DragGeometry(surfaces: [
            DragSurface(bounds: source.bounds, housing: source.home),
            DragSurface(bounds: Rect(x: 720, y: 0, width: 720, height: 420),
                        housing: Rect(x: 980, y: 0, width: 200, height: 54)),
        ], heldBounds: Rect(x: 55, y: source.ceiling, width: 1330, height: source.floor - source.ceiling))
        let captured = engine.sendAndCapture(at: engine.snapshot.hitBounds.center, geometry: all)
        #expect(captured)
        engine.send(.pointerDragged(Point(x: 650, y: 120)))
        engine.advance(by: 0.5)
        let beforeSeam = engine.snapshot
        engine.send(.pointerDragged(Point(x: 735, y: 8)))
        engine.advance(by: 0.1)
        let acrossSeam = engine.snapshot
        #expect(acrossSeam.phase == .held && engine.hasPointerCapture)
        #expect(abs(acrossSeam.pose.width - beforeSeam.pose.width) < 0.02)
        #expect(abs(acrossSeam.pose.height - beforeSeam.pose.height) < 0.03)

        let delta = Point(x: -720, y: 420)
        let moved = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: -720, y: 420, width: 720, height: 420),
                        housing: Rect(x: -460, y: 420, width: 200, height: 54)),
            DragSurface(bounds: destination.bounds, housing: destination.home),
        ], heldBounds: Rect(x: -665, y: destination.ceiling,
                           width: 1330, height: 420 + destination.floor - destination.ceiling))
        // Translate from the lower display to an upper display while still held.
        let transfer = engine.transferDrag(scene: destination, translation: delta, geometry: moved)
        #expect(transfer)
        #expect(engine.hasPointerCapture && engine.isDragging)
        #expect(engine.snapshot.dragGeometry == moved)
    }

    @Test("Release outside the destination keeps clipping until the body settles inside it")
    func pendingReleaseReturnsToDestinationBounds() {
        let source = SceneGeometry.preview
        let destination = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 600, height: 420),
                                        home: Rect(x: 390, y: 8, width: 160, height: 24),
                                        floor: 380, scale: source.scale, hasHardwareNotch: false)
        var engine = CompanionEngine(scene: source)
        let sourceSurface = DragSurface(bounds: source.bounds, housing: source.home)
        let otherSurfaceInSource = DragSurface(bounds: Rect(x: -720, y: 0, width: 600, height: 420),
                                               housing: Rect(x: -330, y: 8, width: 160, height: 24))
        let unionInSource = Rect(x: -665, y: source.ceiling, width: 1330, height: source.floor - source.ceiling)
        let geometry = DragGeometry(surfaces: [sourceSurface, otherSurfaceInSource], heldBounds: unionInSource)
        let captured = engine.sendAndCapture(at: engine.snapshot.hitBounds.center, geometry: geometry)
        #expect(captured)
        engine.send(.pointerDragged(Point(x: 700, y: 280)))
        engine.advance(by: 0.8)
        let delta = Point(x: 720, y: 0)
        let transferredGeometry = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 720, y: 0, width: source.bounds.width, height: source.bounds.height),
                        housing: Rect(x: 720 + source.home.x, y: source.home.y, width: source.home.width, height: source.home.height)),
            DragSurface(bounds: destination.bounds, housing: destination.home),
        ], heldBounds: Rect(x: 55, y: destination.ceiling,
                           width: 1330, height: destination.floor - destination.ceiling))
        let transferred = engine.transferDrag(scene: destination, translation: delta, geometry: transferredGeometry)
        #expect(transferred)
        engine.send(.pointerReleased(Point(x: 1400, y: 280)))
        #expect(!engine.hasPointerCapture)
        #expect(engine.snapshot.phase == .held)
        #expect(engine.snapshot.dragGeometry == transferredGeometry)
        for _ in 0..<600 where engine.snapshot.phase == .held { engine.advance(by: 1 / 120) }
        #expect(engine.snapshot.phase != .held)
        #expect(engine.snapshot.dragGeometry == nil)
        #expect(engine.snapshot.windowAnchor.x >= destination.leftLimit - 0.001)
        #expect(engine.snapshot.windowAnchor.x <= destination.rightLimit + 0.001)
    }

    @Test("Reduce Motion keeps capture and returns to the transferred home on release")
    func reducedMotionReleaseUsesDestinationHome() {
        let source = SceneGeometry.preview
        let destination = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 800, height: 480),
                                        home: Rect(x: 620, y: 12, width: 150, height: 24),
                                        floor: 450, scale: source.scale, hasHardwareNotch: false)
        var engine = CompanionEngine(scene: source)
        let sourceHeld = Rect(x: source.leftLimit, y: source.ceiling,
                              width: source.rightLimit - source.leftLimit, height: source.floor - source.ceiling)
        let sourceGeometry = DragGeometry(surfaces: [DragSurface(bounds: source.bounds, housing: source.home)],
                                          heldBounds: sourceHeld)
        let captured = engine.sendAndCapture(at: engine.snapshot.hitBounds.center, geometry: sourceGeometry)
        #expect(captured)
        engine.send(.pointerDragged(Point(x: 600, y: 200)))
        let destinationGeometry = DragGeometry(surfaces: [DragSurface(bounds: destination.bounds, housing: destination.home)],
                                              heldBounds: Rect(x: destination.leftLimit, y: destination.ceiling,
                                                               width: destination.rightLimit - destination.leftLimit,
                                                               height: destination.floor - destination.ceiling))
        let transferred = engine.transferDrag(scene: destination, translation: Point(x: -100, y: 20),
                                              geometry: destinationGeometry)
        #expect(transferred)
        engine.setMotionPolicy(.reduced)
        let time = engine.time
        engine.send(.pointerDragged(Point(x: 500, y: 220)))
        engine.send(.pointerReleased(Point(x: 500, y: 220)))
        #expect(!engine.hasPointerCapture && !engine.hasPendingDragRelease)
        #expect(engine.snapshot.phase == .hanging)
        #expect(engine.snapshot.scene == destination)
        #expect(engine.snapshot.windowAnchor == destination.homeFeet)
        #expect(engine.snapshot.homeAttachment == Point(x: destination.home.midX, y: destination.home.maxY))
        #expect(engine.snapshot.dragGeometry == nil && engine.time == time)
    }
}

private extension CompanionEngine {
    mutating func sendAndCapture(at point: Point, geometry: DragGeometry) -> Bool {
        send(.pointerPressed(point))
        return beginDesktopDrag(geometry: geometry)
    }
}
