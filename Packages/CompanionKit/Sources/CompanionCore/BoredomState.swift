import Foundation

public enum BoatHabit: String, CaseIterable, Sendable { case admire, fiddle, doze }

public enum IdleMoment: Hashable, CaseIterable, Sendable {
    case wander, nap, doodle, fidget
    case boat(BoatHabit)
    public static let ordinary: [Self] = [.wander, .nap, .doodle, .fidget]
    public static let allCases: [Self] = ordinary + BoatHabit.allCases.map { .boat($0) }
    public var boatHabit: BoatHabit? { if case .boat(let habit) = self { habit } else { nil } }
    public var duration: Double {
        switch self { case .wander: 6; case .nap: 8; case .doodle: 7; case .fidget: 5; case .boat: 8 }
    }
    public var command: CompanionCommand {
        switch self {
        case .wander: .idleWander; case .nap: .idleNap; case .doodle: .idleDoodle; case .fidget: .idleFidget
        case .boat(.admire): .idleAdmireBoat; case .boat(.fiddle): .idleFiddleBoat; case .boat(.doze): .idleDozeWithBoat
        }
    }
}

public struct BoredomTiming: Sendable {
    public let threshold: Double
    public let cooldown: Double
    public init(threshold: Double = 300, cooldown: Double = 480) {
        precondition(threshold.isFinite && threshold > 0 && cooldown.isFinite && cooldown > 0)
        self.threshold = threshold; self.cooldown = cooldown
    }
}

/// A repeatable shuffled bag visits every idle family before repeating. No services,
/// wall-clock reads or global randomness are involved.
public struct IdleMomentPicker: Sendable {
    private enum Family: CaseIterable { case wander, nap, doodle, fidget, boat }
    private var state: UInt64
    private var bag: [Family] = []
    private var previous: Family?
    private var habits: [BoatHabit] = []
    private var previousHabit: BoatHabit?
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> IdleMoment {
        if bag.isEmpty {
            bag = shuffled(Family.allCases, avoiding: previous)
        }
        let family = bag.removeLast(); previous = family
        switch family {
        case .wander: return .wander
        case .nap: return .nap
        case .doodle: return .doodle
        case .fidget: return .fidget
        case .boat:
            if habits.isEmpty { habits = shuffled(BoatHabit.allCases, avoiding: previousHabit) }
            let habit = habits.removeLast(); previousHabit = habit
            return .boat(habit)
        }
    }
    private mutating func shuffled<T: Equatable>(_ choices: [T], avoiding previous: T?) -> [T] {
        var result = choices
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            result.swapAt(index, Int((state >> 32) % UInt64(index + 1)))
        }
        if result.last == previous { result.swapAt(0, result.count - 1) }
        return result
    }
}

public struct IdleMomentFrame: Equatable, Sendable {
    public let moment: IdleMoment
    public let progress: Double
    public let movementAmount: Double
    public var weight: Double {
        let age = progress * moment.duration
        let t = clamp(min(age, moment.duration - age), 0, 1)
        return t * t * (3 - 2 * t)
    }
    public init(moment: IdleMoment, progress: Double, movementAmount: Double = 1) {
        self.moment = moment; self.progress = clamp(progress, 0, 1)
        self.movementAmount = clamp(movementAmount, 0, 1.5)
    }
    /// Authored pose targets still pass through the engine's normal pose springs.
    func applying(to base: CharacterPose) -> CharacterPose {
        var pose = base
        let phase = progress * 2 * .pi, w = weight
        switch moment {
        case .wander: pose.look = sin(phase) * 3 * w; pose.lean = sin(phase) * 0.025 * w
        case .nap: pose.eyes *= 1 - w; pose.height -= 0.035 * w; pose.lookY += 1.5 * w
        case .doodle: pose.look = 3 * w; pose.lookY += 2 * w; pose.arm += (0.18 + sin(phase * 3) * 0.08) * w
        case .boat(let habit):
            pose.look = 3 * w; pose.lookY += w
            if habit == .doze { pose.eyes *= 1 - w; pose.height -= 0.02 * w }
            if habit == .fiddle { pose.lean = sin(phase * 3) * 0.012 * w }
        case .fidget: pose.lean = sin(phase * 2) * 0.025 * w; pose.height -= (1 - cos(phase * 2)) * 0.012 * w
        }
        pose.width = 1 / pose.height
        return pose
    }
    public var boatPresentation: BoatPresentation? {
        guard let habit = moment.boatHabit else { return nil }
        let phase = progress * 2 * .pi
        let angle: Double = switch habit {
        case .admire: sin(phase) * 0.12
        case .fiddle: sin(phase * 3) * 0.07
        case .doze: -0.12
        }
        return BoatPresentation(center: Point(x: 34, y: -8 + (1 - weight) * 5 * movementAmount),
                                rotation: angle * weight * movementAmount, opacity: weight)
    }
    var offset: Double { moment == .wander ? sin(progress * 2 * .pi) * 6 * weight : 0 }
}

