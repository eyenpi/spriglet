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
    @Test("Wake and unlock cannot override another suspension reason")
    func independentSuspensionReasons() {
        var policy = RuntimeConditions()
        policy.systemAwake = false; policy.displayAwake = false
        policy.screenUnlocked = false; policy.sessionActive = false
        policy.systemAwake = true
        #expect(policy.isSuspended)
        policy.displayAwake = true
        #expect(policy.isSuspended)
        policy.screenUnlocked = true
        #expect(policy.isSuspended)
        policy.sessionActive = true
        #expect(!policy.isSuspended)
        policy.thermal = .critical; policy.screenUnlocked = false
        policy.screenUnlocked = true
        #expect(policy.isSuspended)
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
        #expect(abs(engine.snapshot.feet.x - engine.snapshot.scene.homeFeet.x) < 0.000001)
        #expect(engine.snapshot.feet.y <= engine.snapshot.scene.homeFeet.y)
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
    @Test("Interrupted swing recovery clears deformation, gesture and hover")
    func cleanRecovery() {
        var engine = CompanionEngine(scene: .preview)
        tap(&engine); advance(&engine, seconds: 1)
        tap(&engine); advance(&engine, seconds: 0.1)
        #expect(engine.snapshot.rotation != 0)
        engine.send(.pointerMoved(engine.snapshot.hitBounds.center))
        let time = engine.time
        engine.send(.cancelInteraction)
        let resting = CompanionEngine(scene: .preview).snapshot
        #expect(engine.time == time)
        #expect(engine.snapshot.openness == 0.6 && engine.snapshot.gesture == nil)
        #expect(engine.snapshot.rotation == 0 && engine.snapshot.pose == resting.pose)
        #expect(engine.snapshot.feet == resting.feet)
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.openness == 0.6)
    }
    @Test("Unplug or resize during a grab discards stale drag and release events", arguments: [
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1024, height: 768),
                      home: Rect(x: 794, y: 4, width: 180, height: 20), floor: 720, hasHardwareNotch: false),
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1280, height: 800),
                      home: Rect(x: 545, y: 0, width: 190, height: 32), floor: 750),
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 3440, height: 1440),
                      home: Rect(x: 3210, y: 4, width: 180, height: 20), floor: 1380, hasHardwareNotch: false),
    ])
    func interruptedDisplayChange(scene: SceneGeometry) {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 500, y: 250)))
        advance(&engine, seconds: 0.5)
        #expect(engine.snapshot.phase == .held && engine.hasPointerCapture)
        engine.reconfigure(scene: scene)
        engine.send(.pointerDragged(Point(x: 650, y: 300)))
        engine.send(.pointerReleased(scene.homeFeet))
        #expect(!engine.hasPointerCapture && !engine.isDragging)
        #expect(engine.snapshot.windowAnchor == scene.homeFeet)
        #expect(engine.snapshot.phase == .hanging && engine.snapshot.presence == .peek)
        #expect(engine.snapshot.openness == 0.6 && engine.snapshot.rotation == 0)
        // A fresh interaction still works after recovery.
        tap(&engine)
        #expect(engine.snapshot.presence == .engaged && !engine.hasPointerCapture)
    }
    @Test("Quiet presence reduces redraws without stopping animation")
    func restingCadence() {
        var conditions = RuntimeConditions()
        #expect(conditions.frameRate(presence: .peek, phase: .hanging) == 20)
        #expect(conditions.frameRate(presence: .engaged, phase: .hanging) == 60)
        #expect(conditions.frameRate(presence: .playing, phase: .grounded) == 30)
        #expect(conditions.frameRate(presence: .peek, phase: .falling) == 60)
        #expect(conditions.frameRate(presence: .peek, phase: .held) == 60)
        conditions.lowPower = true
        #expect(conditions.frameRate(presence: .peek, phase: .hanging) == 15)
        #expect(conditions.frameRate(presence: .engaged, phase: .hanging) == 30)
        #expect(conditions.frameRate(presence: .playing, phase: .falling) == 30)
        conditions.thermal = .serious
        #expect(conditions.frameRate(presence: .engaged, phase: .hanging) == 15)
        conditions.displayAwake = false
        #expect(conditions.frameRate(presence: .playing, phase: .held) == 0)
    }
    @Test("Idle cadence preserves visible blinks and the breathing range", arguments: [15.0, 20.0], [0.0, 1 / 120.0, 1 / 60.0, 1 / 30.0, 1 / 24.0])
    func idleExpression(fps: Double, offset: Double) {
        var engine = CompanionEngine(scene: .preview)
        engine.advance(by: offset)
        var closedFrames = 0, minimumHeight = Double.infinity, maximumHeight = 0.0
        for _ in 0..<Int(fps * 90) {
            engine.advance(by: 1 / fps)
            let pose = engine.snapshot.pose
            if pose.eyes < 0.12 { closedFrames += 1 }
            minimumHeight = min(minimumHeight, pose.height)
            maximumHeight = max(maximumHeight, pose.height)
        }
        #expect(closedFrames >= 15)
        // Gentler breathing remains visible at both resting cadences, without
        // requiring the larger fixed-amplitude motion of the original idle.
        #expect((0.018...0.04).contains(maximumHeight - minimumHeight))
        #expect(engine.snapshot.hitBounds.height > 25)
    }
    @Test("Low Power Mode preserves gesture, swing and return timing")
    func lowPowerFeel() {
        var normal = CompanionEngine(scene: .preview), lowPower = normal
        var conditions = RuntimeConditions(); conditions.lowPower = true
        for command in [CompanionCommand.greet, .swing, .stretch, .returnHome] {
            normal.send(.command(command)); lowPower.send(.command(command))
            // Supply the same semantic input and compare every half second, not
            // just final resting states where a timing error could be hidden.
            for _ in 0..<8 {
                let referenceRate = RuntimeConditions().frameRate(presence: normal.snapshot.presence, phase: normal.snapshot.phase)
                let lowPowerRate = conditions.frameRate(presence: lowPower.snapshot.presence, phase: lowPower.snapshot.phase)
                advance(&normal, seconds: 0.5, fps: Double(referenceRate))
                // Fifteen fps cannot divide half a second; use elapsed chunks
                // that still finish at exactly the comparison time.
                var remaining = 0.5
                while remaining > 0.000001 {
                    let step = min(remaining, 1 / Double(lowPowerRate))
                    lowPower.advance(by: step); remaining -= step
                }
                #expect(abs(normal.time - lowPower.time) < 0.000001)
                #expect(normal.snapshot.phase == lowPower.snapshot.phase)
                #expect(normal.snapshot.gesture == lowPower.snapshot.gesture)
                #expect(normal.snapshot.feet.distance(to: lowPower.snapshot.feet) < 0.000001)
                #expect(abs(normal.snapshot.rotation - lowPower.snapshot.rotation) < 0.000001)
                #expect(abs(normal.snapshot.pose.arm - lowPower.snapshot.pose.arm) < 0.000001)
                #expect(abs(normal.snapshot.pose.height - lowPower.snapshot.pose.height) < 0.000001)
            }
        }
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
