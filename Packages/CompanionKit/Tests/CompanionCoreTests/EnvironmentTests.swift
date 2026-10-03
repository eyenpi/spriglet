import Testing
@testable import CompanionCore

@Suite("Platform boundaries") struct EnvironmentTests {
    @Test("Window translation aligns the clip with the housing on any display", arguments: [
        Rect(x: 0, y: 0, width: 1512, height: 982),
        Rect(x: -1800, y: -600, width: 1800, height: 1200),
        Rect(x: 1512, y: 100, width: 1920, height: 1080),
    ])
    func windowCoordinates(display: Rect) {
        let feet = Point(x: display.width / 2, y: 92)
        let desired = WindowGeometry.desiredOrigin(feet: feet, display: display)
        // Exercise actual-frame compensation when the OS moves the panel.
        let actual = Rect(x: desired.x + 11, y: desired.y - 7, width: WindowGeometry.width, height: WindowGeometry.height)
        let origin = WindowGeometry.drawingOrigin(window: actual, display: display)
        #expect(abs(actual.maxY - (32 + origin.y) - (display.maxY - 32)) < 0.001)
        let global = Point(x: display.minX + feet.x, y: display.maxY - feet.y)
        #expect(WindowGeometry.scenePoint(global: global, display: display) == feet)
    }
    @Test("Sleep, session lock and critical heat suspend animation")
    func suspension() {
        var policy = RuntimeConditions()
        #expect(policy.maximumFrameRate == 60)
        policy.displayAwake = false; #expect(policy.maximumFrameRate == 0)
        policy.displayAwake = true; policy.sessionActive = false; #expect(policy.maximumFrameRate == 0)
        policy.sessionActive = true; policy.thermal = .critical; #expect(policy.maximumFrameRate == 0)
        policy.thermal = .serious; #expect(policy.maximumFrameRate == 15)
        policy.thermal = .normal; policy.lowPower = true; #expect(policy.maximumFrameRate == 30)
    }
    @Test("Reduce Motion keeps the face alive and returns without a flight")
    func reducedMotion() {
        var engine = CompanionEngine(scene: .preview)
        engine.setMotionPolicy(.reduced)
        tap(&engine); advance(&engine, seconds: 1)
        #expect(engine.snapshot.rotation == 0 && engine.snapshot.pose.lean == 0)
        #expect(engine.snapshot.pose.width == 1 && engine.snapshot.pose.height == 1)
        drag(&engine, to: Point(x: 520, y: 200)); advance(&engine, seconds: 3)
        engine.send(.command(.returnHome))
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
        var didBlink = false
        for _ in 0..<1200 { engine.advance(by: 1 / 120.0); didBlink = didBlink || engine.snapshot.pose.eyes < 0.1 }
        #expect(didBlink)
    }
    @Test("A display change cancels pointer capture and reanchors the face")
    func displayChange() {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center)); engine.send(.pointerDragged(Point(x: 500, y: 200)))
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1000, height: 800), home: Rect(x: 850, y: 28, width: 140, height: 20), floor: 750, hasHardwareNotch: false)
        engine.reconfigure(scene: scene)
        #expect(!engine.hasPointerCapture && engine.snapshot.phase == .hanging)
        #expect(engine.snapshot.presence == .peek && engine.snapshot.scene == scene)
    }
    @Test("Suspending during a grab cancels capture and leaves a safe home state")
    func cancelOnSuspend() {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 520, y: 200)))
        engine.send(.cancelInteraction)
        #expect(!engine.hasPointerCapture && engine.snapshot.phase == .hanging)
        #expect(engine.snapshot.presence == .peek)
    }
    @Test("Quiet presence reduces redraws without stopping animation")
    func restingCadence() {
        var conditions = RuntimeConditions()
        #expect(conditions.frameRate(presence: .peek, phase: .hanging) == 30)
        #expect(conditions.frameRate(presence: .engaged, phase: .hanging) == 60)
        #expect(conditions.frameRate(presence: .playing, phase: .grounded) == 30)
        conditions.displayAwake = false
        #expect(conditions.frameRate(presence: .playing, phase: .held) == 0)
    }
    @Test("Every command is bounded when delivered while playing or at home", arguments: CompanionCommand.allCases)
    func commandBoundary(command: CompanionCommand) {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.command(command)); advance(&engine, seconds: 8)
        #expect(engine.snapshot.feet.isFinite && engine.snapshot.pose.width.isFinite)
        drag(&engine, to: Point(x: 520, y: 200)); advance(&engine, seconds: 3)
        engine.send(.command(command)); advance(&engine, seconds: 8)
        #expect(engine.snapshot.feet.isFinite && engine.snapshot.pose.height > 0)
    }
}
