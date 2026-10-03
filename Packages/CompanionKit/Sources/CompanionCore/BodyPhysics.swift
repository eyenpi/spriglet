import Foundation

/// Position, contact and weight only. No pointer sampling, gestures or drawing.
struct BodyPhysics: Sendable {
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
    private var heldFeet: Point?
    private var lastDrag: (feet: Point, time: Double)?
    private var pointerVelocity = Point.zero
    private var jumpTarget: Point?
    private var jumpToHome = false
    private var anticipation = 0.0
    private var flightRemaining = 0.0
    init(scene: SceneGeometry) { self.scene = scene; position = scene.homeFeet }
    var renderedFeet: Point {
        guard phase == .hanging else { return position }
        let length = 44 * scene.scale
        return position + Point(x: sin(swing.value) * length, y: (cos(swing.value) - 1) * length)
    }
    var rotation: Double {
        phase == .hanging ? -swing.value : phase == .held ? clamp(-pointerVelocity.x / 3500, -0.12, 0.12) : 0
    }
    var isReturningHome: Bool { (phase == .preparingJump || phase == .jumping) && jumpToHome }
    var anticipationProgress: Double { 1 - anticipation / SimulationTuning.jumpAnticipation }
    var canCatch: Bool {
        guard phase == .held, let feet = heldFeet else { return false }
        let margin = 20 * scene.scale
        return feet.x >= scene.home.minX - margin && feet.x <= scene.home.maxX + margin
            && feet.y >= scene.home.maxY + 12 * scene.scale && feet.y <= scene.home.maxY + 115 * scene.scale
    }
    mutating func grab(visibleFeet: Point, target: Point, at time: Double) {
        if phase != .held {
            position = visibleFeet; lastDrag = nil; pointerVelocity = .zero
            swing.value = 0; swing.speed = 0
        }
        phase = .held; isWalking = false; jumpTarget = nil; velocity = .zero
        let feet = Point(x: clamp(target.x, scene.leftLimit, scene.rightLimit),
                         y: clamp(target.y + SimulationTuning.grabWeightOffset * scene.scale, scene.bounds.minY, scene.floor))
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
            phase = .catching
            catchX.value = position.x - scene.homeFeet.x; catchY.value = position.y - scene.homeFeet.y
            catchX.speed = clamp(pointerVelocity.x * 0.2, -150, 150)
            catchY.speed = clamp(pointerVelocity.y * 0.2, -150, 150)
            velocity = .zero
        } else {
            phase = .falling
            velocity = Point(x: clamp(pointerVelocity.x * 0.25, -200, 200), y: clamp(pointerVelocity.y * 0.25, -350, 350))
        }
        heldFeet = nil; lastDrag = nil
    }
    mutating func returnHome(immediately: Bool = false) {
        guard phase != .hanging else { return }
        heldFeet = nil; lastDrag = nil; isWalking = false
        if immediately { settleAtHome(arrivalSpeed: 0); return }
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
        phase = .preparingJump; anticipation = SimulationTuning.jumpAnticipation; velocity = .zero
    }
    private mutating func settleAtHome(arrivalSpeed: Double) {
        position = scene.homeFeet; phase = .hanging; velocity = .zero
        heldFeet = nil; lastDrag = nil; jumpTarget = nil
        swing.value = 0; swing.speed = 0
        compression.impulse(min(1.8, arrivalSpeed / 140))
    }
    mutating func step(_ dt: Double, at time: Double, walkingAmount: Double) {
        compression.step(dt); swing.step(dt)
        switch phase {
        case .hanging: break
        case .held:
            if let lastDrag, time - lastDrag.time > 0.08 { pointerVelocity = pointerVelocity * exp(-12 * dt) }
            if let heldFeet {
                position = position + (heldFeet - position) * (1 - exp(-SimulationTuning.dragFollowRate * dt))
            }
        case .catching:
            catchX.step(dt); catchY.step(dt)
            position = scene.homeFeet + Point(x: catchX.value, y: catchY.value)
            if hypot(catchX.value, catchY.value) < 0.5 && hypot(catchX.speed, catchY.speed) < 6 { settleAtHome(arrivalSpeed: 25) }
        case .preparingJump:
            anticipation -= dt
            if anticipation <= 0, let target = jumpTarget {
                let dy = target.y - position.y
                flightRemaining = max(0.62, sqrt(2 * abs(dy) / SimulationTuning.gravity) * 1.08)
                velocity = Point(x: (target.x - position.x) / flightRemaining,
                                 y: dy / flightRemaining - SimulationTuning.gravity * flightRemaining / 2)
                phase = .jumping
            }
        case .jumping:
            let step = min(dt, flightRemaining)
            position.x += velocity.x * step
            position.y += velocity.y * step + SimulationTuning.gravity * step * step / 2
            velocity.y += SimulationTuning.gravity * step; flightRemaining -= step
            if flightRemaining <= 0.000001, let target = jumpTarget {
                let speed = abs(velocity.y)
                position = target; velocity = .zero; jumpTarget = nil; landingCount += 1
                if jumpToHome { settleAtHome(arrivalSpeed: speed) }
                else { phase = .grounded; compression.impulse(-min(8, max(3, speed / 140))) }
            }
        case .falling:
            let nextY = position.y + velocity.y * dt + SimulationTuning.gravity * dt * dt / 2
            if position.y <= scene.floor && nextY >= scene.floor {
                let hitTime = (-velocity.y + sqrt(max(0, velocity.y * velocity.y + 2 * SimulationTuning.gravity * (scene.floor - position.y)))) / SimulationTuning.gravity
                position.x += velocity.x * hitTime; position.y = scene.floor
                let speed = velocity.y + SimulationTuning.gravity * hitTime
                compression.impulse(-min(8, max(0.8, speed / 140))); landingCount += 1
                if speed > 140 { velocity.y = -min(95, speed * 0.11); velocity.x *= 0.45 }
                else { velocity = .zero; phase = .grounded }
            } else {
                position.x += velocity.x * dt; position.y = nextY; velocity.y += SimulationTuning.gravity * dt
            }
            position.x = clamp(position.x, scene.leftLimit, scene.rightLimit)
        case .grounded:
            if isWalking {
                let low = scene.leftLimit + 32 * scene.scale, high = scene.rightLimit - 32 * scene.scale
                guard low < high else { isWalking = false; return }
                let speed = 22 * scene.scale / (SimulationTuning.walkingStride * 0.6) * walkingAmount
                position.x += direction * speed * dt
                if position.x >= high { position.x = high; direction = -1 }
                if position.x <= low { position.x = low; direction = 1 }
            }
        }
    }
}
