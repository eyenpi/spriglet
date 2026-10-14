import Testing
@testable import CompanionCore

@Suite("Resting hover target") struct HomeHoverTests {
    private func scene(notch: Bool = true, form: MallowForm = .fingertipGrip) -> SceneGeometry {
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                      home: Rect(x: 260, y: notch ? 0 : 13, width: 200, height: notch ? 54 : 20),
                      floor: 365, scale: 0.8, hasHardwareNotch: notch, form: form)
    }
    private func advance(_ engine: inout CompanionEngine, seconds: Double) {
        for _ in 0..<Int(seconds * 120) { engine.advance(by: 1 / 120.0) }
    }

    @Test("The broad hover area excludes the housing and menu bar", arguments: [true, false])
    func area(notch: Bool) throws {
        let frame = CompanionEngine(scene: scene(notch: notch)).snapshot
        let target = try #require(frame.homeHoverBounds)
        #expect(target.width == (notch ? 200 : 96) && target.height == 20)
        #expect(target.midX == frame.scene.home.midX && target.minY == frame.scene.home.maxY)
        #expect(frame.containsHoverTarget(target.center) && !frame.contains(target.center))
        #expect(!frame.acceptsPress(target.center))
        #expect(!frame.containsHoverTarget(Point(x: target.midX, y: target.minY - 1)))
        #expect(!frame.containsHoverTarget(Point(x: target.maxX + 1, y: target.midY)))
        #expect(frame.hitBounds.height < 4 && frame.inputBounds.height == 20)
    }

    @Test("Empty space is click-through until a dwell arms it, including a tiny jitter", arguments: [true, false])
    func dwellAndClick(notch: Bool) throws {
        var engine = CompanionEngine(scene: scene(notch: notch))
        let region = try #require(engine.snapshot.homeHoverBounds)
        let point = Point(x: region.maxX - 4, y: region.maxY - 4)
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.2)
        #expect(!engine.snapshot.homeHoverArmed && !engine.snapshot.acceptsPress(point))
        engine.send(.pointerPressed(point)); engine.send(.pointerReleased(point))
        #expect(!engine.hasPointerCapture && engine.snapshot.presence == .peek)
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.4)
        #expect(engine.snapshot.homeHoverArmed && engine.snapshot.acceptsPress(point))
        #expect(engine.snapshot.hitBounds.height < 4 && engine.snapshot.openness == 0.6)
        engine.send(.pointerPressed(point)); #expect(engine.hasPointerCapture)
        engine.send(.pointerDragged(point + Point(x: 1, y: 1)))
        engine.send(.pointerReleased(point + Point(x: 1, y: 1)))
        #expect(engine.snapshot.presence == .engaged && !engine.hasPointerCapture)
        #expect(engine.snapshot.homeHoverBounds == nil)
    }

    @Test("Leaving clears readiness immediately, even if reentering before another tick")
    func leaveAndRecovery() throws {
        var engine = CompanionEngine(scene: scene())
        let point = try #require(engine.snapshot.homeHoverBounds).center
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.4)
        #expect(engine.snapshot.homeHoverArmed)
        engine.send(.pointerMoved(Point(x: point.x, y: point.y + 50)))
        #expect(!engine.snapshot.homeHoverArmed)
        engine.send(.pointerMoved(point))
        #expect(!engine.snapshot.acceptsPress(point))
        advance(&engine, seconds: 0.4)
        engine.send(.cancelInteraction)
        #expect(!engine.snapshot.homeHoverArmed && !engine.snapshot.acceptsPress(point))
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.4)
        engine.reconfigure(scene: scene(notch: false))
        #expect(!engine.snapshot.homeHoverArmed)
    }

    @Test("A drag from the armed area retains capture after leaving it")
    func drag() throws {
        var engine = CompanionEngine(scene: scene())
        let point = try #require(engine.snapshot.homeHoverBounds).center
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.4)
        engine.send(.pointerPressed(point)); engine.send(.pointerDragged(point + Point(x: 80, y: 100)))
        #expect(engine.isDragging && engine.hasPointerCapture && engine.snapshot.homeHoverBounds == nil)
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.fingertipGrip < 0.001)
        engine.send(.pointerReleased(point + Point(x: 80, y: 100)))
        #expect(!engine.hasPointerCapture)
    }

    @Test("Reduce Motion keeps the larger interaction area without animating a squeeze")
    func reducedMotion() throws {
        var engine = CompanionEngine(scene: scene(notch: false))
        engine.setMotionPolicy(.reduced)
        let point = try #require(engine.snapshot.homeHoverBounds).center
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.4)
        #expect(engine.snapshot.homeHoverArmed && engine.snapshot.gripSqueeze == 0)
        engine.send(.pointerPressed(point)); engine.send(.pointerReleased(point))
        #expect(engine.snapshot.presence == .engaged && engine.snapshot.fingertipGrip == 0)
    }

    @Test("Medium preserves its silhouette-only input contract")
    func standardUnchanged() {
        var engine = CompanionEngine(scene: scene(form: .standard))
        #expect(engine.snapshot.homeHoverBounds == nil && engine.snapshot.inputBounds == engine.snapshot.hitBounds)
        let point = Point(x: engine.snapshot.scene.home.maxX - 4, y: engine.snapshot.scene.home.maxY + 16)
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 1)
        #expect(!engine.snapshot.acceptsPress(point) && engine.snapshot.openness == 0.6)
        engine.send(.pointerPressed(point)); #expect(!engine.hasPointerCapture)
    }

    @Test("Activation targets stay inside narrow displays")
    func smallDisplay() throws {
        let narrow = SceneGeometry(bounds: Rect(x: -10, y: 0, width: 60, height: 120),
                                   home: Rect(x: -8, y: 0, width: 56, height: 32),
                                   floor: 110, scale: 0.8, hasHardwareNotch: false, form: .fingertipGrip)
        let bounds = try #require(CompanionEngine(scene: narrow).snapshot.homeHoverBounds)
        #expect(bounds.minX >= narrow.bounds.minX && bounds.maxX <= narrow.bounds.maxX)
        #expect(bounds.maxY <= narrow.bounds.maxY)
    }
}
