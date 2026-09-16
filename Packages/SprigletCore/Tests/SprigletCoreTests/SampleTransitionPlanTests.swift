import SprigletCore
import Testing

@Suite("Finite character state transitions")
struct SampleTransitionPlanTests {
    private enum Pose { case ready, happy, asleep }

    private func boundary(_ clip: SampleClipID) -> (Pose, Pose) {
        switch clip {
        case .idle, .walkLeft, .walkRight: (.ready, .ready)
        case .pet: (.ready, .happy)
        case .settle: (.happy, .ready)
        case .fallAsleep: (.ready, .asleep)
        case .wakeUp: (.asleep, .ready)
        default: (.ready, .ready)
        }
    }

    @Test("Every ordered intent pair has a continuous pose route",
          arguments: SampleTransitionIntent.allCases, SampleTransitionIntent.allCases)
    func everyPair(first: SampleTransitionIntent, next: SampleTransitionIntent) {
        let initial = SampleTransitionPlan(to: first, isSleeping: false, animatedSleep: true)
        let handover = SampleTransitionPlan(to: next, isSleeping: initial.sleepsAtEnd, animatedSleep: true)
        var pose = Pose.ready
        for clip in initial.clips + handover.clips {
            let (entry, exit) = boundary(clip)
            #expect(pose == entry)
            pose = exit
        }
        #expect(pose == (handover.sleepsAtEnd ? .asleep : .ready))
        #expect(handover.clips.count <= 3)
    }

    @Test("A sleeping pet wakes before every awake experience",
          arguments: SampleTransitionIntent.allCases.filter { $0 != .sleep })
    func automaticWake(intent: SampleTransitionIntent) {
        let plan = SampleTransitionPlan(to: intent, isSleeping: true, animatedSleep: true)
        #expect(plan.clips.first == .wakeUp)
        #expect(!plan.sleepsAtEnd)
    }

    @Test("Rest and sleep holds need no continuing animation")
    func staticHolds() {
        #expect(SampleTransitionPlan(to: .ready, isSleeping: false, animatedSleep: true).clips.isEmpty)
        #expect(SampleTransitionPlan(to: .sleep, isSleeping: true, animatedSleep: true).clips.isEmpty)
    }

    @Test("Affection always settles before the next gesture")
    func happyExit() {
        #expect(SampleTransitionPlan(to: .happy, isSleeping: false, animatedSleep: true).clips == [.pet, .settle])
        #expect(SampleTransitionPlan(to: .happy, isSleeping: true, animatedSleep: true).clips == [.wakeUp, .pet, .settle])
    }

    @Test("Legacy Sprout never requests missing transition frames", arguments: SampleTransitionIntent.allCases)
    func legacy(intent: SampleTransitionIntent) {
        for sleeping in [true, false] {
            let plan = SampleTransitionPlan(to: intent, isSleeping: sleeping, animatedSleep: false)
            #expect(plan.clips.allSatisfy { SampleClipID.versionOneCases.contains($0) })
            #expect(plan.sleepsAtEnd == (intent == .sleep))
        }
    }
}
