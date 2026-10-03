import AppKit
import CompanionCore

/// Composition root. Routes inputs, snapshots and lifecycle; the three owned
/// adapters never call one another and the core never retains an adapter.
@MainActor final class CompanionRuntime {
    private let environment: DesktopEnvironment
    private let clock: ScreenFrameClock
    private let host: CompanionWindowHost
    private let leftButtonIsDown: () -> Bool
    private var context: DisplayContext?
    private var engine: CompanionEngine?
    private var conditions = RuntimeConditions()
    private var running = false
    private var cadence: Float?

    init(environment: DesktopEnvironment = DesktopEnvironment(), clock: ScreenFrameClock = ScreenFrameClock(),
         host: CompanionWindowHost = CompanionWindowHost(),
         leftButtonIsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        self.environment = environment; self.clock = clock; self.host = host
        self.leftButtonIsDown = leftButtonIsDown
    }
    func start() {
        guard !running else { return }; running = true
        host.onInput = { [weak self] input in self?.send(input) }
        clock.onTick = { [weak self] elapsed in self?.tick(elapsed) }
        environment.onDisplayChanged = { [weak self] context in self?.bind(context) }
        environment.onConditionsChanged = { [weak self] conditions in self?.apply(conditions) }
        environment.onRecoveryNeeded = { [weak self] in self?.recover() }
        environment.onOutsidePressed = { [weak self] in self?.send(.outsidePressed) }
        environment.onReturnHome = { [weak self] in self?.send(.command(.returnHome)) }
        environment.start()
    }
    func stop() {
        guard running else { return }; running = false
        clock.stop(); environment.stop(); host.close()
        host.onInput = nil; clock.onTick = nil
        engine = nil; context = nil; cadence = nil; conditions = RuntimeConditions()
    }
    /// Finder reopens recover immediately without requesting application focus.
    func reopen() { environment.recover() }
    /// Future capabilities enter through this action boundary, not adapter access.
    func perform(_ command: CompanionCommand) { send(.command(command)) }
    private func send(_ input: CompanionInput) {
        guard running, context != nil, !conditions.isSuspended else { return }
        engine?.send(input); refresh()
    }
    private func bind(_ context: DisplayContext?) {
        guard running else { return }
        guard let context else {
            engine?.send(.cancelInteraction)
            self.context = nil; cadence = nil
            clock.stop(); host.close()
            return
        }
        if let current = self.context, current.hasSameLayout(as: context) { return }
        self.context = context
        if engine == nil { engine = CompanionEngine(scene: context.scene) }
        else { engine?.reconfigure(scene: context.scene) }
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        guard let engine else { return }
        host.attach(context: context, snapshot: engine.snapshot)
        resumeClock(); refresh(); host.setVisible(!conditions.isSuspended)
    }
    private func apply(_ conditions: RuntimeConditions) {
        let changedSuspension = self.conditions.isSuspended != conditions.isSuspended
        self.conditions = conditions
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        if changedSuspension { recover() }
        else { refresh() }
    }
    private func recover() {
        guard running else { return }
        engine?.send(.cancelInteraction)
        // Recreate a display link even if the screen ID and cadence are unchanged:
        // a link tied to the pre-sleep/pre-Space display may have stopped firing.
        resumeClock(); refresh()
        host.setVisible(context != nil && !conditions.isSuspended)
    }
    private func resumeClock() {
        guard let context, let engine, !conditions.isSuspended else {
            clock.stop(); cadence = nil; return
        }
        let frame = engine.snapshot
        let rate = conditions.frameRate(presence: frame.presence, phase: frame.phase)
        clock.bind(to: context.screen, rate: rate); cadence = rate
    }
    private func tick(_ elapsed: Double) {
        guard running, !conditions.isSuspended, let context else { return }
        // A release can be swallowed by a Space switch, system UI or a host stall.
        // Sample button state only while captured, never other apps' event content.
        if engine?.hasPointerCapture == true && !leftButtonIsDown() { engine?.send(.cancelInteraction) }
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
