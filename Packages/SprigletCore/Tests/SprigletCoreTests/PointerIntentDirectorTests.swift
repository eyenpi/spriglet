import Foundation
import SprigletCore
import Testing

@Suite("Pointer facts and scene intent")
struct PointerIntentDirectorTests {
    private let attention = PointerAttentionState(mode: .curious,
                                                  gaze: PointerVector(dx: -0.5, dy: 0.75), lean: 0.6)

    @Test("Gaze crosses the Y-up/Y-down boundary once and lean follows the pointer")
    func commands() throws {
        let commands = PointerIntentDirector.commands(in: .init(attention: attention))
        #expect(commands.count == 3)
        guard case let .procedural(id, value) = commands[0] else { Issue.record("Missing gaze"); return }
        #expect(id == "gaze")
        #expect(value == SamplePoint(x: -0.5, y: -0.75))
        guard case let .procedural(leanID, lean) = commands[1] else { Issue.record("Missing lean"); return }
        #expect(leanID == "lean")
        #expect(lean == SamplePoint(x: -0.3, y: 0))
    }

    @Test("Direct input, suspension, sleep, macro motion, and accessibility outrank attention")
    func priorityBarriers() {
        let blocked: [PetWorldSnapshot] = [
            .init(activityPolicy: .init(reasons: [.hidden]), attention: attention),
            .init(isSleeping: true, attention: attention), .init(isReduceMotion: true, attention: attention),
            .init(isOnActiveSpace: false, attention: attention), .init(isInteracting: true, attention: attention),
            .init(isAnimating: true, attention: attention), .init(isMoving: true, attention: attention)
        ]
        for world in blocked { #expect(PointerIntentDirector.commands(in: world).isEmpty) }
    }

    @Test("Low Power retains gaze and removes cap and leaf motion")
    func lowPower() {
        let commands = PointerIntentDirector.commands(in: .init(isLowPower: true, attention: attention))
        for command in commands.dropFirst() {
            guard case let .procedural(_, target) = command else { Issue.record("Unexpected command"); return }
            #expect(target == .zero)
        }
    }

    @Test("World replay clears raw pointer facts on suspension and ignores delayed attention")
    func ephemeralLifetime() throws {
        let first = try #require(MonotonicTimestamp(seconds: 10))
        let point = try #require(PointerPoint(x: -500, y: 100))
        let target = try #require(PointerPoint(x: -400, y: 100))
        let perception = PointerPerception.reduce(.empty, sample: .init(timestamp: first, location: point), toward: target)
        var world = WorldReducer.reduce(.init(), .init(timestamp: first, event: .pointer(perception: perception, attention: attention)))
        #expect(world.pointer.latestSample?.location == point)
        let later = try #require(MonotonicTimestamp(seconds: 11))
        world = WorldReducer.reduce(world, .init(timestamp: later, event: .suspension(reason: .hidden, active: true)))
        #expect(world.pointer == .empty)
        #expect(world.attention == .neutral)
        world = WorldReducer.reduce(world, .init(timestamp: later, event: .pointer(perception: perception, attention: attention)))
        #expect(world.pointer == .empty)
        #expect(world.attention == .neutral)
    }
}
