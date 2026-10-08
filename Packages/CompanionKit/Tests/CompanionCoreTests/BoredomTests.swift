import Testing
@testable import CompanionCore

@Suite("Mallow gets bored") struct BoredomTests {
    @Test("Three quiet minutes are required; interaction restarts the whole wait")
    func threshold() {
        var state = BoredomState(seed: 42)
        state.update(at: 0, quiet: true, enabled: true)
        state.update(at: 179.99, quiet: true, enabled: true)
        #expect(state.requestedMoment == nil)
        state.interrupt(at: 179.99)
        state.update(at: 180, quiet: true, enabled: true)
        state.update(at: 359.99, quiet: true, enabled: true)
        #expect(state.requestedMoment == nil)
        state.update(at: 360, quiet: true, enabled: true)
        #expect(state.requestedMoment != nil)
        #expect(state.frame == nil) // Only a command can start it.
    }
    @Test("Completion and interruption impose a full cooldown")
    func cooldown() throws {
        for interrupted in [false, true] {
            var state = BoredomState(seed: 42)
            state.update(at: 0, quiet: true, enabled: true)
            state.update(at: 180, quiet: true, enabled: true)
            let moment = try #require(state.requestedMoment)
            let began = state.begin(moment, at: 180)
            #expect(began)
            let end = interrupted ? 182 : 180 + moment.duration
            if interrupted { state.interrupt(at: end) }
            else { state.update(at: end, quiet: true, enabled: true) }
            #expect(state.frame == nil)
            state.update(at: end + 1, quiet: true, enabled: true)
            state.update(at: end + 239.99, quiet: true, enabled: true)
            #expect(state.requestedMoment == nil)
            state.update(at: end + 240, quiet: true, enabled: true)
            #expect(state.requestedMoment != nil)
        }
    }
    @Test("A stale or unsolicited command cannot override interaction")
    func staleRequest() throws {
        var state = BoredomState(seed: 0, timing: BoredomTiming(threshold: 1, cooldown: 2))
        let unsolicited = state.begin(.nap, at: 0)
        #expect(!unsolicited)
        state.update(at: 0, quiet: true, enabled: true)
        state.update(at: 1, quiet: true, enabled: true)
        let moment = try #require(state.requestedMoment)
        state.interrupt(at: 1)
        let stale = state.begin(moment, at: 1)
        #expect(!stale)
        state.update(at: 1000, quiet: true, enabled: true)
        #expect(state.requestedMoment == nil)
    }
#if DEBUG
    @Test("A debug request starts through its command and pointer attention interrupts it",
          arguments: IdleMoment.allCases)
    func debugTrigger(moment: IdleMoment) {
        var engine = CompanionEngine(scene: .preview)
        engine.requestDebugIdleMoment(moment)
        #expect(engine.requestedIdleMoment == moment)
        engine.send(.command(moment.command))
        #expect(engine.snapshot.idleMoment?.moment == moment)
        engine.send(.pointerMoved(engine.snapshot.hitBounds.center))
        #expect(engine.snapshot.idleMoment == nil)
        #expect(engine.snapshot.presence == .peek && engine.snapshot.phase == .hanging)
    }
#endif
    @Test("Energy, battery, heat and Reduce Motion gate pending and active work")
    func gating() throws {
        let blocked: [RuntimeConditions] = [
            { var c = RuntimeConditions(); c.lowPower = true; return c }(),
            { var c = RuntimeConditions(); c.onBattery = true; return c }(),
            { var c = RuntimeConditions(); c.reduceMotion = true; return c }(),
            { var c = RuntimeConditions(); c.thermal = .serious; return c }(),
            { var c = RuntimeConditions(); c.screenUnlocked = false; return c }(),
        ]
        #expect(RuntimeConditions().allowsIdleMoments)
        for conditions in blocked {
            #expect(!conditions.allowsIdleMoments)
            var state = BoredomState(seed: 42)
            state.update(at: 0, quiet: true, enabled: true)
            state.update(at: 180, quiet: true, enabled: true)
            let moment = try #require(state.requestedMoment)
            let began = state.begin(moment, at: 180)
            #expect(began)
            state.update(at: 181, quiet: true, enabled: conditions.allowsIdleMoments)
            #expect(state.frame == nil && state.requestedMoment == nil)
            state.update(at: 999, quiet: true, enabled: false)
            state.update(at: 1000, quiet: true, enabled: true)
            #expect(state.requestedMoment == nil)
        }
        var gentle = BoredomState(seed: 42)
        gentle.update(at: 0, quiet: true, enabled: true, cadence: 2)
        gentle.update(at: 359.99, quiet: true, enabled: true, cadence: 2)
        #expect(gentle.requestedMoment == nil)
        gentle.update(at: 360, quiet: true, enabled: true, cadence: 2)
        #expect(gentle.requestedMoment != nil)
    }
    @Test("Fallback visits all four moments, avoids repeats, and reproduces its seed")
    func picker() {
        for seed in [UInt64(0), 42, .max] {
            var a = IdleMomentPicker(seed: seed), b = IdleMomentPicker(seed: seed)
            let sequence = (0..<100).map { _ in a.next() }
            #expect(sequence == (0..<100).map { _ in b.next() })
            #expect(zip(sequence, sequence.dropFirst()).allSatisfy { $0 != $1 })
            for start in stride(from: 0, to: 100, by: 4) {
                #expect(Set(sequence[start..<start + 4]).count == 4)
            }
        }
    }
    @Test("Real engine keeps moments at home and accepts hover, click and drag", arguments: IdleMoment.allCases)
    func interruption(moment: IdleMoment) throws {
        // Find a seed whose first request is the desired moment.
        let seed = try #require((UInt64(0)...100).first { seed in
            var picker = IdleMomentPicker(seed: seed); return picker.next() == moment
        })
        for input in 0..<4 {
            var engine = CompanionEngine(scene: .preview, idleSeed: seed, boredomTiming: BoredomTiming(threshold: 1, cooldown: 2))
            for _ in 0..<130 { engine.advance(by: 1 / 120.0) }
            #expect(engine.requestedIdleMoment == moment)
            engine.send(.command(moment.command))
            for _ in 0..<180 { engine.advance(by: 1 / 120.0) }
            #expect(engine.snapshot.idleMoment?.moment == moment)
            #expect(engine.snapshot.presence == .peek && engine.snapshot.phase == .hanging)
            #expect(abs(engine.snapshot.feet.x - engine.snapshot.scene.homeFeet.x) <= 13 * engine.snapshot.scene.scale)
            if moment == .nap { #expect(engine.snapshot.pose.eyes < 0.12) }
            let point = engine.snapshot.hitBounds.center
            #expect(engine.snapshot.contains(point))
            switch input {
            case 0: engine.send(.pointerMoved(point))
            case 1:
                engine.send(.pointerPressed(point)); #expect(engine.hasPointerCapture)
                engine.send(.pointerReleased(point)); #expect(engine.snapshot.presence == .engaged)
            case 2:
                engine.send(.pointerPressed(point))
                let beforeGrab = engine.snapshot
                engine.send(.pointerDragged(point + Point(x: 20, y: 20)))
                #expect(engine.snapshot.feet.distance(to: beforeGrab.feet) < 0.000001)
                #expect(engine.snapshot.homeAttachment.distance(to: beforeGrab.homeAttachment) < 0.000001)
                #expect(engine.isDragging && engine.snapshot.phase == .held)
                engine.send(.pointerReleased(point + Point(x: 20, y: 20)))
                #expect(!engine.hasPointerCapture)
            default: engine.setIdleMomentsEnabled(false)
            }
            #expect(engine.snapshot.idleMoment == nil && engine.requestedIdleMoment == nil)
            for _ in 0..<60 { engine.advance(by: 1 / 120.0) }
            #expect(engine.snapshot.feet.isFinite && engine.snapshot.pose.eyes > 0.12)
        }
    }
    @Test("Deliberate commands cancel idle without changing their existing behavior", arguments: [CompanionCommand.greet, .swing, .stretch, .returnHome, .walk, .hop])
    func commands(command: CompanionCommand) throws {
        var engine = CompanionEngine(scene: .preview, boredomTiming: BoredomTiming(threshold: 1, cooldown: 2))
        for _ in 0..<130 { engine.advance(by: 1 / 120.0) }
        let moment = try #require(engine.requestedIdleMoment)
        engine.send(.command(moment.command))
        engine.send(.command(command))
        #expect(engine.snapshot.idleMoment == nil && engine.requestedIdleMoment == nil)
        for _ in 0..<60 { engine.advance(by: 1 / 120.0) }
        #expect(engine.snapshot.feet.isFinite && engine.snapshot.pose.height.isFinite)
    }
    @Test("An ignored hour stays rare, finite, and at the original home")
    func hour() {
        var engine = CompanionEngine(scene: .preview, idleSeed: 42)
        var starts = 0, activeFrames = 0, prior: IdleMoment?
        var safe = true
        for _ in 0..<3600 * 20 {
            engine.advance(by: 1 / 20.0)
            if let request = engine.requestedIdleMoment { engine.send(.command(request.command)) }
            let frame = engine.snapshot
            if frame.idleMoment != nil { activeFrames += 1 }
            if let moment = frame.idleMoment?.moment, prior == nil { starts += 1; prior = moment }
            if frame.idleMoment == nil { prior = nil }
            safe = safe && frame.phase == .hanging && frame.presence == .peek
                && frame.gesture == nil && frame.feet.isFinite
                && abs(frame.feet.x - frame.scene.homeFeet.x) <= 13 * frame.scene.scale
                && frame.openness == 0.6
        }
        #expect(safe)
        #expect((12...15).contains(starts))
        #expect(Double(activeFrames) / Double(3600 * 20) < 0.04)
    }
    @Test("Zero energy, reduced motion, recovery and capture never launch overdue moments")
    func safety() {
        var engine = CompanionEngine(scene: .preview, boredomTiming: BoredomTiming(threshold: 1, cooldown: 2))
        engine.setMovementAmount(0)
        for _ in 0..<240 { engine.advance(by: 1 / 120.0) }
        #expect(engine.requestedIdleMoment == nil)
        engine.setMovementAmount(1); engine.setMotionPolicy(.reduced)
        for _ in 0..<240 { engine.advance(by: 1 / 120.0) }
        #expect(engine.requestedIdleMoment == nil)
        engine.setMotionPolicy(.full); engine.send(.cancelInteraction)
        engine.advance(by: 0.05)
        #expect(engine.requestedIdleMoment == nil)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        for _ in 0..<240 { engine.advance(by: 1 / 120.0) }
        #expect(engine.requestedIdleMoment == nil && engine.hasPointerCapture)
    }
}
