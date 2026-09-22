import Foundation
import SprigletCore
import Testing

@Suite("Purposeful behavior planning")
struct PetBehaviorPlannerTests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Legacy action previews preserve probe behavior", arguments: PetAction.allCases)
    func actionCompatibility(action: PetAction) throws {
        let encoded = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(PetAction.self, from: encoded) == action)
        let plan = PlannedBehavior(action: action, delaySeconds: 0.05)
        #expect(plan.action == action)
        #expect(plan.delaySeconds == 0.05)
    }

    @Test("Intent names round-trip", arguments: PetBehaviorIntent.allCases)
    func intentCoding(intent: PetBehaviorIntent) throws {
        #expect(try JSONDecoder().decode(PetBehaviorIntent.self, from: JSONEncoder().encode(intent)) == intent)
    }

    @Test("Same seed and executed history reproduce suggestions", arguments: [UInt64(0), 1, .max])
    func reproducibleHistory(seed: UInt64) {
        var first = PetBehaviorPlanner(seed: seed)
        var second = PetBehaviorPlanner(seed: seed)
        var memory = PetInteractionMemory()
        for index in 0..<256 {
            let now = epoch.addingTimeInterval(Double(index) * 600)
            if index.isMultiple(of: 11) {
                first.resetAfterInteraction(); second.resetAfterInteraction()
                memory.record(.petted, at: now)
            }
            let a = first.next(isSleeping: index.isMultiple(of: 7), memory: memory, now: now, canWander: true)
            let b = second.next(isSleeping: index.isMultiple(of: 7), memory: memory, now: now, canWander: true)
            #expect(a == b)
            if !index.isMultiple(of: 3) {
                first.didPerform(a.intent, at: now.addingTimeInterval(a.delaySeconds))
                second.didPerform(b.intent, at: now.addingTimeInterval(b.delaySeconds))
            }
        }
    }

    @Test("Intentions are bounded and never repeat a performed major routine", arguments: [UInt64(0), 1, .max])
    func executionInvariants(seed: UInt64) {
        var planner = PetBehaviorPlanner(seed: seed)
        var previous: PetBehaviorIntent?
        var now = epoch
        var sleeping = false
        var lastExplore: Date?
        for _ in 0..<1_024 {
            let plan = planner.next(isSleeping: sleeping, now: now, canWander: true)
            #expect(plan.delaySeconds.isFinite && (60...480).contains(plan.delaySeconds))
            #expect((plan.intent == .wake) == sleeping)
            if plan.intent != .observe { #expect(plan.intent != previous) }
            now.addTimeInterval(plan.delaySeconds)
            if plan.intent == .explore {
                if let lastExplore { #expect(now.timeIntervalSince(lastExplore) >= 180) }
                lastExplore = now
            }
            planner.didPerform(plan.intent, at: now)
            sleeping = plan.intent == .nap
            previous = plan.intent
        }
    }

    @Test("Parked and low-power pets never receive exploration", arguments: [(false, false), (false, true), (true, true)])
    func movementPolicy(policy: (Bool, Bool)) {
        var planner = PetBehaviorPlanner(seed: 19)
        for index in 0..<1_024 {
            let now = epoch.addingTimeInterval(Double(index) * 600)
            let plan = planner.next(isSleeping: false, now: now, canWander: policy.0, lowPower: policy.1)
            #expect(plan.intent != .explore)
            #expect((60...480).contains(plan.delaySeconds))
            planner.didPerform(plan.intent, at: now)
        }
    }

    @Test("Sleeping receives an intentional bounded wake", arguments: [false, true])
    func sleepingWake(lowPower: Bool) {
        var planner = PetBehaviorPlanner(seed: 42)
        for _ in 0..<64 {
            let plan = planner.next(isSleeping: true, now: epoch, canWander: true, lowPower: lowPower)
            #expect(plan.intent == .wake && plan.action == .wakeUp)
            #expect((180...480).contains(plan.delaySeconds))
        }
    }

    @Test("Cancelled intentions do not become executed history")
    func cancellationDoesNotConsumeHistory() {
        var repeatedAfterCancellation = false
        for seed in UInt64(0)..<512 {
            var planner = PetBehaviorPlanner(seed: seed)
            let first = planner.next(isSleeping: false, now: epoch, canWander: true)
            guard first.intent != .observe else { continue }
            var performed = planner
            performed.didPerform(first.intent, at: epoch)
            let cancelledNext = planner.next(isSleeping: false, now: epoch.addingTimeInterval(600), canWander: true)
            let performedNext = performed.next(isSleeping: false, now: epoch.addingTimeInterval(600), canWander: true)
            #expect(performedNext.intent != first.intent)
            if cancelledNext.intent == first.intent { repeatedAfterCancellation = true }
        }
        #expect(repeatedAfterCancellation)
    }

    @Test("Walking cooldown survives an intervening small routine and recovers after clock rollback")
    func movementCooldown() {
        var planner = PetBehaviorPlanner(seed: 15)
        planner.didPerform(.explore, at: epoch)
        planner.didPerform(.observe, at: epoch)
        for _ in 0..<256 {
            #expect(planner.next(isSleeping: false, now: epoch.addingTimeInterval(179.999), canWander: true).intent != .explore)
        }
        let eligible = (0..<256).map { _ in planner.next(isSleeping: false, now: epoch.addingTimeInterval(180), canWander: true).intent }
        #expect(eligible.contains(.explore))

        let rolledBack = epoch.addingTimeInterval(-10_000)
        #expect(planner.next(isSleeping: false, now: rolledBack, canWander: true).intent != .explore)
        for _ in 0..<128 {
            #expect(planner.next(isSleeping: false, now: rolledBack.addingTimeInterval(179), canWander: true).intent != .explore)
        }
        let recovered = (0..<256).map { _ in planner.next(isSleeping: false, now: rolledBack.addingTimeInterval(180), canWander: true).intent }
        #expect(recovered.contains(.explore))
    }

    @Test("Invalid dates cannot trigger a walk or damage executed history")
    func invalidClock() {
        var planner = PetBehaviorPlanner(seed: 44)
        planner.didPerform(.greet, at: epoch)
        planner.didPerform(.explore, at: Date(timeIntervalSinceReferenceDate: .nan))
        for value in [Double.nan, .infinity, -.infinity] {
            for _ in 0..<64 {
                let plan = planner.next(isSleeping: false, now: Date(timeIntervalSinceReferenceDate: value), canWander: true)
                #expect(plan.intent != .explore && plan.intent != .greet)
                #expect(plan.delaySeconds.isFinite && (60...480).contains(plan.delaySeconds))
            }
        }
    }

    @Test("Interaction quiet time survives cancellation and wake until an awake routine is performed")
    func quietCompatibility() {
        var planner = PetBehaviorPlanner(seed: 42)
        planner.resetAfterInteraction()
        planner.resetAfterInteraction()
        let wake = planner.next(isSleeping: true, now: epoch)
        planner.didPerform(wake.intent, at: epoch)
        for _ in 0..<12 {
            let cancelled = planner.next(isSleeping: false, now: epoch, canWander: true)
            #expect(cancelled.intent == .observe)
            #expect((90...180).contains(cancelled.delaySeconds))
        }
        planner.didPerform(.observe, at: epoch)
        let subsequent = (0..<256).map { _ in planner.next(isSleeping: false, now: epoch, canWander: true) }
        #expect(subsequent.contains { $0.intent != .observe })
    }

    @Test("All own-interaction quiet periods bound the next suggestion", arguments: PetInteractionKind.allCases)
    func memoryQuietPeriod(kind: PetInteractionKind) {
        var memory = PetInteractionMemory()
        memory.record(kind, at: epoch)
        var planner = PetBehaviorPlanner(seed: 18)
        for _ in 0..<256 {
            let plan = planner.next(isSleeping: false, memory: memory, now: epoch, canWander: true)
            #expect(plan.delaySeconds >= memory.values(at: epoch).quietSecondsRemaining)
            #expect(plan.delaySeconds <= 480)
        }
    }

    @Test("Traits and recent interactions modestly change deterministic preference weights")
    func personalityAffectsMix() {
        func counts(profile: PetProfile, memory: PetInteractionMemory = .init()) -> [PetBehaviorIntent: Int] {
            var planner = PetBehaviorPlanner(seed: 0x53505249474c4554)
            var counts: [PetBehaviorIntent: Int] = [:]
            for _ in 0..<4_096 {
                counts[planner.next(isSleeping: false, profile: profile, memory: memory, now: epoch, canWander: true).intent, default: 0] += 1
            }
            return counts
        }
        let quiet = counts(profile: PetProfile(traits: PetTraits(curiosity: 0, sociability: 0, playfulness: 0)))
        let outgoing = counts(profile: PetProfile(traits: PetTraits(curiosity: 1, sociability: 1, playfulness: 1)))
        #expect(outgoing[.explore, default: 0] > quiet[.explore, default: 0])
        #expect(outgoing[.greet, default: 0] > quiet[.greet, default: 0])
        #expect(outgoing[.observe, default: 0] > outgoing[.explore, default: 0])
        var affection = PetInteractionMemory()
        for index in 0..<5 { affection.record(.petted, at: epoch.addingTimeInterval(Double(index - 4) * 20)) }
        let baseline = counts(profile: PetProfile())
        let affectionate = counts(profile: PetProfile(), memory: affection)
        #expect(affectionate[.greet, default: 0] > baseline[.greet, default: 0])
        #expect(baseline[.nap, default: 0] == 0)
    }

    @Test("Different seeds vary the finite suggestions")
    func seedMatters() {
        var first = PetBehaviorPlanner(seed: 0)
        var second = PetBehaviorPlanner(seed: .max)
        #expect((0..<32).map { _ in first.next(isSleeping: false, now: epoch, canWander: true) }
                != (0..<32).map { _ in second.next(isSleeping: false, now: epoch, canWander: true) })
    }
}
