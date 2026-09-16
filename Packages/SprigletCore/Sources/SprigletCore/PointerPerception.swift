import Foundation

/// A finite screen-coordinate point. Pointer coordinates are ephemeral input to
/// a perception reducer; callers must not persist or log them.
public struct PointerPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = x
        self.y = y
    }

    public func distance(to other: Self) -> Double {
        hypot(other.x - x, other.y - y)
    }
}

/// A bounded pointer observation from a monotonic clock.
public struct PointerSample: Equatable, Sendable {
    public let timestamp: MonotonicTimestamp
    public let location: PointerPoint

    public init(timestamp: MonotonicTimestamp, location: PointerPoint) {
        self.timestamp = timestamp
        self.location = location
    }
}

/// A derived vector, never a retained input history.
public struct PointerVector: Equatable, Sendable {
    public static let zero = PointerVector(dx: 0, dy: 0)

    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx.isFinite ? dx : 0
        self.dy = dy.isFinite ? dy : 0
    }

    public var magnitude: Double {
        hypot(dx, dy)
    }
}

/// The hysteretic pointer proximity classification for a pet target.
public enum PointerProximity: Equatable, Sendable {
    case far
    case near
}

/// Thresholds for the pure pointer-perception reducer.
///
/// These are deliberately data rather than behavior rules. Product tuning can
/// change them without changing how raw platform events are captured.
public struct PointerPerceptionConfiguration: Equatable, Sendable {
    public static let standard = PointerPerceptionConfiguration(
        nearEnterDistance: 180,
        nearExitDistance: 220,
        dwellEnterDistance: 96,
        dwellExitDistance: 120,
        dwellDuration: 0.8,
        maximumSampleGap: 0.75,
        teleportDistance: 480,
        projectionHorizon: 0.35,
        maximumDwellSpeed: 12
    )!

    public let nearEnterDistance: Double
    public let nearExitDistance: Double
    public let dwellEnterDistance: Double
    public let dwellExitDistance: Double
    public let dwellDuration: TimeInterval
    public let maximumSampleGap: TimeInterval
    public let teleportDistance: Double
    public let projectionHorizon: TimeInterval
    public let maximumDwellSpeed: Double

    public init?(
        nearEnterDistance: Double,
        nearExitDistance: Double,
        dwellEnterDistance: Double,
        dwellExitDistance: Double,
        dwellDuration: TimeInterval,
        maximumSampleGap: TimeInterval,
        teleportDistance: Double,
        projectionHorizon: TimeInterval,
        maximumDwellSpeed: Double = 12
    ) {
        guard nearEnterDistance.isFinite, nearExitDistance.isFinite,
              dwellEnterDistance.isFinite, dwellExitDistance.isFinite,
              dwellDuration.isFinite, maximumSampleGap.isFinite,
              teleportDistance.isFinite, projectionHorizon.isFinite,
              maximumDwellSpeed.isFinite,
              nearEnterDistance >= 0, nearExitDistance >= nearEnterDistance,
              dwellEnterDistance >= 0, dwellExitDistance >= dwellEnterDistance,
              dwellDuration >= 0, maximumSampleGap > 0,
              teleportDistance > 0, projectionHorizon >= 0,
              maximumDwellSpeed >= 2
        else { return nil }

        self.nearEnterDistance = nearEnterDistance
        self.nearExitDistance = nearExitDistance
        self.dwellEnterDistance = dwellEnterDistance
        self.dwellExitDistance = dwellExitDistance
        self.dwellDuration = dwellDuration
        self.maximumSampleGap = maximumSampleGap
        self.teleportDistance = teleportDistance
        self.projectionHorizon = projectionHorizon
        self.maximumDwellSpeed = maximumDwellSpeed
    }
}

/// Immutable perception facts derived from the latest pointer sample.
///
/// `latestSample` is the only retained coordinate. Velocity, projection and
/// dwell metadata are scalars derived as each new sample replaces the old one.
public struct PointerPerception: Equatable, Sendable {
    public let latestSample: PointerSample?
    public let velocity: PointerVector
    public let distanceToTarget: Double?
    /// Signed motion along the line toward the target. Positive values approach;
    /// negative values depart, so callers can distinguish departure from a
    /// stationary or tangential pass.
    public let radialVelocity: Double
    public let approachSpeed: Double
    public let projectedDistanceToTarget: Double?
    public let proximity: PointerProximity
    public let dwellStartedAt: MonotonicTimestamp?
    public let isDwelling: Bool
    public let didDiscontinue: Bool

    public init(
        latestSample: PointerSample? = nil,
        velocity: PointerVector = .zero,
        distanceToTarget: Double? = nil,
        radialVelocity: Double = 0,
        approachSpeed: Double = 0,
        projectedDistanceToTarget: Double? = nil,
        proximity: PointerProximity = .far,
        dwellStartedAt: MonotonicTimestamp? = nil,
        isDwelling: Bool = false,
        didDiscontinue: Bool = false
    ) {
        self.latestSample = latestSample
        self.velocity = velocity
        self.distanceToTarget = distanceToTarget
        self.radialVelocity = radialVelocity.isFinite ? radialVelocity : 0
        self.approachSpeed = approachSpeed
        self.projectedDistanceToTarget = projectedDistanceToTarget
        self.proximity = proximity
        self.dwellStartedAt = dwellStartedAt
        self.isDwelling = isDwelling
        self.didDiscontinue = didDiscontinue
    }

