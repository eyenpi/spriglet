import Testing
@testable import CompanionCore

@Suite("Authored movement amplitude") struct MovementAmountTests {
    @Test("Scaled native canvases fit the visible character through grabs and landings", arguments: [0.8, 1.0, 1.2], [0.35, 1.0, 1.35])
    func canvasCoverage(scale: Double, amount: Double) {
        let scene = SceneGeometry(bounds: SceneGeometry.preview.bounds, home: SceneGeometry.preview.home,
                                  floor: SceneGeometry.preview.floor, scale: scale)
        var engine = CompanionEngine(scene: scene)
        engine.setMovementAmount(amount); engine.send(.command(.stretch))
        advance(&engine, seconds: 1.4)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 500, y: 260)))
        for index in 0..<360 {
            if index == 120 { engine.send(.pointerReleased(Point(x: 500, y: 260))) }
            engine.advance(by: 1 / 120.0)
            let frame = engine.snapshot
            let display = scene.bounds
            let window = WindowGeometry.desiredFrame(feet: frame.windowAnchor, display: display,
                                                     scale: scale, visibleBounds: frame.hitBounds)
            let drawing = WindowGeometry.drawingOrigin(window: window, display: display)
            let visible = frame.hitBounds
            #expect(visible.minX + drawing.x >= 0 && visible.maxX + drawing.x <= window.width)
            #expect(visible.minY + drawing.y >= 0 && visible.maxY + drawing.y <= window.height)
        }
    }
    @Test("Intensity changes breathing and swing amplitude while preserving blinks")
    func amplitude() {
        var gentle = CompanionEngine(scene: .preview), lively = gentle
        gentle.setMovementAmount(0.35); lively.setMovementAmount(1.35)
        var gentleMinimum = Double.infinity, gentleMaximum = -Double.infinity
        var livelyMinimum = Double.infinity, livelyMaximum = -Double.infinity, blink = false
        for _ in 0..<600 {
            gentle.advance(by: 1 / 120.0); lively.advance(by: 1 / 120.0)
            gentleMinimum = min(gentleMinimum, gentle.snapshot.pose.height)
            gentleMaximum = max(gentleMaximum, gentle.snapshot.pose.height)
            livelyMinimum = min(livelyMinimum, lively.snapshot.pose.height)
            livelyMaximum = max(livelyMaximum, lively.snapshot.pose.height)
            #expect(gentle.snapshot.pose.eyes == lively.snapshot.pose.eyes)
            blink = blink || gentle.snapshot.pose.eyes < 0.1
        }
        #expect(blink && livelyMaximum - livelyMinimum > (gentleMaximum - gentleMinimum) * 2)
        gentle.send(.command(.swing)); lively.send(.command(.swing))
        advance(&gentle, seconds: 0.2); advance(&lively, seconds: 0.2)
        #expect(abs(lively.snapshot.rotation) > abs(gentle.snapshot.rotation) * 2)
    }
    @Test("Changing amount preserves pointer capture and free physics")
    func heldPhysics() {
        var normal = CompanionEngine(scene: .preview)
        normal.send(.pointerPressed(normal.snapshot.hitBounds.center))
        normal.send(.pointerDragged(Point(x: 500, y: 220)))
        advance(&normal, seconds: 0.2)
        var gentle = normal
        gentle.setMovementAmount(0.35)
        #expect(gentle.hasPointerCapture && gentle.snapshot.phase == .held)
        #expect(gentle.snapshot.feet == normal.snapshot.feet)
        normal.send(.pointerReleased(Point(x: 500, y: 220)))
        gentle.send(.pointerReleased(Point(x: 500, y: 220)))
        for _ in 0..<300 {
            normal.advance(by: 1 / 120.0); gentle.advance(by: 1 / 120.0)
            #expect(normal.snapshot.feet == gentle.snapshot.feet)
            #expect(normal.snapshot.phase == gentle.snapshot.phase)
        }
    }
    @Test("Intensity scales quiet glances without changing their schedule or blinks")
    func quietGlances() {
        var gentle = CompanionEngine(scene: .preview), lively = gentle
        gentle.setMovementAmount(0.35); lively.setMovementAmount(1.35)
        var gentleLook = 0.0, livelyLook = 0.0
        for _ in 0..<2400 {
            gentle.advance(by: 1 / 30.0); lively.advance(by: 1 / 30.0)
            gentleLook = max(gentleLook, abs(gentle.snapshot.pose.look))
            livelyLook = max(livelyLook, abs(lively.snapshot.pose.look))
            #expect(gentle.snapshot.pose.eyes == lively.snapshot.pose.eyes)
            #expect(gentle.snapshot.presence == .peek && lively.snapshot.presence == .peek)
            #expect(gentle.snapshot.feet == lively.snapshot.feet)
        }
        #expect(gentleLook > 0.1 && livelyLook > gentleLook * 3)
    }
    @Test("Values are finite and bounded, survive recovery and respect Reduce Motion")
    func safety() {
        var engine = CompanionEngine(scene: .preview)
        engine.setMovementAmount(.nan); #expect(engine.movementAmount == 1)
        engine.setMovementAmount(.infinity); #expect(engine.movementAmount == 1)
        engine.setMovementAmount(-1); #expect(engine.movementAmount == 0)
        engine.setMovementAmount(100); #expect(engine.movementAmount == 1.5)
        engine.setMotionPolicy(.reduced); engine.send(.command(.swing))
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.rotation == 0 && engine.snapshot.pose.height == 1 && engine.snapshot.pose.arm == 0)
        engine.send(.cancelInteraction)
        #expect(engine.movementAmount == 1.5 && engine.motionPolicy == .reduced)
        engine.setMotionPolicy(.full); engine.send(.command(.swing))
        advance(&engine, seconds: 0.2)
        let before = engine.snapshot.rotation
        engine.setMovementAmount(0.3)
        #expect(abs(engine.snapshot.rotation - before * 0.2) < 0.000001)
    }
}
