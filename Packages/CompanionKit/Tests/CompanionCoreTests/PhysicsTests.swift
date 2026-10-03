import Foundation
import Testing
@testable import CompanionCore

@Suite("Desktop physics") struct PhysicsTests {
    @Test("A grab starts at the visible peek without a jump, on real notch geometry")
    func nativeGrab() {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1512, height: 982),
                                  home: Rect(x: 663.5, y: 0, width: 185, height: 32), floor: 898)
        var engine = CompanionEngine(scene: scene)
        let before = engine.snapshot.feet, p = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(p)); engine.send(.pointerDragged(p + Point(x: 5, y: 0)))
        #expect(engine.snapshot.feet.distance(to: before) < 0.001)
        let initialPose = engine.snapshot.pose
        engine.advance(by: 1 / 120.0)
        #expect(engine.snapshot.feet.distance(to: before) < 2)
        #expect(abs(engine.snapshot.pose.height - initialPose.height) < 0.15)
    }
    @Test("Gravity lands and settles at different host frame rates", arguments: [12.0, 30, 60, 120])
    func gravity(fps: Double) {
        var engine = CompanionEngine(scene: .preview)
        drag(&engine, to: Point(x: 520, y: 200))
        advance(&engine, seconds: 3, fps: fps)
        #expect(engine.snapshot.phase == .grounded)
        #expect(abs(engine.snapshot.feet.y - engine.snapshot.scene.floor) < 0.001)
        #expect(engine.snapshot.pose.width > 0.9 && engine.snapshot.pose.width < 1.2)
        engine.send(.outsidePressed); advance(&engine, seconds: 3, fps: fps)
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
        #expect(abs(engine.snapshot.openness - 0.6) < 0.001)
    }
    @Test("Near-notch release catches smoothly instead of falling")
    func catchNotch() {
        var engine = CompanionEngine(scene: .preview)
        let p = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(p)); engine.send(.pointerDragged(p + Point(x: 25, y: 10)))
        advance(&engine, seconds: 0.4)
        let before = engine.snapshot.feet
        engine.send(.pointerReleased(p))
        #expect(engine.snapshot.phase == .catching)
        #expect(engine.snapshot.feet.distance(to: before) < 0.001)
        advance(&engine, seconds: 3)
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
    }
    @Test("A fast drag away does not catch because the body lagged behind")
    func fastRelease() {
        var engine = CompanionEngine(scene: .preview)
        let p = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(p)); engine.send(.pointerDragged(p + Point(x: 10, y: 5)))
        advance(&engine, seconds: 0.3)
        engine.send(.pointerDragged(Point(x: 90, y: 250)))
        engine.send(.pointerReleased(Point(x: 90, y: 250)))
        #expect(engine.snapshot.phase == .falling)
    }
    @Test("Return home can interrupt a hop without restarting an existing return")
    func jumpInterruption() {
        var engine = CompanionEngine(scene: .preview)
        drag(&engine, to: Point(x: 520, y: 200)); advance(&engine, seconds: 3)
        engine.send(.command(.hop)); advance(&engine, seconds: 0.35)
        #expect(engine.snapshot.phase == .jumping)
        engine.send(.command(.returnHome))
        for _ in 0..<180 { engine.send(.outsidePressed); engine.advance(by: 1 / 60.0) }
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
    }
    @Test("Fixed simulation steps make frame cadence independent")
    func deterministicCadence() {
        var slow = CompanionEngine(scene: .preview), fast = slow
        drag(&slow, to: Point(x: 520, y: 200)); drag(&fast, to: Point(x: 520, y: 200))
        advance(&slow, seconds: 2, fps: 12); advance(&fast, seconds: 2, fps: 120)
        #expect(slow.snapshot.feet.distance(to: fast.snapshot.feet) < 0.000001)
        #expect(abs(slow.snapshot.pose.width - fast.snapshot.pose.width) < 0.000001)
    }
    @Test("Interrupted gestures retain their current pose")
    func poseContinuity() {
        var engine = CompanionEngine(scene: .preview)
        tap(&engine); advance(&engine, seconds: 0.2)
        let before = engine.snapshot
        engine.send(.command(.stretch))
        #expect(engine.snapshot.pose == before.pose)
        #expect(engine.snapshot.feet == before.feet)
        engine.advance(by: 1 / 120.0)
        #expect(abs(engine.snapshot.pose.height - before.pose.height) < 0.04)
    }
    @Test("Impact squish is damped and settles")
    func squish() {
        var body = BodyPhysics(scene: .preview)
        body.grab(visibleFeet: Point(x: 520, y: 200), target: Point(x: 520, y: 180), at: 0)
        body.release()
        var minCompression = 0.0
        for index in 0..<600 { body.step(1 / 120.0, at: Double(index) / 120, walkingAmount: 0); minCompression = min(minCompression, body.compression.value) }
        #expect(minCompression < -0.1)
        #expect(body.phase == .grounded && body.landingCount >= 1)
        #expect(abs(body.compression.value) < 0.001)
    }
    @Test("A stationary hold loses old throw momentum before release")
    func heldMomentum() {
        var body = BodyPhysics(scene: .preview)
        body.grab(visibleFeet: Point(x: 450, y: 200), target: Point(x: 450, y: 180), at: 0)
        body.grab(visibleFeet: body.renderedFeet, target: Point(x: 600, y: 250), at: 0.05)
        for index in 0..<240 { body.step(1 / 120.0, at: 0.05 + Double(index) / 120, walkingAmount: 0) }
        body.release()
        #expect(body.phase == .falling)
        #expect(abs(body.velocity.x) < 0.001 && abs(body.velocity.y) < 0.001)
    }
    @Test("Walking stays within the floor and returning home stops walking")
    func walkBounds() {
        var engine = CompanionEngine(scene: .preview)
        drag(&engine, to: Point(x: 620, y: 220)); advance(&engine, seconds: 3)
        engine.send(.command(.walk)); advance(&engine, seconds: 30)
        #expect(engine.snapshot.feet.x <= engine.snapshot.scene.rightLimit)
        #expect(engine.snapshot.feet.x >= engine.snapshot.scene.leftLimit)
        engine.send(.command(.returnHome)); advance(&engine, seconds: 3)
        #expect(engine.snapshot.phase == .hanging)
    }
}
