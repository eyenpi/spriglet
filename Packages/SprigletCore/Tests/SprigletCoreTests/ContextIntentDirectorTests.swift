import Testing
@testable import SprigletCore

@Suite("Context intent arbitration")
struct ContextIntentDirectorTests {
    @Test("Movement wakes explicit sleep even when automatic moments are off")
    func explicitWake() {
        #expect(decide(.wakeRequested, sleeping: true, automatic: false) == .wake)
        #expect(decide(.wakeRequested, sleeping: false, automatic: true) == nil)
    }

    @Test("Actual idle and generic app glance require automatic moments")
    func automaticContext() {
        #expect(decide(.napEligible, automatic: true) == .nap)
        #expect(decide(.appGlance, automatic: true) == .appGlance)
        #expect(decide(.napEligible, automatic: false) == nil)
        #expect(decide(.appGlance, automatic: false) == nil)
    }

    @Test("Suspension and competing direct or authored work win")
    func priority() {
        let fact = UserActivityContextFact(timestamp: .zero, kind: .napEligible)
        for world in [
            PetWorldSnapshot(activityPolicy: ActivityPolicy(reasons: [.hidden])),
            PetWorldSnapshot(isInteracting: true),
            PetWorldSnapshot(isAnimating: true),
            PetWorldSnapshot(isMoving: true),
            PetWorldSnapshot(isOnActiveSpace: false)
        ] {
            #expect(ContextIntentDirector.intent(
                for: fact, in: world, automaticMomentsEnabled: true
            ) == nil)
        }
    }

    private func decide(
        _ kind: UserActivityContextFact.Kind,
        sleeping: Bool = false,
        automatic: Bool
    ) -> ContextualBehaviorIntent? {
        ContextIntentDirector.intent(
            for: UserActivityContextFact(timestamp: .zero, kind: kind),
            in: PetWorldSnapshot(isSleeping: sleeping),
            automaticMomentsEnabled: automatic
        )
    }
}
