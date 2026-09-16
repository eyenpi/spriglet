import Testing
@testable import SprigletCore

@Suite("Pure pointer perception")
struct PointerPerceptionTests {
    private let target = PointerPoint(x: 0, y: 0)!

    private func time(_ seconds: Double) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: seconds)!
    }

    private func sample(_ seconds: Double, _ x: Double, _ y: Double = 0) -> PointerSample {
        PointerSample(timestamp: time(seconds), location: PointerPoint(x: x, y: y)!)
    }

    @Test("Approach is the pointer velocity projected toward the target")
    func approachProjection() throws {
        let configuration = try #require(PointerPerceptionConfiguration(
            nearEnterDistance: 20, nearExitDistance: 30,
            dwellEnterDistance: 10, dwellExitDistance: 12,
            dwellDuration: 1, maximumSampleGap: 2,
            teleportDistance: 500, projectionHorizon: 0.5
        ))
        let first = PointerPerception.reduce(.empty, sample: sample(1, 100), toward: target, configuration: configuration)
        let approaching = PointerPerception.reduce(first, sample: sample(2, 80), toward: target, configuration: configuration)
        let departing = PointerPerception.reduce(approaching, sample: sample(3, 100), toward: target, configuration: configuration)

        #expect(approaching.velocity == PointerVector(dx: -20, dy: 0))
        #expect(approaching.radialVelocity == 20)
        #expect(approaching.approachSpeed == 20)
        #expect(approaching.distanceToTarget == 80)
        #expect(approaching.projectedDistanceToTarget == 70)
        #expect(departing.approachSpeed == 0)
        #expect(departing.radialVelocity == -20)
        #expect(departing.projectedDistanceToTarget == 110)
    }

    @Test("Approach remains stable at irregular delivered sample rates", arguments: [30, 60, 120, 240])
    func approachAcrossSampleRates(hertz: Int) throws {
        let configuration = try #require(PointerPerceptionConfiguration(
            nearEnterDistance: 200, nearExitDistance: 220,
            dwellEnterDistance: 20, dwellExitDistance: 30,
            dwellDuration: 1, maximumSampleGap: 1,
            teleportDistance: 500, projectionHorizon: 0.25
        ))
        let interval = 1 / Double(hertz)
        let first = PointerPerception.reduce(.empty, sample: sample(0, 100), toward: target, configuration: configuration)
        let second = PointerPerception.reduce(
            first,
            sample: sample(interval, 100 - 20 * interval),
            toward: target,
            configuration: configuration
        )

        #expect(abs(second.approachSpeed - 20) < 0.000_001)
        #expect(second.didDiscontinue == false)
    }

    @Test("Near and dwell thresholds use independent hysteresis")
    func proximityAndDwellHysteresis() throws {
        let configuration = try #require(PointerPerceptionConfiguration(
            nearEnterDistance: 100, nearExitDistance: 120,
            dwellEnterDistance: 20, dwellExitDistance: 30,
            dwellDuration: 1, maximumSampleGap: 3,
            teleportDistance: 500, projectionHorizon: 0
        ))
        var perception = PointerPerception.empty
        perception = PointerPerception.reduce(perception, sample: sample(1, 99), toward: target, configuration: configuration)
        #expect(perception.proximity == .near)
        perception = PointerPerception.reduce(perception, sample: sample(1.2, 115), toward: target, configuration: configuration)
        #expect(perception.proximity == .near)
        perception = PointerPerception.reduce(perception, sample: sample(1.4, 121), toward: target, configuration: configuration)
        #expect(perception.proximity == .far)

        perception = PointerPerception.reduce(perception, sample: sample(2, 15), toward: target, configuration: configuration)
        #expect(!perception.isDwelling)
        perception = PointerPerception.reduce(perception, sample: sample(2.8, 25), toward: target, configuration: configuration)
        #expect(!perception.isDwelling)
        perception = PointerPerception.reduce(perception, sample: sample(3.1, 25), toward: target, configuration: configuration)
        #expect(!perception.isDwelling)
        perception = PointerPerception.reduce(perception, sample: sample(3.8, 25), toward: target, configuration: configuration)
        #expect(perception.isDwelling)
        perception = PointerPerception.reduce(perception, sample: sample(3.9, 31), toward: target, configuration: configuration)
        #expect(!perception.isDwelling)
        #expect(perception.dwellStartedAt == nil)
    }

    @Test("Meaningful motion resets dwell while small jitter retains it")
    func motionResetsDwell() throws {
        let configuration = try #require(PointerPerceptionConfiguration(
            nearEnterDistance: 100, nearExitDistance: 120,
            dwellEnterDistance: 40, dwellExitDistance: 50,
            dwellDuration: 0.8, maximumSampleGap: 1,
            teleportDistance: 500, projectionHorizon: 0,
            maximumDwellSpeed: 12
        ))
        var perception = PointerPerception.reduce(
            .empty, sample: sample(0, 30), toward: target, configuration: configuration
        )
        perception = PointerPerception.reduce(
            perception, sample: sample(0.1, 28), toward: target, configuration: configuration
        )
        #expect(perception.dwellStartedAt == time(0.1))
        perception = PointerPerception.reduce(
            perception, sample: sample(0.2, 27.5), toward: target, configuration: configuration
        )
        #expect(perception.dwellStartedAt == time(0.1))
        #expect(!perception.isDwelling)
        #expect(perception.evaluatingDwell(at: time(0.9), configuration: configuration).isDwelling)
    }

    @Test("Teleports and irregular timestamps clear inferred motion and retain only the latest point")
    func discontinuities() throws {
        let configuration = try #require(PointerPerceptionConfiguration(
            nearEnterDistance: 100, nearExitDistance: 120,
            dwellEnterDistance: 20, dwellExitDistance: 30,
            dwellDuration: 1, maximumSampleGap: 0.5,
            teleportDistance: 100, projectionHorizon: 0.25
        ))
        var perception = PointerPerception.reduce(.empty, sample: sample(1, 10), toward: target, configuration: configuration)
        perception = PointerPerception.reduce(perception, sample: sample(1.1, 0), toward: target, configuration: configuration)
        perception = PointerPerception.reduce(perception, sample: sample(1.2, 500), toward: target, configuration: configuration)
        #expect(perception.didDiscontinue)
        #expect(perception.velocity == .zero)
        #expect(perception.approachSpeed == 0)
        #expect(perception.dwellStartedAt == nil)
        #expect(perception.latestSample == sample(1.2, 500))

        let stale = PointerPerception.reduce(perception, sample: sample(1.1, 2), toward: target, configuration: configuration)
        #expect(stale == perception)
        let afterGap = PointerPerception.reduce(perception, sample: sample(2, 490), toward: target, configuration: configuration)
        #expect(afterGap.didDiscontinue)
        #expect(afterGap.velocity == .zero)
    }

    @Test("Malformed configurations fail before reaching the reducer")
    func malformedConfiguration() {
        #expect(PointerPerceptionConfiguration(
            nearEnterDistance: 100, nearExitDistance: 90,
            dwellEnterDistance: 10, dwellExitDistance: 20,
            dwellDuration: 1, maximumSampleGap: 1,
            teleportDistance: 100, projectionHorizon: 0
        ) == nil)
        #expect(PointerPerceptionConfiguration(
            nearEnterDistance: 100, nearExitDistance: 120,
            dwellEnterDistance: 10, dwellExitDistance: 20,
            dwellDuration: 1, maximumSampleGap: 1,
            teleportDistance: 100, projectionHorizon: 0,
            maximumDwellSpeed: 1.9
        ) == nil)
    }

    @Test("Overflowing coordinate and velocity math fails closed without retaining history")
    func numericOverflow() throws {
        let permissive = try #require(PointerPerceptionConfiguration(
            nearEnterDistance: 100, nearExitDistance: 120,
            dwellEnterDistance: 20, dwellExitDistance: 30,
            dwellDuration: 1, maximumSampleGap: Double.greatestFiniteMagnitude,
            teleportDistance: Double.greatestFiniteMagnitude, projectionHorizon: 1
        ))
        let huge = Double.greatestFiniteMagnitude
        let overflowingDistance = PointerPerception.reduce(
            .empty, sample: sample(1, huge), toward: PointerPoint(x: -huge, y: 0)!, configuration: permissive
        )
        #expect(overflowingDistance.didDiscontinue)
        #expect(overflowingDistance.distanceToTarget == nil)
        #expect(overflowingDistance.velocity == .zero)
        #expect(overflowingDistance.radialVelocity == 0)
        #expect(overflowingDistance.latestSample == sample(1, huge))

        let first = PointerPerception.reduce(.empty, sample: sample(0, 0), toward: target, configuration: permissive)
        let overflowingVelocity = PointerPerception.reduce(
            first,
            sample: sample(Double.leastNonzeroMagnitude, 1), toward: target, configuration: permissive
        )
        #expect(overflowingVelocity.didDiscontinue)
        #expect(overflowingVelocity.velocity == .zero)
        #expect(overflowingVelocity.distanceToTarget == nil)
    }

    @Test("Invalid coordinate and monotonic timestamp values are rejected before reduction")
    func invalidInputValues() {
        #expect(PointerPoint(x: .nan, y: 0) == nil)
        #expect(PointerPoint(x: .infinity, y: 0) == nil)
        #expect(MonotonicTimestamp(seconds: -.leastNonzeroMagnitude) == nil)
        #expect(MonotonicTimestamp(seconds: .infinity) == nil)
    }
}
