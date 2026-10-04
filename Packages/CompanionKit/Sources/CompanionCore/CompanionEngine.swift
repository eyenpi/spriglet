import Foundation

/// One deterministic session owns all mutable character state. The host supplies
/// semantic input and elapsed time; it receives only immutable snapshots.
public struct CompanionEngine: Sendable {
    private var body: BodyPhysics
    private var interaction = InteractionState()
    private var animator = MotionAnimator()
    private var idle: IdleAnimation
    private var presentation = PoseDynamics()
    private var reveal = Spring(value: 0.6, frequency: 12, damping: 0.9)
    private var homeRetraction = Spring(value: 30, frequency: 12, damping: 0.9)
    private var homeGrip = Spring(value: 1, frequency: 14, damping: 1)
    private var gaze = Spring(frequency: 10, damping: 1)
    private var pointer = Point(x: -1000, y: -1000)
    private var remainder = 0.0
    public private(set) var time = 0.0
    public private(set) var motionPolicy = MotionPolicy.full
    public var isDragging: Bool { interaction.dragging }
    public var hasPointerCapture: Bool { interaction.press != nil }
    /// Hosts may supply a fresh session seed; previews and tests default to a
    /// repeatable sequence. The seed is the only external source of randomness.
    public init(scene: SceneGeometry, idleSeed: UInt64 = 0x4D414C4C4F57) {
        body = BodyPhysics(scene: scene); idle = IdleAnimation(seed: idleSeed)
    }
    public mutating func reconfigure(scene: SceneGeometry) {
        body = BodyPhysics(scene: scene); interaction = InteractionState()
        animator = MotionAnimator(); presentation = PoseDynamics()
        idle.reset()
        reveal = Spring(value: 0.6, frequency: 12, damping: 0.9); gaze = Spring(frequency: 10, damping: 1)
        homeRetraction = Spring(value: 30, frequency: 12, damping: 0.9)
        homeGrip = Spring(value: 1, frequency: 14, damping: 1)
        pointer = Point(x: -1000, y: -1000); remainder = 0
    }
    public mutating func setMotionPolicy(_ policy: MotionPolicy) {
        motionPolicy = policy
        if policy == .reduced {
            body.swing.value = 0; body.swing.speed = 0
            if body.isReturningHome { body.returnHome(immediately: true) }
        }
    }
    public mutating func send(_ input: CompanionInput) {
        switch input {
        case .pointerMoved(let point): if point.isFinite { pointer = point }
        case .pointerPressed(let point):
            guard point.isFinite else { return }; pointer = point
            if snapshot.contains(point) {
                interaction.press = point; interaction.dragging = false
                interaction.dragOffset = Point(x: point.x - snapshot.feet.x,
                                               y: point.y - snapshot.feet.y + SimulationTuning.grabWeightOffset * body.scene.scale)
            } else { returnHome() }
        case .pointerDragged(let point):
            guard point.isFinite, let start = interaction.press else { return }; pointer = point
            guard interaction.dragging || point.distance(to: start) > 4 else { return }
            interaction.dragging = true; interaction.play()
            var velocity = body.renderedVelocity
            velocity.y -= homeRetraction.speed * body.scene.scale
            body.grab(visibleFeet: snapshot.feet, visibleVelocity: velocity,
                      target: point - interaction.dragOffset, at: time)
            // The visible offset and its velocity now belong to the held body.
            homeRetraction.value = 0; homeRetraction.speed = 0
        case .pointerReleased(let point):
            guard interaction.press != nil else { return }
            let dragged = interaction.dragging; interaction.clearPress()
            if dragged { body.release() }
            else if point.isFinite && snapshot.contains(point) { activate() }
        case .cancelInteraction:
            reconfigure(scene: body.scene)
        case .outsidePressed:
            if !hasPointerCapture { returnHome() }
        case .activate: activate()
        case .command(let command): perform(command)
        }
    }
    private mutating func activate() {
        switch interaction.presence {
        case .peek: interaction.engage(at: time)
        case .engaged:
            let gesture: CharacterGesture = interaction.gesture == .hello ? .swing : .hello
            interaction.react(gesture, at: time)
            if gesture == .swing && motionPolicy == .full { body.swing.impulse(1.8) }
            body.compression.impulse(-1.2)
        case .playing: returnHome()
        }
    }
    private mutating func returnHome() {
        interaction.rest()
        if body.phase != .hanging && !body.isReturningHome {
            body.returnHome(immediately: motionPolicy == .reduced)
        }
    }
    private mutating func perform(_ command: CompanionCommand) {
        switch command {
        case .returnHome: interaction.clearPress(); returnHome()
        case .greet:
            body.returnHome(immediately: motionPolicy == .reduced); interaction.engage(at: time)
        case .swing, .stretch:
            body.returnHome(immediately: motionPolicy == .reduced); interaction.engage(at: time)
            interaction.react(command == .swing ? .swing : .stretch, at: time)
            if command == .swing && body.phase == .hanging && motionPolicy == .full { body.swing.impulse(1.8) }
        case .walk: if motionPolicy == .full { body.walk() }
        case .hop: if motionPolicy == .full { body.hop() }
        }
    }
    public mutating func advance(by elapsed: Double) {
        guard elapsed > 0 && elapsed.isFinite else { return }
        remainder += min(elapsed, SimulationTuning.maximumCatchUp)
        while remainder + 0.00000001 >= SimulationTuning.step {
            remainder = max(0, remainder - SimulationTuning.step)
            step(SimulationTuning.step)
        }
    }
    private mutating func step(_ dt: Double) {
        time += dt
        if interaction.step(dt, at: time, pointerOver: snapshot.contains(pointer)) { returnHome() }
        body.step(dt, at: time, walkingAmount: presentation.pose.walk)
        if body.phase == .hanging && interaction.presence == .playing { interaction.rest() }
        let openTarget = body.phase != .hanging || interaction.presence != .peek ? 1.0 : interaction.hoverAge > 0.35 ? 0.66 : 0.6
        reveal.step(dt, target: openTarget)
        homeRetraction.step(dt, target: body.phase == .hanging ? (1 - openTarget) * 75 : 0)
        homeGrip.step(dt, target: body.phase == .hanging || body.phase == .catching ? 1 : 0)
        let nearby = pointer.distance(to: snapshot.feet) < 260 * body.scene.scale
        idle.step(dt, quiet: body.phase == .hanging && interaction.presence == .peek && !hasPointerCapture && !nearby,
                  policy: motionPolicy)
        let look = nearby && motionPolicy == .full ? clamp((pointer.x - snapshot.feet.x) / 35, -5, 5) : 0
        gaze.step(dt, target: look)
        var desired = Motion.idle
        if body.phase == .hanging {
            switch interaction.gesture {
            case .hello: desired = .wave
            case .stretch: desired = .stretch
            default: break
            }
        } else if body.isWalking && body.phase == .grounded { desired = body.direction > 0 ? .walkRight : .walkLeft }
        if motionPolicy == .reduced { desired = .idle }
        if animator.motion != desired { animator.select(desired, at: time) }
        animator.advance(to: time, dt: dt, walkingAmount: presentation.pose.walk, idlePose: idle.pose)
        presentation.step(toward: targetPose, dt: dt)
    }
    private var targetPose: CharacterPose {
        var pose = animator.targetPose
        switch body.phase {
        case .hanging:
            pose.arm = interaction.gesture == .hello ? pose.arm : 0.4
            pose.facing = 0
        case .preparingJump:
            pose.height = 1 - body.anticipationProgress * 0.19
        case .jumping, .falling:
            let stretch = min(abs(body.velocity.y) / 1400, 1)
            pose.height = 1 + stretch * 0.13
            pose.arm = 0.55; pose.lean = clamp(body.velocity.x / 1800, -0.08, 0.08)
        case .held:
            pose.height = 1.13; pose.arm = body.canCatch ? 0.85 : 0.7
            pose.lookY = body.canCatch ? -5 : 0
        case .catching: pose.height = 1.08; pose.arm = 0.9
        case .grounded: break
        }
        pose.width = 1 / pose.height
        return pose
    }
    public var snapshot: CompanionSnapshot {
        let open = clamp(reveal.value, 0.6, 1), scene = body.scene
        var feet = body.renderedFeet - Point(x: 0, y: homeRetraction.value * scene.scale)
        var pose = presentation.pose
        // Reveal keeps evolving after a grab; removing this deformation at the
        // phase boundary would instantly change the silhouette and face height.
        pose.lookY += min(28, (1 - open) * 75)
        let squish = sin((1 - open) * .pi) * 0.1
        pose.width *= 1 + squish; pose.height /= 1 + squish
        let deformation = clamp(body.compression.value, -0.38, 0.2)
        pose.height *= 1 + deformation; pose.width /= 1 + deformation
        // Stretch the crown without pulling the eyes back behind the housing.
        pose.lookY += max(0, 47 * (1 - 1 / pose.height))
        pose.look += gaze.value
        if motionPolicy == .reduced {
            pose.width = 1; pose.height = 1; pose.lean = 0; pose.look = 0
            pose.arm = 0; pose.sparkle = 0
            feet = body.phase == .hanging ? Point(x: scene.homeFeet.x, y: scene.homeFeet.y - homeRetraction.value * scene.scale) : feet
        }
        return CompanionSnapshot(scene: scene, presence: interaction.presence, phase: body.phase, pose: pose,
                                 feet: feet, windowAnchor: body.renderedFeet, rotation: motionPolicy == .full ? body.rotation : 0,
                                 openness: open, homeGrip: clamp(homeGrip.value, 0, 1), time: time, gesture: interaction.gesture,
                                 canCatch: body.canCatch)
    }
}
