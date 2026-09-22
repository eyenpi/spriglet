import CoreGraphics
import Testing
@testable import SprigletCore

@Suite("Habitat visit eligibility")
struct HabitatVisitEligibilityTests {
    @Test("Explicit visits require a quiet visible motion context")
    func explicitVisitGate() {
        let ready = eligibility()
        #expect(ready.allowsExplicitVisit)
        #expect(!eligibility(isHidden: true).allowsExplicitVisit)
        #expect(!eligibility(isPaused: true).allowsExplicitVisit)
        #expect(!eligibility(isReduceMotionEnabled: true).allowsExplicitVisit)
        #expect(!eligibility(isAnimating: true).allowsExplicitVisit)
        #expect(!eligibility(isSleeping: true).allowsExplicitVisit)
        #expect(!eligibility(isOnActiveSpace: false).allowsExplicitVisit)
        #expect(!eligibility(isSystemSuspended: true).allowsExplicitVisit)
        #expect(!eligibility(isLowPowerModeEnabled: true).allowsExplicitVisit)
        #expect(!eligibility(isMoving: true).allowsExplicitVisit)
        #expect(!eligibility(isInteracting: true).allowsExplicitVisit)
        #expect(!eligibility(isSampling: true).allowsExplicitVisit)
        #expect(!eligibility(isRunning: false).allowsExplicitVisit)
    }

    @Test("The measured portal contract follows all supported window scales")
    func scaledArtContract() throws {
        for side in [CGFloat(72), 96, 120, 168, 224, 280] {
            let scaled = try #require(
                HabitatPortalArtGeometry.acornStandard.scaled(
                    toPortalWindowSize: CGSize(width: side, height: side)
                )
            )
            #expect(scaled.portalWindowSize == CGSize(width: side, height: side))
            #expect(scaled.gripOffsetFromWindowTop >= scaled.requiredHeadClearance)
        }
        #expect(HabitatPortalArtGeometry.acornStandard.scaled(
            toPortalWindowSize: CGSize(width: 96, height: 120)
        ) == nil)
    }

    private func eligibility(
        isRunning: Bool = true,
        isHidden: Bool = false,
        isPaused: Bool = false,
        isSystemSuspended: Bool = false,
        isReduceMotionEnabled: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        isOnActiveSpace: Bool = true,
        isSleeping: Bool = false,
        isAnimating: Bool = false,
        isMoving: Bool = false,
        isInteracting: Bool = false,
        isSampling: Bool = false
    ) -> HabitatVisitEligibility {
        HabitatVisitEligibility(
            isRunning: isRunning,
            isHidden: isHidden,
            isPaused: isPaused,
            isSystemSuspended: isSystemSuspended,
            isReduceMotionEnabled: isReduceMotionEnabled,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            isOnActiveSpace: isOnActiveSpace,
            isSleeping: isSleeping,
            isAnimating: isAnimating,
            isMoving: isMoving,
            isInteracting: isInteracting,
            isSampling: isSampling
        )
    }
}
