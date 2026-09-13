import Testing
import SprigletCore

@Suite("Animation suspension policy")
struct ActivityPolicyTests {
    @Test(
        "Every combination resumes only after every cause clears",
        arguments: 0..<(1 << SuspensionReason.allCases.count)
    )
    func independentReasons(mask: Int) {
        let reasons = Set(SuspensionReason.allCases.enumerated().compactMap { index, reason in
            mask & (1 << index) == 0 ? nil : reason
        })
        var policy = ActivityPolicy(reasons: reasons)
        #expect(policy.allowsAnimation == (mask == 0))

        var remaining = reasons
        for reason in SuspensionReason.allCases {
            policy.set(reason, active: false)
            remaining.remove(reason)
            #expect(policy.reasons == remaining)
            #expect(policy.allowsAnimation == remaining.isEmpty)
        }
    }

    @Test("Wake and thermal recovery preserve a manual pause")
    func wakeDoesNotClearManualPause() {
        var policy = ActivityPolicy()
        policy.set(.userPaused, active: true)
        policy.set(.occluded, active: true)
        policy.set(.systemAsleep, active: true)
        policy.set(.displayAsleep, active: true)
        policy.set(.sessionInactive, active: true)
        policy.set(.thermalPressure, active: true)

        policy.set(.displayAsleep, active: false)
        #expect(policy.reasons.contains(.systemAsleep))
        #expect(!policy.allowsAnimation)
        policy.set(.systemAsleep, active: false)
        policy.set(.occluded, active: false)
        policy.set(.sessionInactive, active: false)
        policy.set(.thermalPressure, active: false)

        #expect(policy.reasons == [.userPaused])
        #expect(!policy.allowsAnimation)
        policy.set(.userPaused, active: false)
        #expect(policy.allowsAnimation)
    }

    @Test("Duplicate notifications require only one matching clear", arguments: SuspensionReason.allCases)
    func duplicateNotifications(reason: SuspensionReason) {
        var policy = ActivityPolicy()
        policy.set(reason, active: true)
        policy.set(reason, active: true)
        #expect(!policy.allowsAnimation)
        #expect(policy.reasons.count == 1)

        policy.set(reason, active: false)
        policy.set(reason, active: false)
        #expect(policy.allowsAnimation)
    }

    @Test("Showing a hidden pet does not resume its manually paused animation")
    func showKeepsPause() {
        var policy = ActivityPolicy(reasons: [.hidden, .userPaused])
        policy.set(.hidden, active: false)
        #expect(policy.reasons == [.userPaused])
        #expect(!policy.allowsAnimation)
    }
}
