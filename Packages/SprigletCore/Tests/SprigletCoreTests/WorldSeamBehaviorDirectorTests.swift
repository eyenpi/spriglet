import Foundation
import Testing
import SprigletCore

@Suite("Legacy behavior director adapter")
struct WorldSeamBehaviorDirectorTests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("World facts preserve the planner's exact suggestion sequence")
    func exactPlannerAdaptation() {
        let world = PetWorldSnapshot(
            isSleeping: false,
            canWander: true,
            isLowPower: false,
            activityLevel: .lively
        )
        let profile = PetProfile(traits: PetTraits(curiosity: 0.8, sociability: 0.6, playfulness: 0.7))
        var memory = PetInteractionMemory()
        memory.record(.petted, at: epoch.addingTimeInterval(-100))
        var planner = PetBehaviorPlanner(seed: 0xAC0A)
        var director = LegacyBehaviorDirector(seed: 0xAC0A)

        for offset in 0..<24 {
            let now = epoch.addingTimeInterval(Double(offset) * 200)
            let expected = planner.next(
                isSleeping: false,
                profile: profile,
                memory: memory,
                now: now,
                canWander: true,
                lowPower: false,
                activityLevel: .lively
            )
            let actual = director.next(in: world, profile: profile, memory: memory, now: now)
            #expect(actual == expected)

            if offset.isMultiple(of: 3) {
                planner.didPerform(expected.intent, at: now)
                director.didPerform(actual.intent, at: now)
            }
        }
    }

    @Test("Execution and interaction feedback remain distinct")
    func feedbackCompatibility() {
        let world = PetWorldSnapshot(canWander: true)
        var planner = PetBehaviorPlanner(seed: 91)
        var director = LegacyBehaviorDirector(seed: 91)

        planner.resetAfterInteraction()
        director.resetAfterInteraction()
        let expectedQuiet = planner.next(isSleeping: false, now: epoch, canWander: true)
        let actualQuiet = director.next(in: world, now: epoch)
        #expect(actualQuiet == expectedQuiet)
        #expect(actualQuiet.intent == .observe)

        planner.didPerform(.observe, at: epoch)
        director.didPerform(.observe, at: epoch)
        let later = epoch.addingTimeInterval(500)
        #expect(
            director.next(in: world, now: later)
                == planner.next(isSleeping: false, now: later, canWander: true)
        )
    }

    @Test("The protocol supports stateful existential dispatch")
    func protocolBoundary() {
        var director: any BehaviorDirector = LegacyBehaviorDirector(seed: 12)
        let planned = director.next(
            in: PetWorldSnapshot(isSleeping: true),
            profile: PetProfile(),
            memory: PetInteractionMemory(),
            now: epoch
        )
        #expect(planned.intent == .wake)
        director.didPerform(.wake, at: epoch)
        director.resetAfterInteraction()
    }
}
