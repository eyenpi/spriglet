public enum MotionPolicy: Sendable { case full, reduced }
public enum ThermalPressure: Sendable { case normal, serious, critical }

/// The platform adapter reports conditions; a pure policy decides frame cadence.
public struct RuntimeConditions: Equatable, Sendable {
    public var displayAwake = true
    public var sessionActive = true
    public var lowPower = false
    public var reduceMotion = false
    public var thermal = ThermalPressure.normal
    public init() {}
    public var maximumFrameRate: Float {
        guard displayAwake && sessionActive && thermal != .critical else { return 0 }
        if thermal == .serious || reduceMotion { return 15 }
        return lowPower ? 30 : 60
    }
    public var isSuspended: Bool { maximumFrameRate == 0 }
    public func frameRate(presence: Presence, phase: BodyPhase) -> Float {
        // A resting peek has slow breathing. Keep flights and grabs smooth even
        // when presence has already returned to peek. Grounded walking keeps 30.
        if presence == .peek && phase == .hanging {
            return min(maximumFrameRate, lowPower ? 15 : 20)
        }
        return min(maximumFrameRate, phase == .grounded ? 30 : 60)
    }
}
