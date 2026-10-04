import Foundation
import Testing
@testable import CompanionCore

@Suite("Animation transitions") struct TransitionTests {
    @Test("Grabbing a peek, emergence or swing keeps the complete visible pose", arguments: [0.0, 0.12, 0.4, 1.0])
    func grabContinuity(age: Double) {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.activate)
        if age == 1 { engine.send(.command(.swing)) }
        advance(&engine, seconds: age, fps: 120)
        let before = engine.snapshot, pointer = before.hitBounds.center
        engine.send(.pointerPressed(pointer))
        engine.send(.pointerDragged(pointer + Point(x: 6, y: 0)))
        let after = engine.snapshot
        #expect(after.phase == .held)
        #expect(after.pose == before.pose)
        #expect(after.feet.distance(to: before.feet) < 0.000001)
        #expect(after.rotation == before.rotation && after.homeGrip == before.homeGrip)
    }

    @Test("Grabbing during emergence retains vertical motion instead of freezing it")
    func emergenceMomentum() {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.activate)
        for _ in 0..<11 { engine.advance(by: SimulationTuning.step) }
        let previousFeet = engine.snapshot.feet
        engine.advance(by: SimulationTuning.step)
        let before = engine.snapshot
        let incomingSpeed = (before.feet.y - previousFeet.y) / SimulationTuning.step
        let pointer = before.hitBounds.center
        engine.send(.pointerPressed(pointer)); engine.send(.pointerDragged(pointer + Point(x: 6, y: 0)))
        engine.advance(by: SimulationTuning.step)
        let outgoingSpeed = (engine.snapshot.feet.y - before.feet.y) / SimulationTuning.step
        #expect(incomingSpeed > 50)
        #expect(outgoingSpeed > incomingSpeed * 0.5)
    }

    @Test("The home housing stays click-through while an emerging body is grabbed")
    func occludedHitTesting() {
        var engine = CompanionEngine(scene: .preview)
        let pointer = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(pointer)); engine.send(.pointerDragged(pointer + Point(x: 6, y: 0)))
        let hidden = Point(x: engine.snapshot.feet.x, y: engine.snapshot.scene.home.maxY - 4)
        #expect(engine.snapshot.geometry.contains(hidden))
        #expect(!engine.snapshot.contains(hidden))
        #expect(engine.snapshot.contains(pointer))
    }

    @Test("A catch enters the resting peek without a visible position step")
    func catchPresentation() {
        var engine = CompanionEngine(scene: .preview)
        let pointer = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(pointer)); engine.send(.pointerDragged(pointer + Point(x: 25, y: 10)))
        advance(&engine, seconds: 0.12, fps: 120)
        engine.send(.pointerReleased(pointer))
        var settled = false
        for _ in 0..<240 {
            let before = engine.snapshot
            engine.advance(by: SimulationTuning.step)
            if before.phase == .catching && engine.snapshot.phase == .hanging {
                // Includes the first accelerated step of the return to peek.
                let movement = engine.snapshot.feet.distance(to: before.feet)
                #expect(movement < 0.4)
                #expect(abs(engine.snapshot.pose.height - before.pose.height) < 0.01)
                #expect(abs(engine.snapshot.homeGrip - before.homeGrip) < 0.01)
                settled = true
            }
        }
        #expect(settled)
    }

    @Test("An interrupted limb or squish target carries its existing velocity")
    func poseMomentum() {
        var dynamics = PoseDynamics(), target = CharacterPose()
        target.arm = 1; target.height = 1.3
        for _ in 0..<12 { dynamics.step(toward: target, dt: SimulationTuning.step) }
        let before = dynamics.pose
        dynamics.step(toward: CharacterPose(), dt: SimulationTuning.step)
        #expect(dynamics.pose.arm > before.arm)
        #expect(dynamics.pose.height > before.height)
        for _ in 0..<240 { dynamics.step(toward: CharacterPose(), dt: SimulationTuning.step) }
        #expect(abs(dynamics.pose.arm) < 0.000001)
        #expect(abs(dynamics.pose.height - 1) < 0.000001)
    }

    @Test("Silhouette area stays constant through reveal, hold, impact and return", arguments: [30.0, 120])
    func bodyVolume(fps: Double) {
        var engine = CompanionEngine(scene: .preview)
        var phases: Set<String> = []
        var largestSquish = 0.0
        func observe(_ frame: CompanionSnapshot) {
            #expect(abs(frame.pose.width * frame.pose.height - 1) < 0.000001)
            #expect(frame.pose.width > 0 && frame.pose.height > 0)
            phases.insert(frame.phase.rawValue)
            largestSquish = max(largestSquish, abs(frame.pose.height - 1))
        }
        engine.send(.activate)
        for _ in 0..<Int(fps) { engine.advance(by: 1 / fps); observe(engine.snapshot) }
        engine.send(.command(.stretch))
        for _ in 0..<Int(fps) { engine.advance(by: 1 / fps); observe(engine.snapshot) }
        let pointer = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(pointer))
        for index in 1...Int(fps) {
            engine.send(.pointerDragged(pointer + Point(x: 180, y: Double(index) / fps * 160)))
            engine.advance(by: 1 / fps); observe(engine.snapshot)
        }
        engine.send(.pointerReleased(pointer))
        for _ in 0..<Int(fps * 3) { engine.advance(by: 1 / fps); observe(engine.snapshot) }
        engine.send(.command(.returnHome))
        for _ in 0..<Int(fps * 3) { engine.advance(by: 1 / fps); observe(engine.snapshot) }
        #expect(phases == Set(["hanging", "held", "falling", "grounded", "preparingJump", "jumping", "catching"]))
        #expect(largestSquish > 0.15)
        #expect(engine.snapshot.phase == .hanging)
    }

    @Test("Release and regrab preserve body velocity, including a moving catch")
    func handoffMomentum() {
        var body = BodyPhysics(scene: .preview)
        body.grab(visibleFeet: body.position, target: body.position - Point(x: 0, y: 18 * body.scene.scale), at: 0)
        body.grab(visibleFeet: body.position, target: body.position + Point(x: 25, y: 0), at: 0.05)
        for index in 0..<6 { body.step(SimulationTuning.step, at: 0.05 + Double(index) * SimulationTuning.step, walkingAmount: 0) }
        let releaseVelocity = body.velocity
        #expect(releaseVelocity.distance(to: .zero) > 20)
        body.release()
        #expect(body.phase == .catching && body.velocity == releaseVelocity)
        body.step(SimulationTuning.step, at: 0.1, walkingAmount: 0)
        let caughtPosition = body.position, caughtVelocity = body.velocity
        body.grab(visibleFeet: caughtPosition, target: caughtPosition, at: 0.11)
        #expect(body.position == caughtPosition && body.velocity == caughtVelocity)
        body.grab(visibleFeet: body.position, target: Point(x: 600, y: 200), at: 0.12)
        body.release()
        #expect(body.phase == .falling && body.velocity == caughtVelocity)
        body.step(SimulationTuning.step, at: 0.13, walkingAmount: 0)
        let fallingVelocity = body.velocity
        body.returnHome()
        #expect(body.phase == .jumping && body.velocity == fallingVelocity)
        #expect(body.position.isFinite)
    }

    @Test("A new return flight matches incoming motion and hands off smoothly to catch")
    func flightEndpoints() {
        let trajectory = JumpTrajectory(start: Point(x: 500, y: 220), end: Point(x: 360, y: 117),
                                        launchVelocity: Point(x: -70, y: -230), arrivalVelocity: Point(x: 0, y: 70), duration: 0.7)
        #expect(trajectory.sample(at: 0).position == trajectory.start)
        #expect(trajectory.sample(at: 0).velocity == trajectory.launchVelocity)
        #expect(trajectory.sample(at: trajectory.duration).position == trajectory.end)
        #expect(trajectory.sample(at: trajectory.duration).velocity == trajectory.arrivalVelocity)
        var body = BodyPhysics(scene: .preview)
        body.grab(visibleFeet: trajectory.start, visibleVelocity: trajectory.launchVelocity,
                  target: Point(x: 500, y: 200), at: 0)
        body.returnHome()
        var settled = false
        for index in 0..<480 {
            let before = body
            body.step(SimulationTuning.step, at: Double(index) * SimulationTuning.step, walkingAmount: 0)
            if before.phase == .catching && body.phase == .hanging {
                #expect(body.position.distance(to: before.position) < 0.06)
                #expect(body.velocity.distance(to: before.velocity) < 0.6)
                settled = true
            }
        }
        #expect(settled && body.position.distance(to: body.scene.homeFeet) < 0.000001)
    }

    @Test("An interrupted fast downward flight respects the floor and still returns")
    func floorDuringReturn() {
        var body = BodyPhysics(scene: .preview)
        body.grab(visibleFeet: Point(x: 500, y: body.scene.floor - 2), visibleVelocity: Point(x: 30, y: 600),
                  target: Point(x: 500, y: 250), at: 0)
        body.returnHome()
        for index in 0..<600 {
            body.step(SimulationTuning.step, at: Double(index) * SimulationTuning.step, walkingAmount: 0)
            #expect(body.position.y <= body.scene.floor)
            #expect(body.position.isFinite && body.velocity.isFinite)
        }
        #expect(body.landingCount == 1 && body.phase == .hanging)
    }
}
