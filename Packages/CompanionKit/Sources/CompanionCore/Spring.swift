import Foundation

struct Spring: Sendable {
    var value: Double
    var speed: Double
    let frequency: Double
    let damping: Double
    init(value: Double = 0, speed: Double = 0, frequency: Double = 14, damping: Double = 0.58) {
        self.value = value; self.speed = speed; self.frequency = frequency; self.damping = damping
    }
    mutating func step(_ dt: Double, target: Double = 0) {
        speed += (frequency * frequency * (target - value) - 2 * damping * frequency * speed) * dt
        value += speed * dt
    }
    mutating func impulse(_ amount: Double) { speed += amount }
}

/// Shared timing and weight. Input thresholds live beside interaction state.
struct SimulationTuning: Sendable {
    static let step = 1 / 120.0
    static let maximumCatchUp = 0.25
    static let gravity = 1150.0
    static let dragFollowRate = 20.0
    static let grabWeightOffset = 18.0
    static let jumpAnticipation = 0.24
    static let walkingStride = 0.72
}
