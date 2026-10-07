import Foundation

/// One deterministic session owns all mutable character state. The host supplies
/// semantic input and elapsed time; it receives only immutable snapshots.
public struct CompanionEngine: Sendable {
    private var body: BodyPhysics
    private var interaction = InteractionState()
    private var animator = MotionAnimator()
    private var idle: IdleAnimation
    private var boredom: BoredomState
    private var idleOffset = Spring(frequency: 18, damping: 1)
    private var idleMomentsEnabled = true
    private var idleCadence: Double { movementAmount < 0.5 ? 2 : 1 }
    public var requestedIdleMoment: IdleMoment? { boredom.requestedMoment }
    private var presentation = PoseDynamics()
    private var reveal = Spring(value: 0.6, frequency: 12, damping: 0.9)
    private var homeRetraction = Spring(value: 30, frequency: 12, damping: 0.9)
    private var homeGrip = Spring(value: 1, frequency: 14, damping: 1)
    private var attachmentX = Spring(frequency: 12, damping: 1)
    private var attachmentY = Spring(frequency: 12, damping: 1)
    private var attachmentTarget = Point.zero
    private var gaze = Spring(frequency: 10, damping: 1)
    private var pointer = Point(x: -1000, y: -1000)
    private var dragGeometry: DragGeometry?
    private var remainder = 0.0
    public private(set) var time = 0.0
    public private(set) var motionPolicy = MotionPolicy.full
    public private(set) var movementAmount = 1.0
    public var isDragging: Bool { interaction.dragging }
    public var hasPointerCapture: Bool { interaction.press != nil }
    public var hasPendingDragRelease: Bool { body.isPendingRelease }
    /// Hosts may supply a fresh session seed; previews and tests default to a
    /// repeatable sequence. The seed is the only external source of randomness.
    public init(scene: SceneGeometry, idleSeed: UInt64 = 0x4D414C4C4F57, boredomTiming: BoredomTiming = BoredomTiming()) {
        body = BodyPhysics(scene: scene); idle = IdleAnimation(seed: idleSeed)
        boredom = BoredomState(seed: idleSeed, timing: boredomTiming)
        attachmentX = Spring(value: scene.home.midX, frequency: 12, damping: 1)
        attachmentY = Spring(value: scene.home.maxY, frequency: 12, damping: 1)
        attachmentTarget = Point(x: scene.home.midX, y: scene.home.maxY)
    }
    public mutating func reconfigure(scene: SceneGeometry) {
        body = BodyPhysics(scene: scene); interaction = InteractionState()
        animator = MotionAnimator(); presentation = PoseDynamics()
        idle.reset(); boredom.interrupt(at: time, cadence: idleCadence); idleOffset = Spring(frequency: 18, damping: 1)
        reveal = Spring(value: 0.6, frequency: 12, damping: 0.9); gaze = Spring(frequency: 10, damping: 1)
        homeRetraction = Spring(value: 30, frequency: 12, damping: 0.9)
        homeGrip = Spring(value: 1, frequency: 14, damping: 1)
        attachmentX = Spring(value: scene.home.midX, frequency: 12, damping: 1)
        attachmentY = Spring(value: scene.home.maxY, frequency: 12, damping: 1)
        attachmentTarget = Point(x: scene.home.midX, y: scene.home.maxY)
        pointer = Point(x: -1000, y: -1000); remainder = 0
        dragGeometry = nil
    }
    /// Called after native hit testing accepts the press; geometry is immutable and finite.
    @discardableResult public mutating func beginDesktopDrag(geometry: DragGeometry) -> Bool {
        guard hasPointerCapture, geometry.isValid else { return false }
        dragGeometry = geometry; body.beginDesktopDrag(heldBounds: geometry.heldBounds)
        return true
    }
    @discardableResult public mutating func updateDesktopDragGeometry(_ geometry: DragGeometry) -> Bool {
        guard hasPointerCapture, geometry.isValid else { return false }
        dragGeometry = geometry; body.updateDesktopDragBounds(geometry.heldBounds)
        return true
    }
    public mutating func endDesktopDrag() { dragGeometry = nil; body.endDesktopDrag() }
    /// Translate every position in the active drag frame while retaining all motion history.
    @discardableResult public mutating func transferDrag(scene: SceneGeometry, translation: Point,
                                                          geometry: DragGeometry) -> Bool {
        guard isDragging, hasPointerCapture, translation.isFinite, geometry.isValid,
              scene.scale == body.scene.scale, (pointer + translation).isFinite,
              (attachmentTarget + translation).isFinite,
              (attachmentX.value + translation.x).isFinite,
              (attachmentY.value + translation.y).isFinite else { return false }
        if let press = interaction.press, !(press + translation).isFinite { return false }
        guard body.transferDrag(scene: scene, translation: translation, heldBounds: geometry.heldBounds) else { return false }
        if let press = interaction.press { interaction.press = press + translation }
        pointer = pointer + translation
        attachmentX.value += translation.x; attachmentY.value += translation.y
        attachmentTarget = attachmentTarget + translation
        dragGeometry = geometry
        return true
    }
    public mutating func setIdleMomentsEnabled(_ enabled: Bool) {
        idleMomentsEnabled = enabled
        if !enabled { boredom.interrupt(at: time, cadence: idleCadence) }
    }
    public mutating func setMotionPolicy(_ policy: MotionPolicy) {
        guard motionPolicy != policy else { return }
        motionPolicy = policy
        if policy == .reduced { boredom.interrupt(at: time, cadence: idleCadence); idleOffset = Spring(frequency: 18, damping: 1) }
        if policy == .reduced {
            body.swing.value = 0; body.swing.speed = 0
            // Keep a deliberate grab, but stop autonomous walking, hopping,
            // falling, catch settling and residual pendulum motion immediately.
            if body.phase != .held {
                body = BodyPhysics(scene: body.scene)
                if interaction.presence == .playing { interaction.rest() }
            }
            if body.isPendingRelease {
                body.returnHome(immediately: true); endDesktopDrag()
            }
            if !hasPointerCapture {
                attachmentTarget = Point(x: body.scene.home.midX, y: body.scene.home.maxY)
                attachmentX.value = attachmentTarget.x; attachmentX.speed = 0
                attachmentY.value = attachmentTarget.y; attachmentY.speed = 0
            }
            updateHomePresentation(SimulationTuning.step)
        }
    }
    /// Amplitude of authored motion, independent of native settings/storage.
    /// Pointer-driven physics and catch geometry keep their normal responsiveness.
    public mutating func setMovementAmount(_ amount: Double) {
        guard amount.isFinite else { return }
        let next = clamp(amount, 0, 1.5)
        if movementAmount > 0 {
            let ratio = next / movementAmount
            body.swing.value *= ratio; body.swing.speed *= ratio
        }
        movementAmount = next
        boredom.interrupt(at: time, cadence: idleCadence)
    }
    public mutating func send(_ input: CompanionInput) {
        switch input {
        case .pointerMoved(let point):
            if point.isFinite {
                pointer = point
                if snapshot.contains(point) { boredom.interrupt(at: time, cadence: idleCadence) }
            }
        case .pointerPressed(let point):
            guard point.isFinite else { return }; pointer = point
            if snapshot.contains(point) {
                boredom.interrupt(at: time, cadence: idleCadence)
                interaction.press = point; interaction.dragging = false
                interaction.dragOffset = Point(x: point.x - snapshot.feet.x,
                                               y: point.y - snapshot.feet.y + SimulationTuning.grabWeightOffset * body.scene.scale)
            } else { returnHome() }
        case .pointerDragged(let point):
            guard point.isFinite, let start = interaction.press else { return }; pointer = point
            guard interaction.dragging || point.distance(to: start) > 4 else { return }
            boredom.interrupt(at: time, cadence: idleCadence)
            interaction.dragging = true; interaction.play()
            var velocity = body.renderedVelocity
            velocity.x += idleOffset.speed * body.scene.scale
            velocity.y -= homeRetraction.speed * body.scene.scale
            body.grab(visibleFeet: snapshot.feet, visibleVelocity: velocity,
                      target: point - interaction.dragOffset, at: time)
            // The visible offset and its velocity now belong to the held body.
            homeRetraction.value = 0; homeRetraction.speed = 0
            attachmentX.value += idleOffset.value * body.scene.scale
            attachmentX.speed += idleOffset.speed * body.scene.scale
            idleOffset = Spring(frequency: 18, damping: 1)
        case .pointerReleased(let point):
            guard interaction.press != nil else { return }
            let dragged = interaction.dragging; interaction.clearPress()
            if dragged {
                if motionPolicy == .reduced { returnHome() }
                else { body.release() }
                attachmentTarget = Point(x: body.scene.home.midX, y: body.scene.home.maxY)
                if motionPolicy == .reduced {
                    attachmentX.value = attachmentTarget.x; attachmentX.speed = 0
                    attachmentY.value = attachmentTarget.y; attachmentY.speed = 0
                }
                if !body.isPendingRelease { endDesktopDrag() }
            }
            else if point.isFinite && snapshot.contains(point) { activate() }
            if !dragged { endDesktopDrag() }
        case .cancelInteraction:
            reconfigure(scene: body.scene)
        case .outsidePressed:
            if !hasPointerCapture { returnHome() }
        case .activate: activate()
        case .command(let command): perform(command)
        }
        if motionPolicy == .reduced { updateHomePresentation(SimulationTuning.step) }
    }
    private mutating func activate() {
        boredom.interrupt(at: time, cadence: idleCadence)
        switch interaction.presence {
        case .peek: interaction.engage(at: time)
        case .engaged:
            let gesture: CharacterGesture = interaction.gesture == .hello ? .swing : .hello
            interaction.react(gesture, at: time)
            if gesture == .swing && motionPolicy == .full { body.swing.impulse(1.8 * movementAmount) }
            body.compression.impulse(-1.2 * movementAmount)
        case .playing: interaction.clearPress(); returnHome()
        }
    }
    private mutating func returnHome() {
        boredom.interrupt(at: time, cadence: idleCadence)
        interaction.rest()
        if body.phase != .hanging && !body.isReturningHome {
            body.returnHome(immediately: motionPolicy == .reduced)
        }
    }
    private mutating func perform(_ command: CompanionCommand) {
        let moment: IdleMoment? = switch command {
        case .idleWander: .wander; case .idleNap: .nap; case .idleDoodle: .doodle; case .idleFidget: .fidget
        default: nil
        }
        if let moment {
            guard idleMomentsEnabled, motionPolicy == .full, movementAmount > 0,
                  body.phase == .hanging, interaction.presence == .peek, !hasPointerCapture,
                  pointer.distance(to: snapshot.feet) >= 260 * body.scene.scale else { return }
            boredom.begin(moment, at: time); return
        }
        boredom.interrupt(at: time, cadence: idleCadence)
        switch command {
        case .returnHome: interaction.clearPress(); returnHome()
        case .greet:
            interaction.clearPress()
            body.returnHome(immediately: motionPolicy == .reduced); interaction.engage(at: time)
        case .swing, .stretch:
            interaction.clearPress()
            body.returnHome(immediately: motionPolicy == .reduced); interaction.engage(at: time)
            interaction.react(command == .swing ? .swing : .stretch, at: time)
            if command == .swing && body.phase == .hanging && motionPolicy == .full { body.swing.impulse(1.8 * movementAmount) }
        case .walk: if motionPolicy == .full { body.walk() }
        case .hop: if motionPolicy == .full { body.hop() }
        case .idleWander, .idleNap, .idleDoodle, .idleFidget: break
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
        if !hasPointerCapture, dragGeometry != nil, !body.isPendingRelease { endDesktopDrag() }
        if body.phase == .hanging && interaction.presence == .playing { interaction.rest() }
        updateHomePresentation(dt)
        let nearby = pointer.distance(to: snapshot.feet) < 260 * body.scene.scale
        let quiet = body.phase == .hanging && interaction.presence == .peek && !hasPointerCapture && !nearby
        boredom.update(at: time, quiet: quiet, enabled: idleMomentsEnabled && motionPolicy == .full && movementAmount > 0,
                       cadence: idleCadence)
        idleOffset.step(dt, target: (boredom.frame?.offset ?? 0) * movementAmount)
        idle.step(dt, quiet: quiet && boredom.frame == nil, policy: motionPolicy)
        let look = nearby && motionPolicy == .full ? clamp((pointer.x - snapshot.feet.x) / 35, -5, 5) * movementAmount : 0
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
        animator.advance(to: time, dt: dt, walkingAmount: presentation.pose.walk, idlePose: boredom.frame?.applying(to: idle.pose) ?? idle.pose)
        presentation.step(toward: targetPose, dt: dt)
    }
    private mutating func updateHomePresentation(_ dt: Double) {
        let openTarget = body.phase != .hanging || interaction.presence != .peek ? 1.0 : interaction.hoverAge > 0.35 ? 0.66 : 0.6
        let retractionTarget = body.phase == .hanging ? (1 - openTarget) * 75 : 0
        let gripTarget = body.phase == .hanging || body.phase == .catching ? 1.0 : 0
        if motionPolicy == .reduced {
            reveal.value = openTarget; reveal.speed = 0
            homeRetraction.value = retractionTarget; homeRetraction.speed = 0
            homeGrip.value = gripTarget; homeGrip.speed = 0
        } else {
            reveal.step(dt, target: openTarget)
            homeRetraction.step(dt, target: retractionTarget)
            homeGrip.step(dt, target: gripTarget)
        }
        if motionPolicy == .reduced {
            if hasPointerCapture {
                attachmentX.speed = 0; attachmentY.speed = 0
            } else {
                attachmentX.value = attachmentTarget.x; attachmentX.speed = 0
                attachmentY.value = attachmentTarget.y; attachmentY.speed = 0
            }
        } else if !hasPointerCapture {
            attachmentX.step(dt, target: attachmentTarget.x)
            attachmentY.step(dt, target: attachmentTarget.y)
        } else {
            attachmentX.step(dt, target: attachmentTarget.x); attachmentY.step(dt, target: attachmentTarget.y)
        }
    }
    private var targetPose: CharacterPose {
        var pose = animator.targetPose
        pose.height = 1 + (pose.height - 1) * movementAmount
        pose.lean *= movementAmount; pose.look *= movementAmount; pose.lookY *= movementAmount
        pose.arm *= movementAmount
        switch body.phase {
        case .hanging:
            pose.arm = interaction.gesture == .hello ? pose.arm : 0.4 + (boredom.frame?.moment == .doodle ? pose.arm : 0)
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
        let offset = Point(x: idleOffset.value * scene.scale, y: 0)
        var feet = body.renderedFeet + offset - Point(x: 0, y: homeRetraction.value * scene.scale)
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
            pose.arm = 0
            pose.walk = 0; pose.facing = 0; pose.gaitPhase = 0; pose.direction = 1
            pose.lookY = min(28, (1 - open) * 75) + (body.canCatch ? -5 : 0)
            feet = body.phase == .hanging ? Point(x: scene.homeFeet.x, y: scene.homeFeet.y - homeRetraction.value * scene.scale) : feet
        }
        return CompanionSnapshot(scene: scene, presence: interaction.presence, phase: body.phase, pose: pose,
                                 feet: feet, windowAnchor: body.renderedFeet + offset, rotation: motionPolicy == .full ? body.rotation : 0,
                                 openness: open, homeGrip: clamp(homeGrip.value, 0, 1),
                                 homeAttachment: Point(x: attachmentX.value + offset.x, y: attachmentY.value), dragGeometry: dragGeometry,
                                 time: time, gesture: interaction.gesture,
                                 canCatch: body.canCatch, idleMoment: boredom.frame)
    }
}
