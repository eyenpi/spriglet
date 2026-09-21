import Foundation
import Testing
import SprigletCore

@Suite("Pure pet world reduction")
struct WorldSeamReducerTests {
    private func time(_ seconds: Double) -> MonotonicTimestamp {
        try! #require(MonotonicTimestamp(seconds: seconds))
    }

    @Test("An event trace replays to exactly the same immutable snapshot")
    func deterministicReplay() {
        let trace = [
            PetStimulus(timestamp: time(1), event: .wanderingAvailability(true)),
            PetStimulus(timestamp: time(2), event: .lowPower(true)),
            PetStimulus(timestamp: time(3), event: .activityLevel(.lively)),
            PetStimulus(timestamp: time(4), event: .sleeping(true)),
            PetStimulus(timestamp: time(5), event: .reduceMotion(true)),
            PetStimulus(timestamp: time(6), event: .activeSpace(false)),
            PetStimulus(timestamp: time(7), event: .interaction(true)),
            PetStimulus(timestamp: time(8), event: .animating(true)),
            PetStimulus(timestamp: time(9), event: .moving(true)),
            PetStimulus(timestamp: time(10), event: .conversing(true))
        ]

        let first = WorldReducer.replay(stimuli: trace)
        let second = WorldReducer.replay(stimuli: trace)

        #expect(first == second)
        #expect(first.timestamp == time(10))
        #expect(first.isConversing)
        #expect(first.isSleeping)
        #expect(first.canWander)
        #expect(first.isLowPower)
        #expect(first.isReduceMotion)
        #expect(!first.isOnActiveSpace)
        #expect(first.isInteracting)
        #expect(first.isAnimating)
        #expect(first.isMoving)
        #expect(first.activityLevel == .lively)
        #expect(!first.allowsAutonomousBehavior)
    }

    @Test("Late observations cannot roll world time or facts backwards")
    func staleStimulusIsIgnored() {
        let current = WorldReducer.reduce(
            PetWorldSnapshot(),
            PetStimulus(timestamp: time(20), event: .lowPower(true))
        )
        let result = WorldReducer.reduce(
            current,
            PetStimulus(timestamp: time(19.999), event: .lowPower(false))
        )

        #expect(result == current)
    }

    @Test("Equal-time events retain deterministic delivery order")
    func equalTimeDeliveryOrder() {
        let enabledThenDisabled = WorldReducer.replay(stimuli: [
            PetStimulus(timestamp: time(10), event: .lowPower(true)),
            PetStimulus(timestamp: time(10), event: .lowPower(false))
        ])
        let disabledThenEnabled = WorldReducer.replay(stimuli: [
            PetStimulus(timestamp: time(10), event: .lowPower(false)),
            PetStimulus(timestamp: time(10), event: .lowPower(true))
        ])

        #expect(!enabledThenDisabled.isLowPower)
        #expect(disabledThenEnabled.isLowPower)
    }

    @Test("Suspension causes aggregate and clear independently")
    func suspensionAggregation() {
        let trace = [
            PetStimulus(timestamp: time(1), event: .suspension(reason: .hidden, active: true)),
            PetStimulus(timestamp: time(2), event: .suspension(reason: .thermalPressure, active: true)),
            PetStimulus(timestamp: time(3), event: .suspension(reason: .hidden, active: false))
        ]
        let stillSuspended = WorldReducer.replay(stimuli: trace)
        #expect(stillSuspended.isSuspended)
        #expect(stillSuspended.activityPolicy.reasons == [.thermalPressure])
        #expect(!stillSuspended.allowsAutonomousBehavior)

        let resumed = WorldReducer.reduce(
            stillSuspended,
            PetStimulus(timestamp: time(4), event: .suspension(reason: .thermalPressure, active: false))
        )
        #expect(!resumed.isSuspended)
        #expect(resumed.allowsAutonomousBehavior)
    }

    @Test("Every busy or accessibility fact independently blocks autonomy")
    func autonomousEligibility() {
        let blockers: [PetStimulus.Event] = [
            .suspension(reason: .userPaused, active: true),
            .reduceMotion(true),
            .activeSpace(false),
            .interaction(true),
            .animating(true),
            .moving(true),
            .conversing(true)
        ]

        #expect(PetWorldSnapshot().allowsAutonomousBehavior)
        for blocker in blockers {
            let snapshot = WorldReducer.reduce(
                PetWorldSnapshot(),
                PetStimulus(timestamp: time(1), event: blocker)
            )
            #expect(!snapshot.allowsAutonomousBehavior)
        }
    }

    @Test("Finishing a conversation restores autonomy without disturbing other facts")
    func conversationEndsCleanly() {
        let talking = WorldReducer.replay(stimuli: [
            PetStimulus(timestamp: time(1), event: .lowPower(true)),
            PetStimulus(timestamp: time(2), event: .conversing(true))
        ])
        #expect(!talking.allowsAutonomousBehavior)

        let finished = WorldReducer.reduce(talking, PetStimulus(timestamp: time(3), event: .conversing(false)))
        #expect(!finished.isConversing)
        #expect(finished.isLowPower)
        #expect(finished.allowsAutonomousBehavior)
    }

    @Test("Malformed elapsed times cannot become timestamps", arguments: [
        -1.0, .nan, .infinity, -.infinity
    ])
    func invalidTimestamp(seconds: Double) {
        #expect(MonotonicTimestamp(seconds: seconds) == nil)
    }
}
