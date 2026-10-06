import Testing
@testable import CompanionCore

@Suite("Reduce Motion interactions") struct ReducedMotionTests {
    private func expectStill(_ frame: CompanionSnapshot) {
        #expect(frame.rotation == 0 && frame.pose.height == 1 && frame.pose.width == 1)
        #expect(frame.pose.lean == 0 && frame.pose.look == 0 && frame.pose.arm == 0)
        #expect(frame.pose.walk == 0 && frame.pose.facing == 0)
    }

    @Test("Hover, invitation, reactions and dismissal change state without animated travel", arguments: [0.8, 1.0, 1.2])
    func interaction(scale: Double) {
        let scene = SceneGeometry(bounds: SceneGeometry.preview.bounds, home: SceneGeometry.preview.home,
                                  floor: SceneGeometry.preview.floor, scale: scale)
        var engine = CompanionEngine(scene: scene)
        engine.setMotionPolicy(.reduced)
        engine.send(.pointerMoved(engine.snapshot.hitBounds.center))
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.openness == 0.66)
        let hoverFeet = engine.snapshot.feet
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.feet == hoverFeet)
        for command in [CompanionCommand.greet, .swing, .stretch] {
            engine.send(.command(command))
            #expect(engine.snapshot.presence == .engaged && engine.snapshot.openness == 1)
            let feet = engine.snapshot.feet
            advance(&engine, seconds: 0.5)
            #expect(engine.snapshot.feet == feet)
            expectStill(engine.snapshot)
        }
        tap(&engine); expectStill(engine.snapshot)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        engine.send(.outsidePressed)
        #expect(engine.snapshot.presence == .peek && engine.snapshot.openness == 0.6)
        let feet = engine.snapshot.feet
        var blink = false
        for _ in 0..<15 * 30 {
            engine.advance(by: 1 / 15.0)
            #expect(engine.snapshot.feet == feet)
            expectStill(engine.snapshot)
            blink = blink || engine.snapshot.pose.eyes < 0.12
        }
        #expect(blink)
    }

    @Test("Dragging stays responsive and release recovers without precise catching", arguments: [false, true])
    func release(nearHome: Bool) {
        var engine = CompanionEngine(scene: .preview)
        engine.setMotionPolicy(.reduced)
        let start = engine.snapshot.hitBounds.center
        let destination = start + (nearHome ? Point(x: 20, y: 10) : Point(x: 260, y: 180))
        engine.send(.pointerPressed(start)); engine.send(.pointerDragged(destination))
        advance(&engine, seconds: 0.5)
        #expect(engine.hasPointerCapture && engine.snapshot.phase == .held)
        #expect(engine.snapshot.canCatch == nearHome)
        #expect(engine.snapshot.feet.distance(to: SceneGeometry.preview.homeFeet) > 5)
        expectStill(engine.snapshot)
        engine.send(.pointerReleased(destination))
        #expect(!engine.hasPointerCapture && engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
        #expect(engine.snapshot.windowAnchor == SceneGeometry.preview.homeFeet && engine.snapshot.openness == 0.6)
        engine.send(.pointerDragged(destination)); engine.send(.pointerReleased(destination))
        #expect(engine.snapshot.phase == .hanging && !engine.hasPointerCapture)
    }

    @Test("A live policy change stops every autonomous phase and preserves a deliberate grab", arguments: BodyPhase.allValidationPhases)
    func liveChange(phase: BodyPhase) {
        var engine = CompanionEngine(scene: .preview)
        switch phase {
        case .hanging: engine.send(.command(.swing)); advance(&engine, seconds: 0.2)
        case .held, .falling, .grounded, .preparingJump, .jumping:
            engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
            engine.send(.pointerDragged(Point(x: 500, y: 200)))
            advance(&engine, seconds: 0.3)
            if phase != .held { engine.send(.pointerReleased(Point(x: 500, y: 200))) }
            if [.grounded, .preparingJump, .jumping].contains(phase) { advance(&engine, seconds: 3) }
            if phase == .grounded { engine.send(.command(.walk)); advance(&engine, seconds: 0.3) }
            if phase == .preparingJump || phase == .jumping { engine.send(.command(.hop)) }
            if phase == .jumping { advance(&engine, seconds: 0.35) }
        case .catching:
            let start = engine.snapshot.hitBounds.center
            engine.send(.pointerPressed(start)); engine.send(.pointerDragged(start + Point(x: 20, y: 10)))
            advance(&engine, seconds: 0.3); engine.send(.pointerReleased(start))
        }
        #expect(engine.snapshot.phase == phase)
        engine.setMotionPolicy(.reduced)
        engine.setMotionPolicy(.reduced)
        expectStill(engine.snapshot)
        if phase == .held {
            #expect(engine.hasPointerCapture && engine.snapshot.phase == .held)
            engine.send(.pointerReleased(Point(x: 500, y: 200)))
        }
        for command in [CompanionCommand.walk, .hop, .returnHome] {
            engine.send(.command(command)); advance(&engine, seconds: 1)
            #expect(engine.snapshot.phase == .hanging && engine.snapshot.windowAnchor == SceneGeometry.preview.homeFeet && !engine.hasPointerCapture)
            expectStill(engine.snapshot)
        }
        engine.send(.cancelInteraction)
        #expect(engine.motionPolicy == .reduced && engine.snapshot.presence == .peek)
        engine.setMotionPolicy(.full); engine.send(.command(.swing)); advance(&engine, seconds: 0.2)
        #expect(abs(engine.snapshot.rotation) > 0.01)
    }

    @Test("Semantic gestures release pointer capture before stale drag events",
          arguments: [MotionPolicy.full, .reduced], [CompanionCommand.greet, .swing, .stretch])
    func inviteDuringGrab(policy: MotionPolicy, command: CompanionCommand) {
        var engine = CompanionEngine(scene: .preview)
        engine.setMotionPolicy(policy)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 500, y: 200)))
        engine.send(.command(command))
        #expect(!engine.hasPointerCapture && engine.snapshot.presence == .engaged)
        engine.send(.pointerDragged(Point(x: 600, y: 300))); engine.send(.pointerReleased(Point(x: 600, y: 300)))
        #expect(!engine.hasPointerCapture && engine.snapshot.phase != .held)
        engine.send(.cancelInteraction)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 500, y: 200)))
        engine.send(.activate)
        #expect(!engine.hasPointerCapture && engine.snapshot.phase != .held)
    }
}

private extension BodyPhase {
    static let allValidationPhases: [BodyPhase] = [.hanging, .held, .falling, .catching, .grounded, .preparingJump, .jumping]
}
