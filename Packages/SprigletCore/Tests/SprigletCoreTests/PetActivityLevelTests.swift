import Foundation
import SprigletCore
import Testing

@Suite("Activity frequency policy")
struct PetActivityLevelTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Frequency changes timing without replacing personality intentions")
    func orderedFrequency() {
        for seed in UInt64(0)..<512 {
            var quiet = PetBehaviorPlanner(seed: seed)
            var balanced = PetBehaviorPlanner(seed: seed)
            var lively = PetBehaviorPlanner(seed: seed)
            let a = quiet.next(isSleeping: false, now: now, canWander: true, activityLevel: .quiet)
            let b = balanced.next(isSleeping: false, now: now, canWander: true, activityLevel: .balanced)
            let c = lively.next(isSleeping: false, now: now, canWander: true, activityLevel: .lively)
            #expect(a.intent == b.intent && b.intent == c.intent)
            #expect(a.delaySeconds >= b.delaySeconds && b.delaySeconds >= c.delaySeconds)
            #expect((60...720).contains(a.delaySeconds) && (60...480).contains(b.delaySeconds) && (60...360).contains(c.delaySeconds))
        }
    }

    @Test("All levels honor interaction quiet time, parking and low power", arguments: PetActivityLevel.allCases)
    func policies(level: PetActivityLevel) {
        var memory = PetInteractionMemory()
        memory.record(.relocated, at: now)
        var planner = PetBehaviorPlanner(seed: 32)
        for index in 0..<256 {
            let plan = planner.next(isSleeping: index.isMultiple(of: 5), memory: memory, now: now,
                                    canWander: index.isMultiple(of: 2), lowPower: index.isMultiple(of: 2), activityLevel: level)
            #expect(plan.intent != .explore)
            #expect(plan.delaySeconds.isFinite && (180...720).contains(plan.delaySeconds))
        }
        planner.resetAfterInteraction()
        let afterPress = planner.next(isSleeping: false, now: now, canWander: true, activityLevel: level)
        #expect(afterPress.intent == .observe && afterPress.delaySeconds >= 90)
    }
}
