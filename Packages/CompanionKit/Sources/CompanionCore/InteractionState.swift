struct InteractionState: Sendable {
    private(set) var presence = Presence.peek
    private(set) var gesture: CharacterGesture?
    private(set) var gestureStarted = 0.0
    private(set) var invitedAt = 0.0
    var hoverAge = 0.0
    private var leaveAge = 0.0
    var press: Point?
    var dragOffset = Point.zero
    var dragging = false
    mutating func engage(at time: Double) {
        presence = .engaged; invitedAt = time; leaveAge = 0
        react(.hello, at: time)
    }
    mutating func react(_ gesture: CharacterGesture, at time: Double) {
        self.gesture = gesture; gestureStarted = time; invitedAt = time
    }
    mutating func play() { presence = .playing; gesture = nil }
    mutating func rest() {
        presence = .peek; gesture = nil; hoverAge = 0; leaveAge = 0
    }
    mutating func clearPress() { press = nil; dragging = false }
    mutating func step(_ dt: Double, at time: Double, pointerOver: Bool) -> Bool {
        hoverAge = pointerOver ? hoverAge + dt : 0
        leaveAge = pointerOver ? 0 : leaveAge + dt
        if let gesture {
            let duration: Double = switch gesture { case .hello: 4; case .swing: 6; case .stretch: 5 }
            if time - gestureStarted >= duration { self.gesture = nil }
        }
        return presence == .engaged && press == nil && leaveAge > 1.2 && time - invitedAt > 4.5
    }
}
