import Foundation
import Testing
@testable import CompanionCore

@Suite("Side-wall impact squash") struct SideWallSquishTests {
    private func scene(scale: Double) -> SceneGeometry {
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720 * scale, height: 420 * scale),
                      home: Rect(x: 260 * scale, y: 0, width: 200 * scale, height: 54 * scale),
                      floor: 365 * scale, scale: scale)
    }

    private func wallImpact(side: Double, normalizedSpeed: Double, scale: Double) -> BodyPhysics {
        var body = BodyPhysics(scene: scene(scale: scale))
        let wall = side < 0 ? body.scene.leftLimit : body.scene.rightLimit
        let feet = Point(x: wall - side * 0.001 * scale, y: body.scene.floor - 80 * scale)
        body.grab(visibleFeet: feet, visibleVelocity: Point(x: side * normalizedSpeed * scale, y: 0),
                  target: Point(x: wall + side * 100 * scale, y: feet.y), at: 0)
        return body
    }

    @Test("An outward wall impact narrows the body and recovers")
    func outwardImpactSquashesAndRecovers() {
        var impacted = wallImpact(side: 1, normalizedSpeed: 450 / 1.05, scale: 1.05)
        var control = BodyPhysics(scene: impacted.scene)
        let wall = impacted.scene.rightLimit, y = impacted.scene.floor - 80 * impacted.scene.scale
        control.grab(visibleFeet: Point(x: wall - 0.001, y: y), target: Point(x: wall + 100, y: y), at: 0)
        var narrowestWidth = 1.0
        for index in 0..<180 {
            let time = Double(index) / 120
            impacted.step(1 / 120, at: time, walkingAmount: 0)
            control.step(1 / 120, at: time, walkingAmount: 0)
            let width = 1 / (1 + max(-0.38, min(0.2, impacted.compression.value)))
            narrowestWidth = min(narrowestWidth, width)
        }
        let controlWidth = 1 / (1 + max(-0.38, min(0.2, control.compression.value)))
        #expect(narrowestWidth < controlWidth - 0.01)
        #expect(abs(impacted.compression.value) < 0.01)
    }

    @Test("Both walls squash on slow and fast crossings at scene scales", arguments: [
        (side: -1.0, speed: 2.2, scale: 0.8), (side: 1.0, speed: 2.2, scale: 1.0),
        (side: -1.0, speed: 560.0, scale: 1.2), (side: 1.0, speed: 560.0, scale: 0.8),
        (side: -1.0, speed: 560.0, scale: 1.0), (side: 1.0, speed: 2.2, scale: 1.2)
    ])
    func bothWallsAndSpeeds(side: Double, speed: Double, scale: Double) {
        var body = wallImpact(side: side, normalizedSpeed: speed, scale: scale)
        for index in 0..<8 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        #expect(body.compression.value > 0.01)
        let height = 1 + min(0.2, body.compression.value)
        let width = 1 / height
        #expect(width < 0.99 && height > 1)
        #expect(abs(width * height - 1) < 1e-12)
        #expect(body.position.x >= body.scene.leftLimit && body.position.x <= body.scene.rightLimit)
        #expect(body.position.y >= body.scene.ceiling && body.position.y <= body.scene.floor)
    }

    @Test("A target clamped to the wall does not squash without feet crossing")
    func targetOnlyDoesNotSquash() {
        var body = BodyPhysics(scene: .preview)
        let wall = body.scene.rightLimit, y = body.scene.floor - 80
        body.grab(visibleFeet: Point(x: wall - 15, y: y), target: Point(x: wall + 500, y: y), at: 0)
        for index in 0..<240 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        #expect(body.compression.value == 0)
    }

    @Test("Resting contact does not repeat until the body moves inward and reimpacts")
    func restingLatchAndReimpact() {
        var body = wallImpact(side: 1, normalizedSpeed: 300, scale: 1.05)
        for index in 0..<120 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        for index in 120..<480 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        #expect(body.compression.value < 0.01)
        #expect(abs(body.compression.speed) < 0.2)

        let inward = body.scene.rightLimit - 8 * body.scene.scale
        body.release()
        body.grab(visibleFeet: Point(x: inward, y: body.scene.floor - 80),
                  visibleVelocity: .zero, target: Point(x: inward, y: body.scene.floor - 80), at: 4)
        for index in 480..<510 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        body.release()
        body.grab(visibleFeet: Point(x: body.scene.rightLimit - 0.001, y: body.scene.floor - 80),
                  visibleVelocity: Point(x: 350, y: 0),
                  target: Point(x: body.scene.rightLimit + 200, y: body.scene.floor - 80), at: 4.25)
        for index in 510..<530 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        #expect(body.compression.value > 0.01)
    }

    @Test("Large finite held motion stays bounded and compression remains finite")
    func boundedLargeMotion() {
        var body = wallImpact(side: -1, normalizedSpeed: 1e9, scale: 1.2)
        for index in 0..<120 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        #expect(body.position.x == body.scene.leftLimit)
        #expect(body.compression.value.isFinite && body.compression.speed.isFinite)
        #expect(body.compression.value <= 0.2)
        #expect(body.position.y.isFinite && body.position.y >= body.scene.ceiling && body.position.y <= body.scene.floor)
    }

    @Test("A floor impact wins when a free body reaches the wall corner in one step")
    func verticalCornerPriority() {
        var body = BodyPhysics(scene: .preview)
        let feet = Point(x: body.scene.rightLimit - 0.001, y: body.scene.floor - 0.001)
        body.grab(visibleFeet: feet, visibleVelocity: Point(x: 5_000, y: 500), target: feet, at: 0)
        body.release()
        body.step(1 / 120, at: 1 / 120, walkingAmount: 0)
        #expect(body.position.x == body.scene.rightLimit)
        #expect(body.position.y == body.scene.floor)
        #expect(body.compression.speed < 0)
    }

    @Test("The same 240 fixed steps produce the same wall response in batches")
    func deterministicWallResponse() {
        var at30 = wallImpact(side: -1, normalizedSpeed: 480, scale: 1.05)
        var at120 = at30
        for frame in 0..<60 {
            for substep in 0..<4 {
                let tick = frame * 4 + substep
                at30.step(1 / 120, at: Double(tick + 1) / 120, walkingAmount: 0)
            }
        }
        for tick in 0..<240 { at120.step(1 / 120, at: Double(tick) / 120, walkingAmount: 0) }
        #expect(at30.position.distance(to: at120.position) < 1e-12)
        #expect(abs(at30.compression.value - at120.compression.value) < 1e-12)
        #expect(abs(at30.compression.speed - at120.compression.speed) < 1e-12)
    }

    @Test("Switching impact axes preserves the current deformation and removes opposing spring speed")
    func axisSwitch() {
        var body = wallImpact(side: 1, normalizedSpeed: 450, scale: 1.05)
        for index in 0..<8 { body.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        #expect(body.compression.value > 0)

        body.release()
        let floorFeet = Point(x: body.scene.homeFeet.x, y: body.scene.floor - 0.001)
        body.grab(visibleFeet: floorFeet, visibleVelocity: Point(x: 0, y: 500), target: floorFeet, at: 0.1)
        body.release()
        body.step(1 / 120, at: 0.11, walkingAmount: 0)
        #expect(body.compression.value > 0)
        #expect(body.compression.speed < 0)

        let nearWall = Point(x: body.scene.rightLimit - 0.001, y: body.scene.floor - 80)
        body.grab(visibleFeet: nearWall, visibleVelocity: Point(x: 350, y: 0),
                  target: Point(x: body.scene.rightLimit + 100, y: nearWall.y), at: 0.12)
        body.step(1 / 120, at: 0.13, walkingAmount: 0)
        #expect(body.compression.value > 0)
        #expect(body.compression.speed > 0)
    }

    @Test("Squash keeps recovering through held, catch, jump and return transitions")
    func phaseInterruptions() {
        var caught = wallImpact(side: -1, normalizedSpeed: 450, scale: 1.05)
        for index in 0..<8 { caught.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        let heldValue = caught.compression.value
        caught.release()
        #expect(caught.phase == .falling && caught.compression.value > 0)
        let catchFeet = Point(x: caught.scene.home.midX, y: caught.scene.homeFeet.y + 20 * caught.scene.scale)
        caught.grab(visibleFeet: catchFeet, visibleVelocity: .zero, target: catchFeet, at: 0.1)
        #expect(caught.canCatch)
        caught.release()
        #expect(caught.phase == .catching && caught.compression.value > 0)
        let catchingValue = caught.compression.value
        caught.returnHome(immediately: true)
        #expect(caught.phase == .hanging && caught.compression.value > 0)
        caught.step(1 / 120, at: 0.11, walkingAmount: 0)
        #expect(caught.compression.value != catchingValue)
        #expect(caught.compression.value > 0)

        var returning = wallImpact(side: 1, normalizedSpeed: 450, scale: 1.05)
        for index in 0..<8 { returning.step(1 / 120, at: Double(index) / 120, walkingAmount: 0) }
        returning.release(); returning.returnHome()
        #expect(returning.phase == .jumping && returning.compression.value > 0)
        returning.returnHome(immediately: true)
        #expect(returning.phase == .hanging && returning.compression.value > 0)
        returning.step(1 / 120, at: 0.11, walkingAmount: 0)
        #expect(returning.compression.value > 0)
        #expect(returning.compression.value != heldValue)
    }
}
