import Foundation

/// Semantic pointer attention that is safe to leave the platform boundary.
/// It deliberately contains no screen coordinate or event object.
public enum PointerAttentionMode: Equatable, Sendable {
    case neutral
    case gaze
    case curious
    case departureHold
    case dwelling
}

/// A compact, coordinate-free description of how a companion may acknowledge
/// the latest pointer observation.
public struct PointerAttentionState: Equatable, Sendable {
    public let mode: PointerAttentionMode
    public let gaze: PointerVector
    public let lean: Double
    public let dwellDeadline: MonotonicTimestamp?
    public let departureDeadline: MonotonicTimestamp?

    public init(
        mode: PointerAttentionMode = .neutral,
        gaze: PointerVector = .zero,
        lean: Double = 0,
        dwellDeadline: MonotonicTimestamp? = nil,
        departureDeadline: MonotonicTimestamp? = nil
    ) {
        self.mode = mode
        self.gaze = gaze
        self.lean = lean.isFinite ? min(1, max(-1, lean)) : 0
        self.dwellDeadline = dwellDeadline
        self.departureDeadline = departureDeadline
    }

    public static let neutral = PointerAttentionState()
}

/// Product-tunable scalar thresholds for pure pointer attention.
public struct PointerAttentionConfiguration: Equatable, Sendable {
    public static let standard = PointerAttentionConfiguration(
        gazeRangePixels: 160,
        curiousDistance: 180,
        curiousApproachSpeed: 36,
        maximumCuriousApproachSpeed: 400,
        departureSpeed: 36,
        departureHoldDuration: 0.45
    )!

    public let gazeRangePixels: Double
    public let curiousDistance: Double
    public let curiousApproachSpeed: Double
    public let maximumCuriousApproachSpeed: Double
    public let departureSpeed: Double
    public let departureHoldDuration: TimeInterval

    public init?(
        gazeRangePixels: Double,
        curiousDistance: Double,
        curiousApproachSpeed: Double,
        maximumCuriousApproachSpeed: Double = 400,
        departureSpeed: Double,
        departureHoldDuration: TimeInterval
    ) {
        guard gazeRangePixels.isFinite, curiousDistance.isFinite,
              curiousApproachSpeed.isFinite, maximumCuriousApproachSpeed.isFinite,
              departureSpeed.isFinite,
              departureHoldDuration.isFinite,
              gazeRangePixels > 0, curiousDistance >= 0,
              curiousApproachSpeed >= 0,
              maximumCuriousApproachSpeed >= curiousApproachSpeed,
              departureSpeed >= 0,
              departureHoldDuration >= 0 else { return nil }
        self.gazeRangePixels = gazeRangePixels
        self.curiousDistance = curiousDistance
        self.curiousApproachSpeed = curiousApproachSpeed
        self.maximumCuriousApproachSpeed = maximumCuriousApproachSpeed
        self.departureSpeed = departureSpeed
        self.departureHoldDuration = departureHoldDuration
    }
}

/// Deterministic mapping from the latest pointer perception to safe companion
/// attention. A deadline caller uses `evaluate` to mature dwell and finish a
/// departure hold without inventing pointer samples.
public enum PointerAttention {
    public static func reduce(
        _ previous: PointerAttentionState,
        perception: PointerPerception,
        toward target: PointerPoint,
        at timestamp: MonotonicTimestamp,
        perceptionConfiguration: PointerPerceptionConfiguration = .standard,
        configuration: PointerAttentionConfiguration = .standard
    ) -> PointerAttentionState {
        let evaluated = perception.evaluatingDwell(at: timestamp, configuration: perceptionConfiguration)
        guard let latest = evaluated.latestSample,
              let distance = evaluated.distanceToTarget else { return .neutral }
        let gaze = normalizedGaze(from: latest.location, toward: target, range: configuration.gazeRangePixels)
        let dwellDeadline = evaluated.dwellDeadline(configuration: perceptionConfiguration)

        if evaluated.isDwelling {
            return PointerAttentionState(mode: .dwelling, gaze: gaze, dwellDeadline: dwellDeadline)
        }
        // A first point, timestamp discontinuity, or teleport still provides a
        // safe bounded gaze. Its cleared velocity must never trigger a motion
        // reaction from that same sample.
        guard !evaluated.didDiscontinue else {
            return evaluated.proximity == .near
                ? PointerAttentionState(mode: .gaze, gaze: gaze, dwellDeadline: dwellDeadline)
                : .neutral
        }
        if evaluated.radialVelocity <= -configuration.departureSpeed,
           evaluated.proximity == .near || previous.mode != .neutral {
            let deadline = MonotonicTimestamp(seconds: timestamp.seconds + configuration.departureHoldDuration)
            return PointerAttentionState(mode: .departureHold, gaze: gaze, departureDeadline: deadline)
        }
        let projectedApproachEntersRange = evaluated.radialVelocity > 0
            && (evaluated.projectedDistanceToTarget ?? .infinity) <= perceptionConfiguration.nearEnterDistance
        guard evaluated.proximity == .near || projectedApproachEntersRange else { return .neutral }
        if distance <= configuration.curiousDistance,
           evaluated.radialVelocity >= configuration.curiousApproachSpeed,
           evaluated.radialVelocity <= configuration.maximumCuriousApproachSpeed {
            let lean = min(1, evaluated.radialVelocity / max(configuration.curiousApproachSpeed * 3, 1))
            return PointerAttentionState(mode: .curious, gaze: gaze, lean: lean, dwellDeadline: dwellDeadline)
        }
        return PointerAttentionState(mode: .gaze, gaze: gaze, dwellDeadline: dwellDeadline)
    }

    public static func evaluate(
        _ state: PointerAttentionState,
        perception: PointerPerception,
        at timestamp: MonotonicTimestamp,
        perceptionConfiguration: PointerPerceptionConfiguration = .standard
    ) -> PointerAttentionState {
        if let deadline = state.dwellDeadline, timestamp >= deadline {
            return PointerAttentionState(
                mode: .dwelling,
                gaze: state.gaze,
                dwellDeadline: deadline
            )
        }
        if let deadline = state.departureDeadline, timestamp >= deadline {
            return .neutral
        }
        return state
    }

    private static func normalizedGaze(from point: PointerPoint, toward target: PointerPoint, range: Double) -> PointerVector {
        PointerVector(
            dx: min(1, max(-1, (point.x - target.x) / range)),
            dy: min(1, max(-1, (point.y - target.y) / range))
        )
    }
}
