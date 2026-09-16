import Testing
@testable import SprigletCore

@Suite("Pure pointer attention")
struct PointerAttentionTests {
    private let target = PointerPoint(x: 0, y: 0)!

    private func time(_ seconds: Double) -> MonotonicTimestamp { MonotonicTimestamp(seconds: seconds)! }
    private func sample(_ seconds: Double, _ x: Double, _ y: Double = 0) -> PointerSample {
        PointerSample(timestamp: time(seconds), location: PointerPoint(x: x, y: y)!)
    }

    private let perceptionConfiguration = PointerPerceptionConfiguration(
        nearEnterDistance: 180, nearExitDistance: 220,
        dwellEnterDistance: 96, dwellExitDistance: 120,
        dwellDuration: 0.8, maximumSampleGap: 0.75,
        teleportDistance: 480, projectionHorizon: 0.35
    )!

    private let attentionConfiguration = PointerAttentionConfiguration(
        gazeRangePixels: 160, curiousDistance: 180,
        curiousApproachSpeed: 36, departureSpeed: 36, departureHoldDuration: 0.45
    )!

    @Test("A stationary dwell matures at an explicit deadline without another sample")
    func dwellDeadline() {
        let perception = PointerPerception.reduce(
            .empty, sample: sample(0, 20), toward: target, configuration: perceptionConfiguration
        )
        let initial = PointerAttention.reduce(
            .neutral, perception: perception, toward: target, at: time(0),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(initial.mode == .gaze)
        #expect(initial.dwellDeadline == time(0.8))

        let matured = PointerAttention.evaluate(
            initial, perception: perception, at: time(0.8), perceptionConfiguration: perceptionConfiguration
        )
        #expect(matured.mode == .dwelling)
        #expect(matured.gaze == PointerVector(dx: 0.125, dy: 0))

        let samePointAfterGap = PointerPerception.reduce(
            perception, sample: sample(0.9, 20), toward: target, configuration: perceptionConfiguration
        )
        #expect(!samePointAfterGap.didDiscontinue)
        #expect(samePointAfterGap.isDwelling)
    }

    @Test("Near approach becomes curious and normalized gaze never contains a coordinate")
    func curiousApproach() {
        let first = PointerPerception.reduce(.empty, sample: sample(0, 220), toward: target, configuration: perceptionConfiguration)
        let approaching = PointerPerception.reduce(first, sample: sample(0.5, 100), toward: target, configuration: perceptionConfiguration)
        let attention = PointerAttention.reduce(
            .neutral, perception: approaching, toward: target, at: time(0.5),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(attention.mode == .curious)
        #expect(attention.gaze == PointerVector(dx: 0.625, dy: 0))
        #expect(attention.lean > 0)
        #expect(attention.lean <= 1)
    }

    @Test("A slow far pass remains neutral")
    func farPassIsNeutral() {
        let first = PointerPerception.reduce(
            .empty, sample: sample(0, 300), toward: target, configuration: perceptionConfiguration
        )
        let passing = PointerPerception.reduce(
            first, sample: sample(0.5, 300, 10), toward: target, configuration: perceptionConfiguration
        )
        let attention = PointerAttention.reduce(
            .neutral, perception: passing, toward: target, at: time(0.5),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(passing.proximity == .far)
        #expect(attention == .neutral)
    }

    @Test("A projected approach can earn gaze before crossing the near boundary")
    func projectedApproachGazes() {
        let first = PointerPerception.reduce(
            .empty, sample: sample(0, 300), toward: target, configuration: perceptionConfiguration
        )
        let approaching = PointerPerception.reduce(
            first, sample: sample(0.5, 220), toward: target, configuration: perceptionConfiguration
        )
        let attention = PointerAttention.reduce(
            .neutral, perception: approaching, toward: target, at: time(0.5),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(approaching.proximity == .far)
        #expect(approaching.projectedDistanceToTarget == 164)
        #expect(attention.mode == .gaze)
    }

    @Test("A discontinuous point can guide gaze but cannot trigger a velocity reaction")
    func discontinuityStillGazes() {
        let first = PointerPerception.reduce(
            .empty, sample: sample(0, 700), toward: target, configuration: perceptionConfiguration
        )
        let teleported = PointerPerception.reduce(
            first, sample: sample(0.1, 80), toward: target, configuration: perceptionConfiguration
        )
        #expect(teleported.didDiscontinue)

        let attention = PointerAttention.reduce(
            .neutral, perception: teleported, toward: target, at: time(0.1),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(attention.mode == .gaze)
        #expect(attention.gaze == PointerVector(dx: 0.5, dy: 0))
        #expect(attention.lean == 0)
    }

    @Test("Fast passes do not become curious")
    func fastPassIsNotCurious() {
        let first = PointerPerception.reduce(
            .empty, sample: sample(0, 200), toward: target, configuration: perceptionConfiguration
        )
        let fast = PointerPerception.reduce(
            first, sample: sample(0.25, 100), toward: target, configuration: perceptionConfiguration
        )
        #expect(fast.radialVelocity == 400)

        let atLimit = PointerAttention.reduce(
            .neutral, perception: fast, toward: target, at: time(0.25),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(atLimit.mode == .curious)

        let faster = PointerPerception.reduce(
            first, sample: sample(0.2, 100), toward: target, configuration: perceptionConfiguration
        )
        let ignored = PointerAttention.reduce(
            .neutral, perception: faster, toward: target, at: time(0.2),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(faster.radialVelocity == 500)
        #expect(ignored.mode == .gaze)
    }

    @Test("Continuous nearby motion restarts dwell from the latest event")
    func movingNearRestartsDwell() {
        let first = PointerPerception.reduce(
            .empty, sample: sample(0, 90), toward: target, configuration: perceptionConfiguration
        )
        let initial = PointerAttention.reduce(
            .neutral, perception: first, toward: target, at: time(0),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(initial.dwellDeadline == time(0.8))

        let moving = PointerPerception.reduce(
            first, sample: sample(0.2, 80), toward: target, configuration: perceptionConfiguration
        )
        let restarted = PointerAttention.reduce(
            initial, perception: moving, toward: target, at: time(0.2),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(moving.velocity.magnitude == 50)
        #expect(restarted.dwellDeadline == time(1.0))
        #expect(PointerAttention.evaluate(
            restarted, perception: moving, at: time(0.8),
            perceptionConfiguration: perceptionConfiguration
        ).mode != .dwelling)
        #expect(PointerAttention.evaluate(
            restarted, perception: moving, at: time(1.0),
            perceptionConfiguration: perceptionConfiguration
        ).mode == .dwelling)
    }

    @Test("Departure holds once then becomes neutral at its explicit deadline")
    func departureHold() {
        let first = PointerPerception.reduce(.empty, sample: sample(0, 100), toward: target, configuration: perceptionConfiguration)
        let approaching = PointerPerception.reduce(first, sample: sample(0.2, 50), toward: target, configuration: perceptionConfiguration)
        let departing = PointerPerception.reduce(approaching, sample: sample(0.4, 110), toward: target, configuration: perceptionConfiguration)
        let hold = PointerAttention.reduce(
            .neutral, perception: departing, toward: target, at: time(0.4),
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        #expect(hold.mode == .departureHold)
        #expect(hold.departureDeadline?.seconds ?? 0 > 0.84)
        #expect(hold.departureDeadline?.seconds ?? 1 < 0.86)
        #expect(PointerAttention.evaluate(hold, perception: departing, at: time(0.84), perceptionConfiguration: perceptionConfiguration).mode == .departureHold)
        #expect(PointerAttention.evaluate(hold, perception: departing, at: time(0.86), perceptionConfiguration: perceptionConfiguration) == .neutral)
    }

    @Test("Invalid attention configuration fails closed before mapping")
    func invalidConfiguration() {
        #expect(PointerAttentionConfiguration(
            gazeRangePixels: 0, curiousDistance: 1, curiousApproachSpeed: 1,
            departureSpeed: 1, departureHoldDuration: 1
        ) == nil)
        #expect(PointerAttentionConfiguration(
            gazeRangePixels: 1, curiousDistance: 1, curiousApproachSpeed: 100,
            maximumCuriousApproachSpeed: 99, departureSpeed: 1, departureHoldDuration: 1
        ) == nil)
    }
}
