import Testing
@testable import CompanionCore

@Suite("Notch catch feedback") struct CatchFeedbackTests {
    @Test("Readiness agrees with release on each side of the catch boundary", arguments: [0.6, 1.0, 1.5])
    func catchBoundaries(scale: Double) {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 900, height: 700),
                                  home: Rect(x: 350, y: 0, width: 200, height: 54), floor: 650, scale: scale)
        let left = scene.home.minX - 20 * scale, right = scene.home.maxX + 20 * scale
        let bottom = scene.home.maxY + 115 * scale, y = scene.home.maxY + 80 * scale
        let targets = [(Point(x: left - 0.1, y: y), false), (Point(x: left, y: y), true),
                       (Point(x: right, y: y), true), (Point(x: right + 0.1, y: y), false),
                       (Point(x: scene.home.midX, y: bottom), true), (Point(x: scene.home.midX, y: bottom + 0.1), false)]
        for (feet, expected) in targets {
            var engine = CompanionEngine(scene: scene)
            let start = engine.snapshot.feet - Point(x: 0, y: 20 * scale)
            #expect(engine.snapshot.contains(start))
            engine.send(.pointerPressed(start))
            let pointer = start + feet - engine.snapshot.feet
            engine.send(.pointerDragged(pointer))
            #expect(engine.snapshot.canCatch == expected)
            engine.send(.pointerReleased(pointer))
            #expect(engine.snapshot.phase == (expected ? .catching : .falling))
            #expect(!engine.snapshot.canCatch && !engine.hasPointerCapture)
        }
    }
    @Test("A ready hold looks up subtly and relaxes after moving away", arguments: [MotionPolicy.full, .reduced])
    func upwardLook(policy: MotionPolicy) {
        var ready = CompanionEngine(scene: .preview)
        ready.setMotionPolicy(policy)
        let start = ready.snapshot.hitBounds.center
        ready.send(.pointerPressed(start))
        let near = start + Point(x: 20, y: 20)
        ready.send(.pointerDragged(near))
        #expect(ready.snapshot.canCatch)
        var away = ready
        away.send(.pointerDragged(start + Point(x: 240, y: 160)))
        #expect(!away.snapshot.canCatch)
        advance(&ready, seconds: 0.7); advance(&away, seconds: 0.7)
        #expect(ready.snapshot.pose.lookY < away.snapshot.pose.lookY - 4)
        if policy == .full { #expect(ready.snapshot.pose.arm > away.snapshot.pose.arm + 0.1) }
        else { #expect(ready.snapshot.pose.arm == 0) }
        let before = ready.snapshot
        ready.send(.pointerDragged(start + Point(x: 240, y: 160)))
        #expect(!ready.snapshot.canCatch && ready.snapshot.pose == before.pose)
        advance(&ready, seconds: 0.7)
        #expect(abs(ready.snapshot.pose.lookY - away.snapshot.pose.lookY) < 0.1)
        ready.send(.cancelInteraction)
        #expect(!ready.snapshot.canCatch && ready.snapshot.presence == .peek)
    }
    @Test("A fast departure clears readiness before the following body moves")
    func targetReadiness() {
        var engine = CompanionEngine(scene: .preview)
        let start = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(start)); engine.send(.pointerDragged(start + Point(x: 20, y: 10)))
        advance(&engine, seconds: 0.5)
        #expect(engine.snapshot.canCatch)
        let before = engine.snapshot.feet
        engine.send(.pointerDragged(Point(x: 80, y: 250)))
        #expect(engine.snapshot.feet == before && !engine.snapshot.canCatch)
        engine.send(.pointerReleased(Point(x: 80, y: 250)))
        #expect(engine.snapshot.phase == .falling)
    }
}