/// Pure, clock-injected scheduling. A request cannot start itself: Runtime must
/// deliver its typed command, and begin rechecks eligibility before accepting it.
public struct BoredomState: Sendable {
    public private(set) var requestedMoment: IdleMoment?
    public private(set) var frame: IdleMomentFrame?
    private let timing: BoredomTiming
    private var picker: IdleMomentPicker
    private var quietSince: Double?
    private var nextAllowed = 0.0
    private var startedAt: Double?
    private var eligible = false
    private var lastTime = 0.0
    public init(seed: UInt64, timing: BoredomTiming = BoredomTiming()) {
        picker = IdleMomentPicker(seed: seed); self.timing = timing
    }
    public mutating func interrupt(at time: Double, cadence: Double = 1) {
        guard time.isFinite && cadence.isFinite && cadence >= 1 else { return }
        if frame != nil || requestedMoment != nil { nextAllowed = time + timing.cooldown * cadence }
        frame = nil; requestedMoment = nil; startedAt = nil; quietSince = nil; eligible = false
    }
    public mutating func update(at time: Double, quiet: Bool, enabled: Bool, cadence: Double = 1) {
        guard time.isFinite && time >= lastTime && cadence.isFinite && cadence >= 1 else { return }
        lastTime = time
        guard quiet && enabled else { interrupt(at: time, cadence: cadence); return }
        eligible = true
        if let startedAt, let frame {
            let progress = (time - startedAt) / frame.moment.duration
            if progress >= 1 {
                self.frame = nil; self.startedAt = nil
                nextAllowed = time + timing.cooldown * cadence; quietSince = time
            } else { self.frame = IdleMomentFrame(moment: frame.moment, progress: progress) }
            return
        }
        if quietSince == nil { quietSince = time }
        if requestedMoment == nil, time - (quietSince ?? time) >= timing.threshold * cadence, time >= nextAllowed {
            requestedMoment = picker.next()
        }
    }
    @discardableResult public mutating func begin(_ moment: IdleMoment, at time: Double) -> Bool {
        guard eligible, requestedMoment == moment, frame == nil, time.isFinite, time == lastTime else { return false }
        requestedMoment = nil; startedAt = time
        frame = IdleMomentFrame(moment: moment, progress: 0)
        return true
    }
#if DEBUG
    mutating func requestDebugMoment(_ moment: IdleMoment, at time: Double) {
        guard frame == nil, requestedMoment == nil, time.isFinite, time >= lastTime else { return }
        lastTime = time; quietSince = time; eligible = true; requestedMoment = moment
    }
#endif
}

public struct BoatPresentation: Equatable, Sendable {
    public let center: Point
    public let rotation: Double
    public let opacity: Double
}

extension CompanionSnapshot {
    /// A still using the same authored habit and geometry as a live encounter.
    public static func boatIllustration(in scene: SceneGeometry, habit: BoatHabit = .admire) -> Self {
        let base = CompanionEngine(scene: scene).snapshot
        guard scene.form == .standard else { return base }
        let moment = IdleMomentFrame(moment: .boat(habit), progress: 0.4)
        return Self(scene: scene, presence: base.presence, phase: base.phase, pose: moment.applying(to: base.pose),
                    feet: base.feet, windowAnchor: base.windowAnchor, rotation: base.rotation,
                    openness: base.openness, homeGrip: base.homeGrip, time: 0,
                    gesture: nil, canCatch: false, idleMoment: moment)
    }
}
