import Foundation
import SprigletCore
import Testing

@Suite("Calm behavior planning")
struct PetBehaviorPlannerTests {
    @Test("Actions round-trip as named values", arguments: PetAction.allCases)
    func actionCoding(action: PetAction) throws {
        let encoded = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(PetAction.self, from: encoded) == action)
        #expect(try JSONDecoder().decode(String.self, from: encoded) == action.rawValue)
    }

    @Test("Same seed and state history reproduce every suggestion", arguments: [UInt64(0), 1, .max])
    func reproducibleHistory(seed: UInt64) {
        var first = PetBehaviorPlanner(seed: seed)
        var second = PetBehaviorPlanner(seed: seed)
        for index in 0..<256 {
            if index.isMultiple(of: 11) {
                first.resetAfterInteraction()
                second.resetAfterInteraction()
            }
            let sleeping = index.isMultiple(of: 7)
            #expect(first.next(isSleeping: sleeping) == second.next(isSleeping: sleeping))
        }
    }

    @Test("Awake suggestions stay bounded and avoid repeated large actions", arguments: [UInt64(0), 1, .max, 0x53505249474c4554])
    func awakeInvariants(seed: UInt64) {
        var planner = PetBehaviorPlanner(seed: seed)
        var previous: PetAction?
        for _ in 0..<512 {
            let plan = planner.next(isSleeping: false)
            #expect(plan.delaySeconds.isFinite)
            #expect((20...75).contains(plan.delaySeconds))
            #expect(plan.action != .react && plan.action != .wakeUp)
            if plan.action != .blink {
                #expect(plan.action != previous)
            }
            previous = plan.action
        }
    }

    @Test("Sleeping always receives a bounded wake suggestion", arguments: [UInt64(0), 42, .max])
    func sleepingWake(seed: UInt64) {
        var planner = PetBehaviorPlanner(seed: seed)
        for _ in 0..<64 {
            let plan = planner.next(isSleeping: true)
            #expect(plan.action == .wakeUp)
            #expect(plan.delaySeconds.isFinite)
            #expect((60...180).contains(plan.delaySeconds))
        }
    }

    @Test("Brief actions dominate, with stretching less common and sleep rare")
    func calmActionMix() {
        var planner = PetBehaviorPlanner(seed: 0x53505249474c4554)
        var counts: [PetAction: Int] = [:]
        for _ in 0..<4_096 {
            counts[planner.next(isSleeping: false).action, default: 0] += 1
        }
        let blinks = counts[.blink, default: 0]
        let looks = counts[.lookAround, default: 0]
        let stretches = counts[.stretch, default: 0]
        let sleeps = counts[.fallAsleep, default: 0]
        #expect(blinks > looks && looks > stretches && stretches > sleeps)
        #expect(sleeps > 0)
        #expect(blinks + looks > 4 * (stretches + sleeps))
        #expect(sleeps < 4_096 / 10)
        #expect(counts[.react, default: 0] == 0)
    }

    @Test("Different seeds produce varied behavior")
    func seedMatters() {
        var first = PetBehaviorPlanner(seed: 0)
        var second = PetBehaviorPlanner(seed: .max)
        let firstPlans = (0..<16).map { _ in first.next(isSleeping: false) }
        let secondPlans = (0..<16).map { _ in second.next(isSleeping: false) }
        #expect(firstPlans != secondPlans)
    }

    @Test("Interaction inserts a gentle cooldown, then ordinary behavior returns", arguments: [UInt64(0), 42, .max])
    func interactionCooldown(seed: UInt64) {
        var planner = PetBehaviorPlanner(seed: seed)
        for _ in 0..<12 { _ = planner.next(isSleeping: false) }
        planner.resetAfterInteraction()
        let next = planner.next(isSleeping: false)
        #expect(next.action == .blink)
        #expect((45...75).contains(next.delaySeconds))

        let subsequent = (0..<128).map { _ in planner.next(isSleeping: false) }
        #expect(subsequent.contains { $0.action != .blink })
        #expect(subsequent.contains { $0.delaySeconds < 45 })
    }

    @Test("A sleep wake-up preserves the interaction cooldown for the awake pet")
    func sleepPreservesCooldown() {
        var planner = PetBehaviorPlanner(seed: 19)
        planner.resetAfterInteraction()
        let sleepingPlan = planner.next(isSleeping: true)
        #expect(sleepingPlan.action == .wakeUp)
        #expect((60...180).contains(sleepingPlan.delaySeconds))
        let awakePlan = planner.next(isSleeping: false)
        #expect(awakePlan.action == .blink)
        #expect((45...75).contains(awakePlan.delaySeconds))
    }

    @Test("Repeated interaction resets are idempotent and do not rewind randomness")
    func resetKeepsRandomProgress() {
        var first = PetBehaviorPlanner(seed: 42)
        var second = PetBehaviorPlanner(seed: 42)
        var delays: Set<Double> = []
        for _ in 0..<32 {
            first.resetAfterInteraction()
            second.resetAfterInteraction()
            second.resetAfterInteraction()
            let firstPlan = first.next(isSleeping: false)
            #expect(firstPlan == second.next(isSleeping: false))
            delays.insert(firstPlan.delaySeconds)
        }
        #expect(delays.count > 1)
    }
}
