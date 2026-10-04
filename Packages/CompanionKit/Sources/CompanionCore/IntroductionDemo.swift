import Foundation

public enum IntroductionStep: Int, CaseIterable, Sendable {
    case hover, invite, drag, catchHome, returnHome
}

/// Scripted input for an isolated production engine. The desktop companion is
/// never used as a teaching surface; the host only displays this demo's values.
public struct IntroductionDemo: Sendable {
    public static let duration = 5.0
    public static let scene = SceneGeometry(
        bounds: Rect(x: 0, y: 0, width: 720, height: 360),
        home: Rect(x: 260, y: 0, width: 200, height: 54), floor: 315, scale: 1.05
    )
    public let step: IntroductionStep
    public let motionPolicy: MotionPolicy
    private var engine: CompanionEngine
    private var ticks = 0
    private var remainder = 0.0
    private var start = Point.zero
    public private(set) var pointer = Point(x: 600, y: 200)
    public var snapshot: CompanionSnapshot { engine.snapshot }
    public var pressed: Bool {
        engine.hasPointerCapture || (step == .returnHome && (2.8..<2.95).contains(elapsed))
    }
    public var elapsed: Double { Double(ticks) * SimulationTuning.step }

    public init(step: IntroductionStep = .hover, motionPolicy: MotionPolicy = .full) {
        self.step = step; self.motionPolicy = motionPolicy
        engine = CompanionEngine(scene: Self.scene)
        reset()
        // Reduce Motion uses a representative still, including the ready-to-
        // catch gaze. Navigation remains available without scripted movement.
        if motionPolicy == .reduced {
            let stillTime = step == .returnHome ? 4.4 : 2.8
            for _ in 0..<Int(stillTime / SimulationTuning.step) { advanceStep() }
        }
    }
    private mutating func reset() {
        engine = CompanionEngine(scene: Self.scene)
        engine.setMotionPolicy(motionPolicy)
        if step == .drag || step == .catchHome || step == .returnHome { engine.send(.activate) }
        for _ in 0..<72 { engine.advance(by: SimulationTuning.step) }
        start = engine.snapshot.hitBounds.center
        pointer = Point(x: 600, y: 200); ticks = 0
    }
    public mutating func advance(by elapsed: Double) {
        guard motionPolicy == .full, elapsed.isFinite, elapsed > 0 else { return }
        remainder += min(elapsed, SimulationTuning.maximumCatchUp)
        while remainder + 0.00000001 >= SimulationTuning.step {
            remainder = max(0, remainder - SimulationTuning.step)
            advanceStep()
            if self.elapsed >= Self.duration { reset() }
        }
    }
    private mutating func advanceStep() {
        let previous = elapsed
        ticks += 1
        let time = elapsed
        func crossed(_ moment: Double) -> Bool { previous < moment && time + 0.00000001 >= moment }
        let away = start + Point(x: 160, y: 140)
        switch step {
        case .hover:
            pointer = interpolate(from: Point(x: 600, y: 200), to: start, time: time, begin: 0.3, end: 1.1)
            if time > 3.4 { pointer = interpolate(from: start, to: Point(x: 600, y: 200), time: time, begin: 3.4, end: 4.2) }
        case .invite:
            pointer = interpolate(from: Point(x: 600, y: 200), to: start, time: time, begin: 0.2, end: 0.8)
            if crossed(1) { engine.send(.pointerPressed(pointer)) }
            if crossed(1.15) { engine.send(.pointerReleased(pointer)) }
        case .drag, .catchHome, .returnHome:
            let releaseTime = step == .returnHome ? 2 : 3.2
            pointer = interpolate(from: Point(x: 600, y: 200), to: start, time: time, begin: 0.1, end: 0.6)
            if crossed(0.8) { engine.send(.pointerPressed(start)) }
            if time >= 1 {
                pointer = interpolate(from: start, to: away, time: time, begin: 1, end: 1.8)
                if step == .catchHome && time >= 2 {
                    pointer = interpolate(from: away, to: start + Point(x: 20, y: 10), time: time, begin: 2, end: 2.6)
                }
                if time < releaseTime { engine.send(.pointerDragged(pointer)) }
            }
            if crossed(releaseTime) { engine.send(.pointerReleased(pointer)) }
            if step == .returnHome && time >= 2.35 {
                pointer = interpolate(from: away, to: Point(x: 620, y: 220), time: time, begin: 2.35, end: 2.65)
                if crossed(2.8) { engine.send(.outsidePressed) }
            }
        }
        engine.send(.pointerMoved(pointer))
        engine.advance(by: SimulationTuning.step)
    }
    private func interpolate(from: Point, to: Point, time: Double, begin: Double, end: Double) -> Point {
        let progress = clamp((time - begin) / (end - begin), 0, 1)
        let eased = progress * progress * (3 - 2 * progress)
        return from + (to - from) * eased
    }
}
