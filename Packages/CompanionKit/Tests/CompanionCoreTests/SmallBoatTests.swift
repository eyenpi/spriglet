import Testing
@testable import CompanionCore

@Suite("Hands-only boat habit") struct SmallBoatTests {
    private func scene(form: MallowForm, scale: Double, notch: Bool) -> SceneGeometry {
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                      home: Rect(x: notch ? 260 : 490, y: notch ? 0 : 13,
                                 width: notch ? 200 : 180, height: notch ? 32 : 20),
                      floor: 365, scale: scale, hasHardwareNotch: notch, form: form)
    }
    private var boatSeed: UInt64 {
        (UInt64(0)...200).first { seed in
            var picker = IdleMomentPicker(seed: seed)
            return picker.next() == .boat(.fiddle)
        }!
    }
    private func advance(_ engine: inout CompanionEngine, seconds: Double) {
        for _ in 0..<Int(seconds * 120) {
            engine.advance(by: 1 / 120.0)
            if let request = engine.requestedIdleMoment { engine.send(.command(request.command)) }
        }
    }
    @Test("All three sizes show a boat; Small never exposes its body", arguments: [true, false], [0.35, 1.0, 1.35])
    func allSizes(notch: Bool, intensity: Double) throws {
        for (form, scale) in [(MallowForm.fingertipGrip, 0.8), (.standard, 0.8), (.standard, 1.0)] {
            let home = scene(form: form, scale: scale, notch: notch)
            var engine = CompanionEngine(scene: home, idleSeed: boatSeed,
                                         boredomTiming: BoredomTiming(threshold: 0.1, cooldown: 30))
            engine.setMovementAmount(intensity)
            advance(&engine, seconds: 0.3)
            #expect(engine.snapshot.idleMoment?.moment == .boat(.fiddle))
            for _ in 0..<7 * 120 {
                let frame = engine.snapshot
                if form == .fingertipGrip {
                    #expect(frame.homeTuck == 1 && frame.phase == .hanging)
                    let geometry = frame.geometry
                    for curve in MallowGeometry.bodyCurves {
                        for point in curve.outline {
                            #expect(geometry.root.apply(geometry.body.apply(point)).y < home.home.maxY)
                        }
                    }
                }
                advance(&engine, seconds: 1 / 120.0)
            }
            if form == .fingertipGrip {
                #expect(engine.snapshot.idleMoment == nil)
                #expect(engine.snapshot.hitBounds.height < 4)
            } else { #expect(engine.snapshot.idleMoment != nil) }
        }
    }
    @Test("Small consumes ordinary slots silently without increasing boat frequency")
    func quietAllocation() {
        func requests(form: MallowForm) -> [IdleMoment] {
            var engine = CompanionEngine(scene: scene(form: form, scale: 0.8, notch: true), idleSeed: 42,
                                         boredomTiming: BoredomTiming(threshold: 0.1, cooldown: 2))
            var result: [IdleMoment] = []
            for _ in 0..<4000 {
                engine.advance(by: 0.05)
                if let request = engine.requestedIdleMoment {
                    result.append(request); engine.send(.command(request.command))
                }
            }
            return result
        }
        let small = requests(form: .fingertipGrip), medium = requests(form: .standard)
        #expect(small.count >= 3)
        #expect(small.allSatisfy { $0 == .boat(.fiddle) })
        #expect(abs(small.count - medium.filter { $0.boatHabit != nil }.count) <= 1)
    }
    @Test("Approach during arrival or withdrawal cancels the boat before the face peeks", arguments: [0.5, 6.5])
    func interruption(age: Double) throws {
        var engine = CompanionEngine(scene: scene(form: .fingertipGrip, scale: 0.8, notch: true), idleSeed: boatSeed,
                                     boredomTiming: BoredomTiming(threshold: 0.1, cooldown: 30))
        advance(&engine, seconds: age)
        #expect(engine.snapshot.idleMoment?.moment == .boat(.fiddle))
        let hover = try #require(engine.snapshot.homeHoverBounds)
        engine.send(.pointerMoved(Point(x: hover.midX, y: hover.maxY - 2)))
        #expect(engine.snapshot.idleMoment == nil && engine.snapshot.homeTuck == 1)
        advance(&engine, seconds: 0.5)
        #expect(engine.snapshot.homeTuck < 0.01)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        advance(&engine, seconds: 2)
        #expect(engine.snapshot.homeTuck == 1 && engine.snapshot.idleMoment == nil)
    }
    @Test("A direct press on a boat-holding hand survives cancellation", arguments: [false, true], [0.0, 100.0])
    func directHandPress(drag: Bool, releaseOffset: Double) {
        var engine = CompanionEngine(scene: scene(form: .fingertipGrip, scale: 0.8, notch: true), idleSeed: boatSeed,
                                     boredomTiming: BoredomTiming(threshold: 0.1, cooldown: 30))
        advance(&engine, seconds: 3)
        let point = engine.snapshot.geometry.hands[0].palm.center
        #expect(engine.snapshot.contains(point))
        engine.send(.pointerPressed(point))
        #expect(engine.hasPointerCapture && engine.snapshot.idleMoment == nil)
        if drag {
            engine.send(.pointerDragged(point + Point(x: 20, y: 20)))
            #expect(engine.isDragging && engine.snapshot.phase == .held)
            engine.send(.cancelInteraction)
        } else {
            advance(&engine, seconds: 0.1)
            engine.send(.pointerReleased(point + Point(x: releaseOffset, y: 0)))
            #expect(engine.snapshot.presence == (releaseOffset == 0 ? .engaged : .peek))
        }
        #expect(!engine.hasPointerCapture)
    }
}
