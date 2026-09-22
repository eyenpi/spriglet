import Foundation
import Testing
@testable import SprigletCore

@Suite("User activity policy")
struct UserActivityPolicyTests {
    @Test("Only real input-idle duration selects wake, idle, or nap eligibility")
    func bucketAndDeadline() throws {
        let policy = try #require(UserActivityPolicy(recentInputThreshold: 10, napThreshold: 120))

        let recent = try #require(policy.evaluate(idleDuration: 10))
        #expect(recent.bucket == .recent)
        #expect(recent.shouldWake)
        #expect(recent.nextIdleDeadlineSeconds == 110)

        let idle = try #require(policy.evaluate(idleDuration: 10.01))
        #expect(idle.bucket == .idle)
        #expect(!idle.shouldWake)
        #expect(abs((idle.nextIdleDeadlineSeconds ?? 0) - 109.99) < 0.000_000_1)

        let nap = try #require(policy.evaluate(idleDuration: 120))
        #expect(nap.bucket == .napEligible)
        #expect(nap.allowsNap)
        #expect(nap.nextIdleDeadlineSeconds == nil)

        let sleeping = try #require(policy.evaluate(idleDuration: 10, isSleeping: true))
        #expect(sleeping.nextIdleDeadlineSeconds == nil)
    }

    @Test("Invalid durations and unordered thresholds never produce activity facts")
    func invalidValuesFailClosed() {
        #expect(UserActivityPolicy(recentInputThreshold: -1, napThreshold: 1) == nil)
        #expect(UserActivityPolicy(recentInputThreshold: 10, napThreshold: 9) == nil)
        let policy = UserActivityPolicy.standard
        #expect(policy.evaluate(idleDuration: -.infinity) == nil)
        #expect(policy.evaluate(idleDuration: .infinity) == nil)
        #expect(policy.evaluate(idleDuration: .nan) == nil)
    }

    @Test("Sleeping evaluations never create an activity deadline")
    func sleepingHasNoDeadline() throws {
        let policy = try #require(UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20))

        for duration in [0.0, 10.0, 20.0, 200.0] {
            let evaluation = try #require(policy.evaluate(idleDuration: duration, isSleeping: true))
            #expect(evaluation.nextIdleDeadlineSeconds == nil)
        }
    }

    @Test("Coincident thresholds retain deterministic recent-input precedence")
    func coincidentThresholds() throws {
        let policy = try #require(UserActivityPolicy(recentInputThreshold: 0, napThreshold: 0))

        let immediate = try #require(policy.evaluate(idleDuration: 0))
        #expect(immediate.bucket == .recent)
        #expect(immediate.shouldWake)
        #expect(immediate.nextIdleDeadlineSeconds == nil)

        let later = try #require(policy.evaluate(idleDuration: 0.001))
        #expect(later.bucket == .napEligible)
        #expect(later.allowsNap)
    }
}
