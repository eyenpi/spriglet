import AppKit
import CompanionCore

/// Composition root. Routes inputs, snapshots and lifecycle; the three owned
/// adapters never call one another and the core never retains an adapter.
@MainActor final class CompanionRuntime {
    private let environment: DesktopEnvironment
    private let clock: ScreenFrameClock
    private let host: CompanionWindowHost
    private let leftButtonIsDown: () -> Bool
    private let preferenceStore: PreferenceStore
    private var displays: [HomeDisplay] = []
    private(set) var preferences: CompanionPreferences
    var onSettingsChanged: ((SettingsState) -> Void)?
    var onShowSettings: (() -> Void)?
    var settingsState: SettingsState { SettingsState(preferences: preferences, displays: displays, controls: controlState) }
    private var context: DisplayContext?
    private var engine: CompanionEngine?
    private var conditions = RuntimeConditions()
    private var running = false
    private var cadence: Float?
    private var hidden = false
    private var paused = false
    private var publishedControlState: CompanionControlState?
    var onControlStateChanged: ((CompanionControlState) -> Void)?
    var controlState: CompanionControlState {
        let canShow = running && context != nil && !conditions.isSuspended
        return CompanionControlState(isVisible: canShow && !hidden, isPaused: paused, canShow: canShow)
    }
    private var isAnimating: Bool { controlState.isVisible && !paused }

    init(environment: DesktopEnvironment = DesktopEnvironment(), clock: ScreenFrameClock = ScreenFrameClock(),
         host: CompanionWindowHost = CompanionWindowHost(),
         preferenceStore: PreferenceStore = PreferenceStore(),
         leftButtonIsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        self.environment = environment; self.clock = clock; self.host = host
        self.leftButtonIsDown = leftButtonIsDown
        self.preferenceStore = preferenceStore; preferences = preferenceStore.load()
    }
    func start() {
        guard !running else { return }; running = true
        host.onInput = { [weak self] input in self?.send(input) }
        host.onShowSettings = { [weak self] in self?.onShowSettings?() }
        clock.onTick = { [weak self] elapsed in self?.tick(elapsed) }
        environment.onDisplayChanged = { [weak self] context in self?.bind(context) }
        environment.onDisplaysChanged = { [weak self] displays in
            guard let self else { return }
            self.displays = displays; self.onSettingsChanged?(self.settingsState)
        }
        environment.onConditionsChanged = { [weak self] conditions in self?.apply(conditions) }
        environment.onRecoveryNeeded = { [weak self] in self?.recover() }
        environment.onOutsidePressed = { [weak self] in self?.send(.outsidePressed) }
        environment.onReturnHome = { [weak self] in self?.send(.command(.returnHome)) }
        environment.configureHome(preferences); environment.start()
    }
    func stop() {
        guard running else { return }; running = false
        clock.stop(); environment.stop(); host.close()
        host.onInput = nil; host.onShowSettings = nil; clock.onTick = nil
        environment.onDisplayChanged = nil; environment.onDisplaysChanged = nil
        environment.onConditionsChanged = nil; environment.onRecoveryNeeded = nil
        environment.onOutsidePressed = nil; environment.onReturnHome = nil
        displays = []
        engine = nil; context = nil; cadence = nil; conditions = RuntimeConditions()
        hidden = false; paused = false; publishControlState()
    }
    /// Finder reopens recover immediately without requesting application focus.
    func reopen() { bringHome() }
    func setVisible(_ visible: Bool) {
        guard running else { return }
        hidden = !visible
        if visible { environment.recover() }
        else {
            engine?.send(.cancelInteraction)
            refresh()
        }
    }
    func setPaused(_ paused: Bool) {
        guard running, self.paused != paused else { return }
        self.paused = paused
        // A paused drag cannot keep mouse capture or wait for a future release.
        if engine?.hasPointerCapture == true { engine?.send(.cancelInteraction) }
        refresh()
    }
    /// Explicit recovery shows Mallow even after Hide, and preserves Pause.
    func bringHome() {
        guard running else { return }
        hidden = false
        environment.recover()
    }
    /// Future capabilities enter through this action boundary, not adapter access.
    func perform(_ command: CompanionCommand) { send(.command(command)) }
    func updatePreferences(_ preferences: CompanionPreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences; preferenceStore.save(preferences)
        engine?.setMovementAmount(preferences.movementIntensity.amount)
        environment.configureHome(preferences)
        refresh(); onSettingsChanged?(settingsState)
    }
    private func send(_ input: CompanionInput) {
        guard isAnimating else { return }
        engine?.send(input); refresh()
    }
    private func bind(_ context: DisplayContext?) {
        guard running else { return }
        guard let context else {
            engine?.send(.cancelInteraction)
            self.context = nil; cadence = nil
            clock.stop(); host.close()
            publishControlState()
            return
        }
        if let current = self.context, current.hasSameLayout(as: context) { return }
        self.context = context
        if engine == nil { engine = CompanionEngine(scene: context.scene, idleSeed: UInt64.random(in: .min ... .max)) }
        else { engine?.reconfigure(scene: context.scene) }
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        engine?.setMovementAmount(preferences.movementIntensity.amount)
        guard let engine else { return }
        host.attach(context: context, snapshot: engine.snapshot)
        resumeClock(); refresh()
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
        // Reassert ordering after lifecycle transitions even when AppKit still
        // reports the panel as visible. Normal frames do not reorder windows.
        host.setVisible(controlState.isVisible, restoringOrder: true)
    }
    private func resumeClock() {
        guard isAnimating, let context, let engine else {
            clock.stop(); cadence = nil; return
        }
        let frame = engine.snapshot
        let rate = conditions.frameRate(presence: frame.presence, phase: frame.phase)
        clock.bind(to: context.screen, rate: rate); cadence = rate
    }
    private func tick(_ elapsed: Double) {
        guard isAnimating, let context else { return }
        // A release can be swallowed by a Space switch, system UI or a host stall.
        // Sample button state only while captured, never other apps' event content.
        if engine?.hasPointerCapture == true && !leftButtonIsDown() { engine?.send(.cancelInteraction) }
        engine?.send(.pointerMoved(context.point(NSEvent.mouseLocation)))
        engine?.advance(by: elapsed); refresh()
    }
    private func refresh() {
        defer { publishControlState() }
        guard let engine, let context else { return }
        let frame = engine.snapshot
        if isAnimating {
            let rate = conditions.frameRate(presence: frame.presence, phase: frame.phase)
            if cadence == nil { resumeClock() }
            else if rate != cadence { clock.setRate(rate); cadence = rate }
        } else { clock.stop(); cadence = nil }
        host.update(snapshot: frame, capturesPointer: engine.hasPointerCapture,
                    pointer: context.point(NSEvent.mouseLocation), acceptsInput: isAnimating)
        host.setVisible(controlState.isVisible)
    }
    private func publishControlState() {
        let state = controlState
        guard publishedControlState != state else { return }
        publishedControlState = state
        onControlStateChanged?(state)
    }
}
