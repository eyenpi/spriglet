struct HomePeekState: Sendable {
    private static let intentRadius = 6.0
    private static let intentDuration = 0.08
    private static let minimumPeekDuration = 0.45
    private static let exitGraceDuration = 0.18
    private enum Phase: Sendable {
        case tucked
        case tracking(anchor: Point, age: Double)
        case revealed(age: Double, leaveAge: Double)
    }
    private var phase = Phase.tucked
    var isRevealed: Bool {
        if case .revealed = phase { return true }
        return false
    }

    mutating func pointerLeft() {
        if case .tracking = phase { phase = .tucked }
    }

    mutating func step(_ dt: Double, pointer: Point, isOver: Bool) {
        switch phase {
        case .tucked:
            if isOver { phase = .tracking(anchor: pointer, age: dt) }
        case .tracking(let anchor, let age):
            guard isOver else { phase = .tucked; return }
            // A passing pointer never settles inside this small neighborhood.
            if pointer.distance(to: anchor) > Self.intentRadius {
                phase = .tracking(anchor: pointer, age: dt)
            } else if age + dt >= Self.intentDuration {
                phase = .revealed(age: 0, leaveAge: 0)
            } else {
                phase = .tracking(anchor: anchor, age: age + dt)
            }
        case .revealed(let age, let leaveAge):
            let nextAge = age + dt
            let nextLeaveAge = isOver ? 0 : leaveAge + dt
            // Finish the peek before retreating, and forgive brief boundary exits.
            phase = nextAge >= Self.minimumPeekDuration && nextLeaveAge >= Self.exitGraceDuration
                ? .tucked : .revealed(age: nextAge, leaveAge: nextLeaveAge)
        }
    }
}
