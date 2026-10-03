/// A finite Hermite flight joins both position and velocity at either end.
/// Retargeting an airborne body uses its current velocity as the next launch.
struct JumpTrajectory: Sendable {
    let start: Point
    let end: Point
    let launchVelocity: Point
    let arrivalVelocity: Point
    let duration: Double

    func sample(at elapsed: Double) -> (position: Point, velocity: Point) {
        let u = clamp(elapsed / duration, 0, 1)
        let u2 = u * u, u3 = u2 * u
        let position = start * (2 * u3 - 3 * u2 + 1)
            + launchVelocity * ((u3 - 2 * u2 + u) * duration)
            + end * (-2 * u3 + 3 * u2)
            + arrivalVelocity * ((u3 - u2) * duration)
        let velocity = start * ((6 * u2 - 6 * u) / duration)
            + launchVelocity * (3 * u2 - 4 * u + 1)
            + end * ((-6 * u2 + 6 * u) / duration)
            + arrivalVelocity * (3 * u2 - 2 * u)
        return (position, velocity)
    }
}
