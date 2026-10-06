import Foundation

/// Position, contact and weight only. No pointer sampling, gestures or drawing.
struct BodyPhysics: Sendable {
    private enum WallSide: Equatable { case left, right }
    private enum CompressionAxis: Equatable { case horizontal, vertical }

    var scene: SceneGeometry
    private(set) var phase = BodyPhase.hanging
    private(set) var position: Point
    private(set) var velocity = Point.zero
    private(set) var landingCount = 0
    private(set) var isWalking = false
    private(set) var direction = 1.0
    var compression = Spring()
    var swing = Spring(frequency: 4.2, damping: 0.22)
    private var catchX = Spring(frequency: 12, damping: 0.82)
    private var catchY = Spring(frequency: 12, damping: 0.82)
    private var tilt = Spring(frequency: 14, damping: 0.9)
    private var heldFeet: Point?
    private var lastDrag: (feet: Point, time: Double)?
    private var pointerVelocity = Point.zero
    private var jumpTarget: Point?
    private var jumpToHome = false
    private var anticipation = 0.0
    private var flight: JumpTrajectory?
    private var flightAge = 0.0
    private var wallContact: WallSide?
    private var lastCompressionAxis: CompressionAxis?
    private var stagedWallImpulse = 0.0
    private var hadVerticalImpactThisStep = false
    init(scene: SceneGeometry) { self.scene = scene; position = scene.homeFeet }
    var renderedFeet: Point {
        guard phase == .hanging else { return position }
        let length = 44 * scene.scale
        return position + Point(x: sin(swing.value) * length, y: (cos(swing.value) - 1) * length)
    }
    var rotation: Double {
        phase == .hanging ? -swing.value : tilt.value
    }
    var renderedVelocity: Point {
        guard phase == .hanging else { return velocity }
        let length = 44 * scene.scale
        return velocity + Point(x: cos(swing.value) * swing.speed * length,
                                y: -sin(swing.value) * swing.speed * length)
    }
    var isReturningHome: Bool { (phase == .preparingJump || phase == .jumping) && jumpToHome }
    var anticipationProgress: Double { 1 - anticipation / SimulationTuning.jumpAnticipation }
    var canCatch: Bool {
        guard phase == .held, let feet = heldFeet else { return false }
        let margin = 20 * scene.scale
        return feet.x >= scene.home.minX - margin && feet.x <= scene.home.maxX + margin
            && feet.y >= scene.home.maxY + 12 * scene.scale && feet.y <= scene.home.maxY + 115 * scene.scale
    }
    mutating func grab(visibleFeet: Point, visibleVelocity: Point? = nil, target: Point, at time: Double) {
        if phase != .held {
            let momentum = visibleVelocity ?? renderedVelocity
            if phase == .hanging { tilt.value = rotation; tilt.speed = -swing.speed }
            position = visibleFeet; lastDrag = nil; pointerVelocity = .zero
            velocity = momentum
        }
        phase = .held; isWalking = false; jumpTarget = nil; flight = nil
        let feet = Point(x: clamp(target.x, scene.leftLimit, scene.rightLimit),
                         y: clamp(target.y + SimulationTuning.grabWeightOffset * scene.scale, scene.ceiling, scene.floor))
        if let previous = lastDrag, time > previous.time {
            let elapsed = max(time - previous.time, SimulationTuning.step)
            let estimate = (feet - previous.feet) * (1 / elapsed)
            let blend = 1 - exp(-12 * elapsed)
            pointerVelocity = pointerVelocity + (estimate - pointerVelocity) * blend
        }
        lastDrag = (feet, time); heldFeet = feet
    }
    mutating func release() {
        guard phase == .held else { return }
        if canCatch {
            beginCatch()
        } else {
            phase = .falling
        }
        heldFeet = nil; lastDrag = nil
    }
    mutating func returnHome(immediately: Bool = false) {
        guard phase != .hanging else { return }
        heldFeet = nil; lastDrag = nil; isWalking = false
        if immediately {
            tilt.value = 0; tilt.speed = 0
            position = scene.homeFeet; velocity = .zero
            settleAtHome(); return
        }
        guard !isReturningHome && phase != .catching else { return }
        beginJump(to: scene.homeFeet, home: true)
    }
    mutating func hop() {
        guard phase == .grounded else { return }
        beginJump(to: position, home: false)
    }
    mutating func walk() {
        guard phase == .grounded else { return }; isWalking = true
    }
    private mutating func beginJump(to target: Point, home: Bool) {
        jumpTarget = target; jumpToHome = home
        if phase == .grounded {
            phase = .preparingJump; anticipation = SimulationTuning.jumpAnticipation
        } else {
            // Airborne interruptions do not stop for a ground anticipation pose.
            startFlight(launchVelocity: velocity)
        }
    }
    private mutating func startFlight(launchVelocity: Point? = nil) {
        guard let target = jumpTarget else { return }
        let dy = target.y - position.y
        let duration = max(0.62, sqrt(2 * abs(dy) / SimulationTuning.gravity) * 1.08)
        let launch = launchVelocity ?? Point(x: (target.x - position.x) / duration,
                                            y: dy / duration - SimulationTuning.gravity * duration / 2)
        let arrival = jumpToHome ? Point(x: 0, y: 70 * scene.scale)
            : Point(x: launch.x, y: launch.y + SimulationTuning.gravity * duration)
        flight = JumpTrajectory(start: position, end: target, launchVelocity: launch,
                                arrivalVelocity: arrival, duration: duration)
        flightAge = 0; velocity = launch; phase = .jumping
    }
    private mutating func beginCatch() {
        phase = .catching
        catchX.value = position.x - scene.homeFeet.x; catchY.value = position.y - scene.homeFeet.y
        catchX.speed = velocity.x; catchY.speed = velocity.y
        jumpTarget = nil; flight = nil
    }
    private mutating func settleAtHome() {
        let incomingPosition = position, incomingVelocity = velocity
        phase = .hanging
        heldFeet = nil; lastDrag = nil; jumpTarget = nil; flight = nil
        swing.value = -tilt.value; swing.speed = -tilt.speed
        let length = 44 * scene.scale
        let swingOffset = Point(x: sin(swing.value) * length, y: (cos(swing.value) - 1) * length)
        let swingVelocity = Point(x: cos(swing.value) * swing.speed * length, y: -sin(swing.value) * swing.speed * length)
        // Transfer residual motion into the hanging frame without adding the
        // pendulum offset or velocity a second time at the phase boundary.
        let residual = incomingPosition - scene.homeFeet - swingOffset
        let momentum = incomingVelocity - swingVelocity
        catchX.value = residual.x; catchY.value = residual.y
        catchX.speed = momentum.x; catchY.speed = momentum.y
        position = incomingPosition - swingOffset; velocity = momentum
    }
    private mutating func registerVerticalImpact(_ amount: Double) {
        if lastCompressionAxis == .horizontal { compression.speed = min(0, compression.speed) }
        compression.impulse(amount)
        lastCompressionAxis = .vertical
        hadVerticalImpactThisStep = true
    }
    private mutating func stageWallImpact(side: WallSide, incomingSpeed: Double) {
        guard wallContact != side, incomingSpeed.isFinite, incomingSpeed > scene.scale else { return }
        let strength = min(8, max(0.8, abs(incomingSpeed) / scene.scale / 140))
        stagedWallImpulse = max(stagedWallImpulse, strength)
        wallContact = side
    }
    private mutating func applyStagedWallImpact() {
        guard !hadVerticalImpactThisStep, stagedWallImpulse > 0 else { return }
        if lastCompressionAxis == .vertical { compression.speed = max(0, compression.speed) }
        compression.impulse(stagedWallImpulse)
        lastCompressionAxis = .horizontal
    }
    /// Preserve free momentum until an actual scene contact. Walls stop only
    /// outward horizontal motion; vertical contacts give a soft, bounded rebound.
    @discardableResult private mutating func resolveSceneContacts() -> Bool {
        let bounded = Point(x: clamp(position.x, scene.leftLimit, scene.rightLimit),
                            y: clamp(position.y, scene.ceiling, scene.floor))
        guard bounded != position else { return false }
        if (position.x < scene.leftLimit && velocity.x < 0) || (position.x > scene.rightLimit && velocity.x > 0) {
            let side: WallSide = position.x < scene.leftLimit ? .left : .right
            stageWallImpact(side: side, incomingSpeed: abs(velocity.x))
            velocity.x = 0
        }
        if bounded.y != position.y {
            let direction = position.y < scene.ceiling ? 1.0 : -1.0
            let impactSpeed = -velocity.y * direction
            if impactSpeed > 0 {
                registerVerticalImpact(-min(8, max(0.8, impactSpeed / 140)))
                velocity.y = direction * min(95, impactSpeed * 0.11)
            }
        }
        position = bounded
        return true
    }
    mutating func step(_ dt: Double, at time: Double, walkingAmount: Double) {
        stagedWallImpulse = 0; hadVerticalImpactThisStep = false
        compression.step(dt)
        if let wallContact {
            let movedInward = switch wallContact {
            case .left: position.x >= scene.leftLimit + scene.scale
            case .right: position.x <= scene.rightLimit - scene.scale
            }
            if movedInward { self.wallContact = nil }
        }
        if phase == .hanging { swing.step(dt) }
        else { tilt.step(dt, target: phase == .held ? clamp(-pointerVelocity.x / 3500, -0.12, 0.12) : 0) }
        switch phase {
        case .hanging:
            catchX.step(dt); catchY.step(dt)
            position = scene.homeFeet + Point(x: catchX.value, y: catchY.value)
            velocity = Point(x: catchX.speed, y: catchY.speed)
        case .held:
            if let lastDrag, time - lastDrag.time > 0.08 { pointerVelocity = pointerVelocity * exp(-12 * dt) }
            if let heldFeet {
                let frequency = SimulationTuning.dragFrequency
                let acceleration = (heldFeet - position) * (frequency * frequency)
                    - velocity * (2 * SimulationTuning.dragDamping * frequency)
                velocity = velocity + acceleration * dt
                position = position + velocity * dt
                if position.x < scene.leftLimit && velocity.x < 0 {
                    stageWallImpact(side: .left, incomingSpeed: abs(velocity.x))
                } else if position.x > scene.rightLimit && velocity.x > 0 {
                    stageWallImpact(side: .right, incomingSpeed: abs(velocity.x))
                }
                let bounded = Point(x: clamp(position.x, scene.leftLimit, scene.rightLimit),
                                    y: clamp(position.y, scene.ceiling, scene.floor))
                if bounded.x != position.x { velocity.x = 0 }
                if bounded.y != position.y { velocity.y = 0 }
                position = bounded
            }
        case .catching:
            catchX.step(dt); catchY.step(dt)
            position = scene.homeFeet + Point(x: catchX.value, y: catchY.value)
            velocity = Point(x: catchX.speed, y: catchY.speed)
            if resolveSceneContacts() {
                catchX.value = position.x - scene.homeFeet.x; catchY.value = position.y - scene.homeFeet.y
                catchX.speed = velocity.x; catchY.speed = velocity.y
            }
            if hypot(catchX.value, catchY.value) < 0.5 && hypot(catchX.speed, catchY.speed) < 6 { settleAtHome() }
        case .preparingJump:
            anticipation -= dt
            if anticipation <= 0 { startFlight() }
        case .jumping:
            guard let flight else { break }
            flightAge = min(flightAge + dt, flight.duration)
            let sample = flight.sample(at: flightAge)
            position = sample.position; velocity = sample.velocity
            if jumpToHome && position.y > scene.floor && velocity.y > 0 {
                position.y = scene.floor
                registerVerticalImpact(-min(8, max(0.8, velocity.y / 140)))
                velocity = .zero; phase = .grounded; landingCount += 1
                resolveSceneContacts()
                beginJump(to: scene.homeFeet, home: true)
            } else if resolveSceneContacts() {
                // The old Hermite path would leave the scene again. Join a new
                // finite flight from the contact position and remaining momentum.
                startFlight(launchVelocity: velocity)
            } else if flightAge >= flight.duration {
                if jumpToHome { beginCatch() }
                else {
                    registerVerticalImpact(-min(8, max(3, abs(velocity.y) / 140)))
                    phase = .grounded; velocity = .zero; jumpTarget = nil; self.flight = nil; landingCount += 1
                }
            }
        case .falling:
            let nextY = position.y + velocity.y * dt + SimulationTuning.gravity * dt * dt / 2
            if position.y <= scene.floor && nextY >= scene.floor {
                let hitTime = (-velocity.y + sqrt(max(0, velocity.y * velocity.y + 2 * SimulationTuning.gravity * (scene.floor - position.y)))) / SimulationTuning.gravity
                position.x += velocity.x * hitTime; position.y = scene.floor
                let speed = velocity.y + SimulationTuning.gravity * hitTime
                registerVerticalImpact(-min(8, max(0.8, speed / 140))); landingCount += 1
                if speed > 140 { velocity.y = -min(95, speed * 0.11); velocity.x *= 0.45 }
                else { velocity = .zero; phase = .grounded }
            } else {
                position.x += velocity.x * dt; position.y = nextY; velocity.y += SimulationTuning.gravity * dt
            }
            resolveSceneContacts()
        case .grounded:
            if isWalking {
                let low = scene.leftLimit + 32 * scene.scale, high = scene.rightLimit - 32 * scene.scale
                guard low < high else { isWalking = false; return }
                let speed = 22 * scene.scale / (SimulationTuning.walkingStride * 0.6) * walkingAmount
                velocity = Point(x: direction * speed, y: 0)
                position.x += direction * speed * dt
                if position.x >= high { position.x = high; direction = -1 }
                if position.x <= low { position.x = low; direction = 1 }
            } else { velocity = .zero }
        }
        applyStagedWallImpact()
    }
}
