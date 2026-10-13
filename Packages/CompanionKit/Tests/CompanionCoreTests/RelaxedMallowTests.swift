import Testing
@testable import CompanionCore

@Suite("Relaxed Small Mallow") struct RelaxedMallowTests {
    private func scene(notch: Bool = true, form: MallowForm = .relaxed) -> SceneGeometry {
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                      home: Rect(x: 260, y: notch ? 0 : 13, width: 200, height: notch ? 54 : 20),
                      floor: 365, scale: 0.6, hasHardwareNotch: notch, form: form)
    }

    @Test("The relaxed home keeps a broad face with half the default height", arguments: [true, false])
    func compactHome(notch: Bool) {
        let frame = CompanionEngine(scene: scene(notch: notch)).snapshot
        #expect(frame.hitBounds.height < 14)
        #expect(frame.hitBounds.width > 100)
        #expect(frame.hitBounds.minY == frame.scene.home.maxY)
        #expect(frame.contains(frame.hitBounds.center))
        for hand in frame.geometry.hands { #expect(frame.contains(hand.palm.center)) }
        #expect(!frame.contains(Point(x: frame.hitBounds.minX + 1, y: frame.hitBounds.maxY - 1)))
        #expect(!frame.contains(Point(x: frame.scene.home.midX, y: frame.scene.home.maxY - 1)))
    }

    @Test("Invite and return unfold and retuck continuously")
    func inviteAndReturn() {
        var engine = CompanionEngine(scene: scene())
        let point = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(point)); engine.send(.pointerReleased(point))
        #expect(engine.snapshot.presence == .engaged)
        #expect(engine.snapshot.relaxation == 1)
        var previous = engine.snapshot
        for _ in 0..<120 {
            engine.advance(by: 1 / 120.0)
            let next = engine.snapshot
            for (a, b) in zip(previous.geometry.bodyContour, next.geometry.bodyContour) {
                #expect(a.start.distance(to: b.start) < 6)
            }
            previous = next
        }
        #expect(engine.snapshot.relaxation < 0.001)
        engine.send(.outsidePressed)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        for _ in 0..<180 { engine.advance(by: 1 / 120.0) }
        #expect(engine.snapshot.relaxation > 0.999)
        #expect(engine.snapshot.hitBounds.height < 14)
    }

    @Test("Hover stays compact without inviting Mallow")
    func hover() {
        var engine = CompanionEngine(scene: scene())
        engine.send(.pointerMoved(engine.snapshot.hitBounds.center))
        for _ in 0..<120 { engine.advance(by: 1 / 120.0) }
        #expect(engine.snapshot.presence == .peek)
        #expect(engine.snapshot.relaxation > 0.9)
        #expect(engine.snapshot.hitBounds.height < 19)
    }

    @Test("A grab preserves the entire drape before the first simulation step")
    func grabContinuity() {
        var engine = CompanionEngine(scene: scene())
        let before = engine.snapshot, point = before.hitBounds.center
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 10, y: 0)))
        let after = engine.snapshot
        #expect(engine.hasPointerCapture && engine.isDragging)
        #expect(after.phase == .held && after.relaxation == before.relaxation)
        #expect(after.feet == before.feet && after.pose == before.pose)
        #expect(after.hitBounds == before.hitBounds)
        for _ in 0..<120 { engine.advance(by: 1 / 120.0) }
        #expect(engine.snapshot.relaxation < 0.001)
        engine.send(.cancelInteraction)
        #expect(engine.snapshot.relaxation == 1 && !engine.hasPointerCapture)
    }

    @Test("Reduce Motion uses still unfolded and tucked poses with safe recovery")
    func reducedMotion() {
        var engine = CompanionEngine(scene: scene(notch: false))
        engine.setMotionPolicy(.reduced)
        #expect(engine.snapshot.relaxation == 1)
        engine.send(.activate)
        #expect(engine.snapshot.relaxation == 0)
        engine.send(.outsidePressed)
        #expect(engine.snapshot.relaxation == 1)
        let point = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 80, y: 80)))
        engine.send(.pointerReleased(point + Point(x: 80, y: 80)))
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.relaxation == 1)
        #expect(!engine.hasPointerCapture)
    }

    @Test("Display transfers preserve the relaxed form and reject mismatched forms")
    func transfer() {
        let source = scene()
        var engine = CompanionEngine(scene: source)
        let point = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 20, y: 30)))
        let destination = scene(notch: false)
        let geometry = DragGeometry(surfaces: [DragSurface(bounds: destination.bounds, housing: destination.homeOcclusion)],
                                    heldBounds: destination.bounds)
        let rejected = engine.transferDrag(scene: scene(form: .standard), translation: .zero, geometry: geometry)
        #expect(!rejected)
        let before = engine.snapshot
        let delta = Point(x: -25, y: 10)
        let transferred = engine.transferDrag(scene: destination, translation: delta, geometry: geometry)
        #expect(transferred)
        let after = engine.snapshot
        #expect(after.relaxation == before.relaxation && after.pose == before.pose)
        #expect(after.feet == before.feet + delta && after.homeAttachment == before.homeAttachment + delta)
    }
}
