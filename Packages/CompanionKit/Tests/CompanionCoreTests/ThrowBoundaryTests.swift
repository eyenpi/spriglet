import Foundation
import Testing
@testable import CompanionCore

private enum UpwardThrowRoute: CaseIterable { case falling, catching, returning }

@Suite("Throw boundaries") struct ThrowBoundaryTests {
    @Test("A rapid upward release or return stays reachable and settles", arguments: [200.0, 300], [false, true])
    func rapidUpwardRelease(drop: Double, returnImmediately: Bool) {
        var engine = CompanionEngine(scene: .preview)
        let pointer = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(pointer))
        engine.send(.pointerDragged(pointer + Point(x: 180, y: drop)))
        for _ in 0..<120 { engine.advance(by: SimulationTuning.step) }
        engine.send(.pointerDragged(pointer + Point(x: 180, y: -70)))
        for _ in 0..<6 { engine.advance(by: SimulationTuning.step) }
        let before = engine.snapshot
        engine.send(.pointerReleased(pointer))
        #expect(engine.snapshot.phase == .falling)
        #expect(engine.snapshot.feet == before.feet && engine.snapshot.pose == before.pose)
        if returnImmediately { engine.send(.command(.returnHome)) }
        var minimumY = before.feet.y
        var unreachableFrames = 0
        for _ in 0..<600 {
            engine.advance(by: SimulationTuning.step)
            let frame = engine.snapshot
            minimumY = min(minimumY, frame.feet.y)
            let visibleBody = Point(x: frame.feet.x, y: frame.feet.y - 4 * frame.scene.scale)
            if !frame.scene.bounds.contains(visibleBody) || !frame.contains(visibleBody) { unreachableFrames += 1 }
        }
        #expect(minimumY >= 60 * engine.snapshot.scene.scale)
        #expect(unreachableFrames == 0)
        #expect(engine.snapshot.phase == (returnImmediately ? .hanging : .grounded))
        engine.send(.command(.returnHome))
        advance(&engine, seconds: 3)
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
    }

    @Test("Catch and return interruptions also respect scene bounds", arguments: UpwardThrowRoute.allCases, [false, true])
    fileprivate func interruptedThrow(route: UpwardThrowRoute, nativeScene: Bool) {
        let scene = nativeScene ? SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1512, height: 982),
                                                home: Rect(x: 663.5, y: 0, width: 185, height: 32), floor: 898) : .preview
        var engine = CompanionEngine(scene: scene)
        let pointer = engine.snapshot.hitBounds.center
        let horizontal = route == .catching ? 0.0 : 180.0
        engine.send(.pointerPressed(pointer))
        engine.send(.pointerDragged(pointer + Point(x: horizontal, y: scene.floor)))
        for _ in 0..<120 { engine.advance(by: SimulationTuning.step) }
        engine.send(.pointerDragged(pointer + Point(x: horizontal, y: -10)))
        for _ in 0..<6 { engine.advance(by: SimulationTuning.step) }
        engine.send(.pointerReleased(pointer))
        #expect(engine.snapshot.phase == (route == .catching ? .catching : .falling))
        if route == .returning { engine.send(.command(.returnHome)) }
        var outsideFrames = 0
        var minimumY = engine.snapshot.feet.y
        for _ in 0..<600 {
            engine.advance(by: SimulationTuning.step)
            let feet = engine.snapshot.feet
            minimumY = min(minimumY, feet.y)
            if !feet.isFinite || feet.y < scene.bounds.minY || feet.y > scene.floor + 0.000001
                || feet.x < scene.leftLimit - 0.000001 || feet.x > scene.rightLimit + 0.000001 { outsideFrames += 1 }
        }
        #expect(outsideFrames == 0)
        #expect(minimumY >= scene.bounds.minY + 60 * scene.scale)
        #expect(engine.snapshot.phase == (route == .falling ? .grounded : .hanging))
    }

    @Test("A return during a horizontal reversal stays inside either edge", arguments: [-1.0, 1])
    func horizontalReturn(direction: Double) {
        var engine = CompanionEngine(scene: .preview)
        let pointer = engine.snapshot.hitBounds.center, scene = engine.snapshot.scene
        engine.send(.pointerPressed(pointer))
        engine.send(.pointerDragged(pointer + Point(x: direction * 300, y: 150)))
        for _ in 0..<120 { engine.advance(by: SimulationTuning.step) }
        engine.send(.pointerDragged(pointer + Point(x: -direction * 300, y: 150)))
        for _ in 0..<9 { engine.advance(by: SimulationTuning.step) }
        let before = engine.snapshot
        engine.send(.command(.returnHome))
        #expect(engine.snapshot.phase == .jumping && !engine.hasPointerCapture)
        #expect(engine.snapshot.feet == before.feet && engine.snapshot.pose == before.pose)
        var minimumX = before.feet.x, maximumX = before.feet.x
        for _ in 0..<600 {
            engine.advance(by: SimulationTuning.step)
            minimumX = min(minimumX, engine.snapshot.feet.x)
            maximumX = max(maximumX, engine.snapshot.feet.x)
        }
        #expect(minimumX >= scene.leftLimit - 0.000001)
        #expect(maximumX <= scene.rightLimit + 0.000001)
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
    }
}
