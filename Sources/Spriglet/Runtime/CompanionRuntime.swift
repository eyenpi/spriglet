import AppKit
import CompanionCore

/// Composition root. Routes inputs, snapshots and lifecycle; the three owned
/// adapters never call one another and the core never retains an adapter.
@MainActor final class CompanionRuntime {
    private let environment = DesktopEnvironment()
    private let clock = ScreenFrameClock()
    private let host = CompanionWindowHost()
    private var context: DisplayContext?
    private var engine: CompanionEngine?
    private var conditions = RuntimeConditions()
    private var running = false
    private var cadence: Float?
    func start() {
        guard !running else { return }; running = true
        host.onInput = { [weak self] input in self?.send(input) }
        clock.onTick = { [weak self] elapsed in self?.tick(elapsed) }
        environment.onDisplayChanged = { [weak self] context in self?.bind(context) }
        environment.onConditionsChanged = { [weak self] conditions in self?.apply(conditions) }
        environment.onOutsidePressed = { [weak self] in self?.send(.outsidePressed) }
        environment.onReturnHome = { [weak self] in self?.send(.command(.returnHome)) }
        environment.start()
    }
    func stop() {
        guard running else { return }; running = false
        clock.stop(); environment.stop(); host.close(); engine = nil; context = nil; cadence = nil
    }
    /// Future capabilities enter through this action boundary, not adapter access.
    func perform(_ command: CompanionCommand) { send(.command(command)) }
    private func send(_ input: CompanionInput) {
        guard running else { return }
        engine?.send(input); refresh()
    }
    private func bind(_ context: DisplayContext) {
        self.context = context
        if engine == nil { engine = CompanionEngine(scene: context.scene) }
        else { engine?.reconfigure(scene: context.scene) }
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        guard let engine else { return }
        host.attach(context: context, snapshot: engine.snapshot)
        host.setVisible(!conditions.isSuspended)
        let frame = engine.snapshot
        let rate = conditions.frameRate(presence: frame.presence, phase: frame.phase)
        clock.bind(to: context.screen, rate: rate); cadence = rate
    }
    private func apply(_ conditions: RuntimeConditions) {
        if conditions.isSuspended { engine?.send(.cancelInteraction) }
        self.conditions = conditions
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        host.setVisible(!conditions.isSuspended)
        refresh()
    }
    private func tick(_ elapsed: Double) {
        guard let context else { return }
        engine?.send(.pointerMoved(context.point(NSEvent.mouseLocation)))
        engine?.advance(by: elapsed); refresh()
    }
    private func refresh() {
        guard let engine, let context else { return }
        let frame = engine.snapshot
        let rate = conditions.frameRate(presence: frame.presence, phase: frame.phase)
        if rate != cadence { clock.setRate(rate); cadence = rate }
        host.update(snapshot: frame, capturesPointer: engine.hasPointerCapture, pointer: context.point(NSEvent.mouseLocation))
    }
}
