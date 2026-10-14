import Testing
@testable import CompanionCore

@Suite("Fingertip Small Mallow") struct FingertipGripTests {
    private func scene(notch: Bool = true, form: MallowForm = .fingertipGrip) -> SceneGeometry {
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                      home: Rect(x: 260, y: notch ? 0 : 13, width: 200, height: notch ? 54 : 20),
                      floor: 365, scale: 0.8, hasHardwareNotch: notch, form: form)
    }
    private func fingertip(_ frame: CompanionSnapshot) -> Point {
        Point(x: frame.geometry.hands[0].palm.midX, y: frame.scene.home.maxY + 1)
    }
    private func advance(_ engine: inout CompanionEngine, seconds: Double = 1) {
        for _ in 0..<Int(seconds * 120) { engine.advance(by: 1 / 120.0) }
    }

    @Test("Only fingertips are painted and pickable at rest", arguments: [true, false])
    func compactHome(notch: Bool) {
        let frame = CompanionEngine(scene: scene(notch: notch)).snapshot
        #expect(frame.hitBounds.height > 1 && frame.hitBounds.height < 4)
        #expect(frame.hitBounds.minY == frame.scene.home.maxY)
        #expect(frame.contains(fingertip(frame)))
        #expect(!frame.contains(frame.hitBounds.center))
        #expect(!frame.contains(Point(x: frame.scene.home.midX, y: frame.scene.home.maxY + 8)))
        #expect(!frame.contains(Point(x: frame.scene.home.midX, y: frame.scene.home.maxY - 1)))
    }

    @Test("Click emerges as exactly Medium and return restores the tiny grip", arguments: [true, false])
    func inviteAndReturn(notch: Bool) {
        var small = CompanionEngine(scene: scene(notch: notch))
        var medium = CompanionEngine(scene: scene(notch: notch, form: .standard))
        let point = fingertip(small.snapshot)
        small.send(.pointerPressed(point)); small.send(.pointerReleased(point))
        medium.send(.activate)
        small.send(.pointerMoved(Point(x: -1000, y: -1000)))
        #expect(small.snapshot.presence == .engaged)
        advance(&small, seconds: 2); advance(&medium, seconds: 2)
        #expect(small.snapshot.fingertipGrip < 0.001)
        #expect(small.snapshot.pose == medium.snapshot.pose)
        #expect(small.snapshot.feet.distance(to: medium.snapshot.feet) < 0.001)
        #expect(small.snapshot.geometry.bounds.center.distance(to: medium.snapshot.geometry.bounds.center) < 0.001)
        #expect(abs(small.snapshot.geometry.bounds.width - medium.snapshot.geometry.bounds.width) < 0.001)
        small.send(.outsidePressed); small.send(.pointerMoved(Point(x: -1000, y: -1000)))
        advance(&small, seconds: 2)
        #expect(small.snapshot.fingertipGrip > 0.999 && small.snapshot.hitBounds.height < 4)
    }

    @Test("A direct fingertip drag starts without a jump and emerges normally")
    func grabContinuity() {
        var engine = CompanionEngine(scene: scene())
        let before = engine.snapshot, point = fingertip(before)
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 10, y: 0)))
        let after = engine.snapshot
        #expect(engine.hasPointerCapture && engine.isDragging)
        #expect(after.phase == .held && after.fingertipGrip == before.fingertipGrip)
        #expect(after.feet == before.feet && after.pose == before.pose && after.hitBounds == before.hitBounds)
        advance(&engine)
        #expect(engine.snapshot.fingertipGrip < 0.001)
        engine.send(.cancelInteraction)
        #expect(engine.snapshot.fingertipGrip == 1 && !engine.hasPointerCapture)
    }

    @Test("Reduce Motion uses intact peek and invited artwork with safe recovery")
    func reducedMotion() {
        var engine = CompanionEngine(scene: scene(notch: false))
        engine.setMotionPolicy(.reduced)
        engine.send(.pointerMoved(fingertip(engine.snapshot))); advance(&engine)
        #expect(engine.snapshot.homeTuck == 0 && engine.snapshot.hitBounds.height > 24)
        engine.send(.activate)
        #expect(engine.snapshot.fingertipGrip == 0)
        var medium = CompanionEngine(scene: scene(notch: false, form: .standard))
        medium.setMotionPolicy(.reduced); medium.send(.activate)
        #expect(engine.snapshot.feet == medium.snapshot.feet && engine.snapshot.pose == medium.snapshot.pose)
        engine.send(.outsidePressed)
        #expect(engine.snapshot.fingertipGrip == 1 && engine.snapshot.hitBounds.height < 4)
        let point = fingertip(engine.snapshot)
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 80, y: 80)))
        engine.send(.pointerReleased(point + Point(x: 80, y: 80)))
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.fingertipGrip == 1 && !engine.hasPointerCapture)
    }

    @Test("Small stays parked through autonomous boredom and restores fingertips on recovery")
    func quietRecovery() {
        var engine = CompanionEngine(scene: scene(), boredomTiming: BoredomTiming(threshold: 0.1, cooldown: 0.1))
        advance(&engine, seconds: 10)
        #expect(engine.requestedIdleMoment == nil && engine.snapshot.hitBounds.height < 4)
        engine.send(.pointerMoved(fingertip(engine.snapshot))); advance(&engine)
        engine.reconfigure(scene: scene(notch: false))
        #expect(engine.snapshot.homeTuck == 1 && engine.snapshot.fingertipGrip == 1)
    }

    @Test("Display transfers preserve grip and reject a different resting mode")
    func transfer() {
        let source = scene()
        var engine = CompanionEngine(scene: source)
        let point = fingertip(engine.snapshot)
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 20, y: 30)))
        let destination = scene(notch: false)
        let geometry = DragGeometry(surfaces: [DragSurface(bounds: destination.bounds, housing: destination.homeOcclusion)],
                                    heldBounds: destination.bounds)
        let rejected = engine.transferDrag(scene: scene(form: .standard), translation: .zero, geometry: geometry)
        #expect(!rejected)
        let before = engine.snapshot, delta = Point(x: -25, y: 10)
        let transferred = engine.transferDrag(scene: destination, translation: delta, geometry: geometry)
        #expect(transferred)
        let after = engine.snapshot
        #expect(after.fingertipGrip == before.fingertipGrip && after.pose == before.pose)
        #expect(after.feet == before.feet + delta && after.homeAttachment == before.homeAttachment + delta)
    }
}