    /// Reduces one newest-only sample into perception facts for a target point.
    /// Older timestamps are ignored. A long gap with movement, a zero elapsed
    /// interval, or a teleport clears motion and dwell state instead of
    /// inferring a reaction. A long gap at the identical point preserves a
    /// legitimate stationary dwell while still clearing inferred velocity.
    public static func reduce(
        _ previous: Self,
        sample: PointerSample,
        toward target: PointerPoint,
        configuration: PointerPerceptionConfiguration = .standard
    ) -> Self {
        if let previousSample = previous.latestSample,
           sample.timestamp < previousSample.timestamp {
            return previous
        }

        let distance = sample.location.distance(to: target)
        guard distance.isFinite else {
            return discontinuity(sample: sample)
        }
        let elapsed: TimeInterval?
        let moved: Double?
        if let previousSample = previous.latestSample {
            elapsed = sample.timestamp.seconds - previousSample.timestamp.seconds
            moved = sample.location.distance(to: previousSample.location)
        } else {
            elapsed = nil
            moved = nil
        }

        let isDiscontinuous: Bool
        if let elapsed, let moved {
            isDiscontinuous = elapsed <= 0
                || !moved.isFinite
                || moved > configuration.teleportDistance
                || (elapsed > configuration.maximumSampleGap && moved > 0)
        } else {
            isDiscontinuous = false
        }

        let velocity: PointerVector
        if let previousSample = previous.latestSample,
           let elapsed,
           elapsed > 0,
           !isDiscontinuous {
            let dx = (sample.location.x - previousSample.location.x) / elapsed
            let dy = (sample.location.y - previousSample.location.y) / elapsed
            guard dx.isFinite, dy.isFinite else {
                return discontinuity(sample: sample)
            }
            velocity = PointerVector(dx: dx, dy: dy)
        } else {
            velocity = .zero
        }

        let directionToTarget: PointerVector
        if distance > 0 {
            directionToTarget = PointerVector(
                dx: (target.x - sample.location.x) / distance,
                dy: (target.y - sample.location.y) / distance
            )
        } else {
            directionToTarget = .zero
        }
        let radialVelocity = velocity.dx * directionToTarget.dx + velocity.dy * directionToTarget.dy
        guard radialVelocity.isFinite else {
            return discontinuity(sample: sample)
        }
        let projectedValue = distance - radialVelocity * configuration.projectionHorizon
        guard projectedValue.isFinite else {
            return discontinuity(sample: sample)
        }
        let approachSpeed = max(0, radialVelocity)
        let projectedDistance = max(0, projectedValue)

        let proximity: PointerProximity
        switch previous.proximity {
        case .far:
            proximity = distance <= configuration.nearEnterDistance ? .near : .far
        case .near:
            proximity = distance <= configuration.nearExitDistance ? .near : .far
        }

        let isWithinDwellRange = previous.dwellStartedAt != nil
            ? distance <= configuration.dwellExitDistance
            : distance <= configuration.dwellEnterDistance
        let resetsDwellClock = isDiscontinuous || velocity.magnitude > configuration.maximumDwellSpeed
        let dwellStartedAt: MonotonicTimestamp?
        if isWithinDwellRange {
            dwellStartedAt = resetsDwellClock ? sample.timestamp : (previous.dwellStartedAt ?? sample.timestamp)
        } else {
            dwellStartedAt = nil
        }
        let isDwelling: Bool
        if let dwellStartedAt {
            isDwelling = sample.timestamp.seconds - dwellStartedAt.seconds >= configuration.dwellDuration
        } else {
            isDwelling = false
        }

        return Self(
            latestSample: sample,
            velocity: velocity,
            distanceToTarget: distance,
            radialVelocity: radialVelocity,
            approachSpeed: approachSpeed,
            projectedDistanceToTarget: projectedDistance,
            proximity: proximity,
            dwellStartedAt: dwellStartedAt,
            isDwelling: isDwelling,
            didDiscontinue: isDiscontinuous
        )
    }

    /// Removes the sole retained coordinate when the source is stopped.
    public static let empty = PointerPerception()

    /// Advances only the stationary-dwell fact for an explicit monotonic time.
    /// The latest coordinate remains unchanged: an event-driven source has no
    /// reason to manufacture another sample while the pointer is still.
    public func evaluatingDwell(
        at timestamp: MonotonicTimestamp,
        configuration: PointerPerceptionConfiguration = .standard
    ) -> Self {
        guard let latestSample, timestamp >= latestSample.timestamp,
              let dwellStartedAt, !didDiscontinue else { return self }
        let elapsed = timestamp.seconds - dwellStartedAt.seconds
        guard elapsed.isFinite else { return Self.discontinuity(sample: latestSample) }
        let isDwelling = elapsed >= configuration.dwellDuration
        guard isDwelling != self.isDwelling else { return self }
        return Self(
            latestSample: latestSample,
            velocity: velocity,
            distanceToTarget: distanceToTarget,
            radialVelocity: radialVelocity,
            approachSpeed: approachSpeed,
            projectedDistanceToTarget: projectedDistanceToTarget,
            proximity: proximity,
            dwellStartedAt: dwellStartedAt,
            isDwelling: isDwelling,
            didDiscontinue: didDiscontinue
        )
    }

    public func dwellDeadline(
        configuration: PointerPerceptionConfiguration = .standard
    ) -> MonotonicTimestamp? {
        guard let dwellStartedAt else { return nil }
        return MonotonicTimestamp(seconds: dwellStartedAt.seconds + configuration.dwellDuration)
    }

    private static func discontinuity(sample: PointerSample) -> Self {
        Self(latestSample: sample, didDiscontinue: true)
    }
}
