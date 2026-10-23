import Testing
@testable import CompanionCore

@Suite("Familiar boat habits") struct LittleHabitsTests {
    @Test("Three boat habits share one of five idle selections without adjacent boat visits")
    func sharedAllocation() {
        for seed in [UInt64(0), 42, .max] {
            var picker = IdleMomentPicker(seed: seed)
            let moments = (0..<150).map { _ in picker.next() }
            for start in stride(from: 0, to: 150, by: 5) {
                let cycle = moments[start..<start + 5]
                #expect(cycle.filter { $0.boatHabit != nil }.count == 1)
                #expect(Set(cycle.filter { $0.boatHabit == nil }) == Set([.wander, .nap, .doodle, .fidget]))
            }
            #expect(zip(moments, moments.dropFirst()).allSatisfy { $0.boatHabit == nil || $1.boatHabit == nil })
            #expect(Set(moments.compactMap(\.boatHabit)) == Set([.admire, .fiddle, .doze]))
        }
    }
    @Test("Interruption needs a fresh quiet interval; absence cannot queue or replay a habit")
    func eligibilityAndAbsence() throws {
        var state = BoredomState(seed: 42)
        state.update(at: 0, quiet: true, enabled: true)
        state.update(at: 170, quiet: true, enabled: true)
        state.interrupt(at: 170)
        state.update(at: 170, quiet: true, enabled: true)
        state.update(at: 349, quiet: true, enabled: true)
        #expect(state.requestedMoment == nil)
        state.update(at: 350, quiet: true, enabled: true)
        let moment = try #require(state.requestedMoment)
        let began = state.begin(moment, at: 350)
        #expect(began)
        state.interrupt(at: 351)
        state.update(at: 1_000_000, quiet: true, enabled: true)
        #expect(state.frame == nil && state.requestedMoment == nil)
        state.update(at: 1_000_179, quiet: true, enabled: true)
        #expect(state.requestedMoment == nil)
        state.update(at: 1_000_180, quiet: true, enabled: true)
        #expect(state.requestedMoment != nil)
    }
    @Test("Every habit can be first, finishes within eight seconds, and leaves no prop", arguments: BoatHabit.allCases)
    func independentEncounter(habit: BoatHabit) throws {
        let seed = try #require((UInt64(0)...200).first { seed in
            var picker = IdleMomentPicker(seed: seed)
            return picker.next() == .boat(habit)
        })
        var state = BoredomState(seed: seed, timing: BoredomTiming(threshold: 1, cooldown: 2))
        state.update(at: 0, quiet: true, enabled: true)
        state.update(at: 1, quiet: true, enabled: true)
        #expect(state.requestedMoment == .boat(habit))
        let began = state.begin(.boat(habit), at: 1)
        #expect(began)
        state.update(at: 5, quiet: true, enabled: true)
        #expect(state.frame?.boatPresentation?.opacity == 1)
        state.update(at: 9, quiet: true, enabled: true)
        #expect(state.frame == nil && state.requestedMoment == nil)
        state.update(at: 10.9, quiet: true, enabled: true)
        #expect(state.requestedMoment == nil)
    }
    @Test("Power restrictions cancel active and requested boat commands immediately", arguments: [false, true])
    func restricted(active: Bool) throws {
        let seed = try #require((UInt64(0)...100).first { seed in
            var picker = IdleMomentPicker(seed: seed)
            return picker.next().boatHabit != nil
        })
        var state = BoredomState(seed: seed, timing: BoredomTiming(threshold: 1, cooldown: 2))
        state.update(at: 0, quiet: true, enabled: true)
        state.update(at: 1, quiet: true, enabled: true)
        let moment = try #require(state.requestedMoment)
        if active { let began = state.begin(moment, at: 1); #expect(began) }
        state.update(at: 1, quiet: true, enabled: false)
        #expect(state.frame == nil && state.requestedMoment == nil)
        let staleBegan = state.begin(moment, at: 1)
        #expect(!staleBegan)
        state.update(at: 1, quiet: true, enabled: true)
        #expect(state.frame == nil && state.requestedMoment == nil)
    }

#if DEBUG
    @Test("Gentle intensity also reduces the boat’s own movement")
    func gentleBoat() throws {
        func rotation(amount: Double) throws -> Double {
            var engine = CompanionEngine(scene: .preview)
            engine.setMovementAmount(amount)
            engine.requestDebugIdleMoment(.boat(.doze)); engine.send(.command(.idleDozeWithBoat))
            for _ in 0..<10 { engine.advance(by: 0.1) }
            return try #require(engine.snapshot.idleMoment?.boatPresentation?.rotation)
        }
        let standard = try rotation(amount: 1), gentle = try rotation(amount: 0.35)
        #expect(abs(standard) > 0.01)
        #expect(abs(gentle) < abs(standard) * 0.5)
    }
#endif

}
