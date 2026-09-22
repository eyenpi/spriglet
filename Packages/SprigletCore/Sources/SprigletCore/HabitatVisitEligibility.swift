/// A value-only gate for starting an explicit habitat visit. The application
/// supplies current facts at request time, so eligibility never needs a timer
/// or retained platform objects.
public struct HabitatVisitEligibility: Equatable, Sendable {
    public let isRunning: Bool
    public let isHidden: Bool
    public let isPaused: Bool
    public let isSystemSuspended: Bool
    public let isReduceMotionEnabled: Bool
    public let isLowPowerModeEnabled: Bool
    public let isOnActiveSpace: Bool
    public let isSleeping: Bool
    public let isAnimating: Bool
    public let isMoving: Bool
    public let isInteracting: Bool
    public let isSampling: Bool

    public init(
        isRunning: Bool,
        isHidden: Bool,
        isPaused: Bool,
        isSystemSuspended: Bool,
        isReduceMotionEnabled: Bool,
        isLowPowerModeEnabled: Bool,
        isOnActiveSpace: Bool,
        isSleeping: Bool,
        isAnimating: Bool,
        isMoving: Bool,
        isInteracting: Bool,
        isSampling: Bool
    ) {
        self.isRunning = isRunning
        self.isHidden = isHidden
        self.isPaused = isPaused
        self.isSystemSuspended = isSystemSuspended
        self.isReduceMotionEnabled = isReduceMotionEnabled
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isOnActiveSpace = isOnActiveSpace
        self.isSleeping = isSleeping
        self.isAnimating = isAnimating
        self.isMoving = isMoving
        self.isInteracting = isInteracting
        self.isSampling = isSampling
    }

    public var allowsExplicitVisit: Bool {
        isRunning && !isHidden && !isPaused && !isSystemSuspended
            && !isReduceMotionEnabled && !isLowPowerModeEnabled
            && isOnActiveSpace && !isSleeping && !isAnimating && !isMoving
            && !isInteracting && !isSampling
    }
}
