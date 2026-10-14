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
        #expect(!frame.contains(target.center))
        #expect(!frame.containsHoverTarget(Point(x: target.midX, y: target.minY - 1)))
        #expect(!frame.containsHoverTarget(Point(x: target.maxX + 1, y: target.midY)))
        #expect(frame.hitBounds.height < 4 && frame.inputBounds.height == 20)
    }

    @Test("Hover starts peeking on the first step, and only the visible face can be clicked", arguments: [true, false])
    func immediatePeek(notch: Bool) throws {
        var engine = CompanionEngine(scene: scene(notch: notch))
        let region = try #require(engine.snapshot.homeHoverBounds)
        let empty = Point(x: region.maxX - 4, y: region.maxY - 4)
        engine.send(.pointerMoved(empty)); engine.advance(by: 1 / 120.0)
        #expect(engine.snapshot.homeTuck < 1 && engine.snapshot.isHomeTransitioning)
        advance(&engine, seconds: 0.6)
        #expect(engine.snapshot.homeTuck == 0 && !engine.snapshot.isHomeTransitioning)
        #expect(engine.snapshot.hitBounds.height > 24 && engine.snapshot.presence == .peek)
        let corner = Point(x: engine.snapshot.hitBounds.minX + 1, y: engine.snapshot.hitBounds.maxY - 1)
        #expect(!engine.snapshot.contains(corner))
        let face = engine.snapshot.hitBounds.center
        #expect(engine.snapshot.contains(face))
        engine.send(.pointerMoved(face)); engine.send(.pointerPressed(face)); engine.send(.pointerReleased(face))
        #expect(engine.snapshot.presence == .engaged && !engine.hasPointerCapture)
        #expect(engine.snapshot.homeHoverBounds == nil)
    }

    @Test("Leaving retucks smoothly, reentry reverses smoothly, and recovery restores fingertips")
    func leaveAndRecovery() throws {
        var engine = CompanionEngine(scene: scene())
        let point = try #require(engine.snapshot.homeHoverBounds).center
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.6)
        #expect(engine.snapshot.homeTuck == 0)
        engine.send(.pointerMoved(Point(x: point.x, y: point.y + 80)))
        engine.advance(by: 1 / 120.0)
        let retreat = engine.snapshot
        #expect(retreat.homeTuck > 0 && retreat.homeTuck < 1)
        engine.send(.pointerMoved(point)); engine.advance(by: 1 / 120.0)
        #expect(engine.snapshot.feet.distance(to: retreat.feet) < 3)
        advance(&engine, seconds: 0.6)
        #expect(engine.snapshot.homeTuck == 0)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000))); advance(&engine, seconds: 0.6)
        #expect(engine.snapshot.homeTuck == 1 && engine.snapshot.hitBounds.height < 4)
        engine.send(.cancelInteraction)
        #expect(engine.snapshot.homeTuck == 1)
        engine.reconfigure(scene: scene(notch: false))
        #expect(engine.snapshot.homeTuck == 1)
    }

    @Test("A drag from the visible peek retains capture after leaving home")
    func drag() throws {
        var engine = CompanionEngine(scene: scene())
        let point = try #require(engine.snapshot.homeHoverBounds).center
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.6)
        let face = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(face)); engine.send(.pointerDragged(face + Point(x: 80, y: 100)))
        #expect(engine.isDragging && engine.hasPointerCapture && engine.snapshot.homeHoverBounds == nil)
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.fingertipGrip == 0)
        engine.send(.pointerReleased(face + Point(x: 80, y: 100)))
        #expect(!engine.hasPointerCapture)
    }

    @Test("Reduce Motion reveals the intact face immediately and retucks without animation")
    func reducedMotion() throws {
        var engine = CompanionEngine(scene: scene(notch: false))
        engine.setMotionPolicy(.reduced)
        let point = try #require(engine.snapshot.homeHoverBounds).center
        engine.send(.pointerMoved(point)); engine.advance(by: 1 / 120.0)
        #expect(engine.snapshot.homeTuck == 0 && !engine.snapshot.isHomeTransitioning)
        let face = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(face)); engine.send(.pointerReleased(face))
        #expect(engine.snapshot.presence == .engaged && engine.snapshot.fingertipGrip == 0)
        engine.send(.outsidePressed); engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        engine.advance(by: 1 / 120.0)
        #expect(engine.snapshot.homeTuck == 1 && engine.snapshot.hitBounds.height < 4)
    }

    @Test("Medium preserves its silhouette-only input contract")
    func standardUnchanged() {
        var engine = CompanionEngine(scene: scene(form: .standard))
        #expect(engine.snapshot.homeHoverBounds == nil && engine.snapshot.inputBounds == engine.snapshot.hitBounds)
        let point = Point(x: engine.snapshot.scene.home.maxX - 4, y: engine.snapshot.scene.home.maxY + 16)
        engine.send(.pointerMoved(point)); advance(&engine, seconds: 1)
        #expect(!engine.snapshot.contains(point) && engine.snapshot.openness == 0.6)
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
