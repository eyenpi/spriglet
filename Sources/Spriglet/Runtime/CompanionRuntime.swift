import AppKit
import CompanionCore

/// Composition root. A captured drag is a transaction until a valid drop commits it.
@MainActor final class CompanionRuntime {
    private struct DragTransaction {
        let origin: DisplayContext
        var active: DisplayContext
        var committing = false
    }
    private let environment: DesktopEnvironment
    private let clock: ScreenFrameClock
    private let host: CompanionWindowHost
    private let introductionHost: IntroductionWindowHost
    private let introductionPreferences: IntroductionPreferences
    private let leftButtonIsDown: () -> Bool
    private let pointerLocation: () -> Point
    private let preferenceStore: PreferenceStore
    private var displays: [HomeDisplay] = []
    private var availableContexts: [DisplayContext] = []
    private var layoutHome: DisplayContext?
    private var dragTransaction: DragTransaction?
    private(set) var preferences: CompanionPreferences
    var onSettingsChanged: ((SettingsState) -> Void)?
    var onControlAction: ((AppControlAction) -> Void)?
    var settingsState: SettingsState { SettingsState(preferences: preferences, displays: displays, controls: controlState) }
    private var context: DisplayContext?
    private var engine: CompanionEngine?
    private let boredomTiming: BoredomTiming
    private let idleSeed: UInt64
#if DEBUG
    private var debugIdleMoment: IdleMoment? = DebugIdleMomentArgument.parse(arguments: ProcessInfo.processInfo.arguments)
#endif
    /// Only Debug builds honor the accelerated demo. Release never reads it.
    private static var defaultBoredomTiming: BoredomTiming {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPRIGLET_BORED_DEMO"] == "1" {
            return BoredomTiming(threshold: 3, cooldown: 4)
        }
        #endif
        return BoredomTiming()
    }
    private var conditions = RuntimeConditions()
    private var running = false
    private var cadence: Float?
    private var introduction: IntroductionDemo?
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
         introductionHost: IntroductionWindowHost = IntroductionWindowHost(),
         introductionPreferences: IntroductionPreferences = IntroductionPreferences(),
         preferenceStore: PreferenceStore = PreferenceStore(),
         boredomTiming: BoredomTiming? = nil, idleSeed: UInt64? = nil,
         leftButtonIsDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
         pointerLocation: @escaping () -> Point = {
             let p = NSEvent.mouseLocation; return Point(x: p.x, y: p.y)
         }) {
        self.boredomTiming = boredomTiming ?? Self.defaultBoredomTiming
        self.idleSeed = idleSeed ?? UInt64.random(in: .min ... .max)
        self.environment = environment; self.clock = clock; self.host = host
        self.introductionHost = introductionHost; self.introductionPreferences = introductionPreferences
        self.leftButtonIsDown = leftButtonIsDown; self.pointerLocation = pointerLocation
        self.preferenceStore = preferenceStore; preferences = preferenceStore.load()
    }
    func start() {
        guard !running else { return }; running = true
        host.onInput = { [weak self] input in self?.send(input) }
        host.onPointerInput = { [weak self] input in self?.pointer(input) }
        host.onControlAction = { [weak self] in self?.onControlAction?($0) }
        introductionHost.onStepSelected = { [weak self] step in self?.selectIntroductionStep(step) }
        introductionHost.onDismiss = { [weak self] in self?.dismissIntroduction() }
        clock.onTick = { [weak self] elapsed in self?.tick(elapsed) }
        environment.onLayoutChanged = { [weak self] layout in self?.apply(layout) }
        environment.onDisplaysChanged = { [weak self] displays in
            guard let self else { return }
            self.displays = displays; self.onSettingsChanged?(self.settingsState)
        }
        environment.onConditionsChanged = { [weak self] conditions in self?.apply(conditions) }
        environment.onRecoveryNeeded = { [weak self] in self?.recover() }
        environment.onOutsidePressed = { [weak self] in self?.send(.outsidePressed) }
        environment.onEscapePressed = { [weak self] in
            guard let self else { return }
            if self.introduction != nil { self.dismissIntroduction() }
            else { self.send(.command(.returnHome)) }
        }
        environment.configureHome(preferences); environment.start()
    }
    func stop() {
        guard running else { return }; running = false
        dragTransaction = nil; availableContexts = []; layoutHome = nil
        clock.stop(); environment.stop(); host.close(); introductionHost.close()
        host.onInput = nil; host.onPointerInput = nil; host.onControlAction = nil; clock.onTick = nil
        introductionHost.onStepSelected = nil; introductionHost.onDismiss = nil; introduction = nil
        environment.onLayoutChanged = nil; environment.onDisplaysChanged = nil
        environment.onConditionsChanged = nil; environment.onRecoveryNeeded = nil
        environment.onOutsidePressed = nil; environment.onEscapePressed = nil
        displays = []; engine = nil; context = nil; cadence = nil; conditions = RuntimeConditions()
        hidden = false; paused = false; publishControlState()
    }
    func reopen() { bringHome() }
    func setVisible(_ visible: Bool) {
        guard running else { return }
        if !visible { cancelDesktopDrag() }
        hidden = !visible
        if visible { environment.recover() }
        else { engine?.send(.cancelInteraction); refresh() }
    }
    func setPaused(_ paused: Bool) {
        guard running, self.paused != paused else { return }
        if paused { cancelDesktopDrag() }
        self.paused = paused
        if engine?.hasPointerCapture == true || engine?.hasPendingDragRelease == true {
            engine?.send(.cancelInteraction)
        }
        refresh()
    }
    func bringHome() { guard running else { return }; hidden = false; environment.recover() }
    func perform(_ command: CompanionCommand) { send(.command(command)) }
#if DEBUG
    private func performDebugIdleMoment(_ moment: IdleMoment) {
        guard isAnimating else { return }
        // Move the simulated pointer out of Mallow's attention radius, then
        // create the requested eligible Core command and deliver it normally.
        engine?.send(.pointerMoved(Point(x: -1_000_000, y: -1_000_000)))
        engine?.requestDebugIdleMoment(moment)
        perform(moment.command)
    }
#endif
    func showIntroductionIfNeeded() { if introductionPreferences.shouldPresentOnLaunch { showIntroduction() } }
    func showIntroduction() { guard running else { return }; selectIntroductionStep(.hover); presentIntroduction() }
    private func selectIntroductionStep(_ step: IntroductionStep) {
        introduction = IntroductionDemo(step: step, motionPolicy: conditions.reduceMotion ? .reduced : .full); refresh()
    }
    private func dismissIntroduction() { introductionPreferences.recordDismissal(); introduction = nil; introductionHost.close(); refresh() }
    private func presentIntroduction() {
        guard let context, let introduction, !conditions.isSuspended else { return }
        introductionHost.present(on: context.screen, demo: introduction)
    }
    func updatePreferences(_ preferences: CompanionPreferences) {
        guard self.preferences != preferences else { return }
        let geometryChanged = self.preferences.characterSize != preferences.characterSize
            || self.preferences.homeLocation != preferences.homeLocation
            || self.preferences.homeDisplayID != preferences.homeDisplayID
        if geometryChanged { cancelDesktopDrag() }
        self.preferences = preferences; preferenceStore.save(preferences)
        engine?.setMovementAmount(preferences.movementIntensity.amount)
        environment.configureHome(preferences)
        refresh(); onSettingsChanged?(settingsState)
    }
    private func apply(_ layout: DisplayLayout) {
        availableContexts = layout.available; layoutHome = layout.home
        if var transaction = dragTransaction, !transaction.committing {
            let origin = availableContexts.first { $0.logicalID == transaction.origin.logicalID }
            let active = availableContexts.first { $0.logicalID == transaction.active.logicalID }
            guard let origin, let active,
                  samePhysicalLayout(transaction.origin, origin), samePhysicalLayout(transaction.active, active) else {
                cancelDesktopDrag(); bind(layout.home); return
            }
            transaction.active = active; dragTransaction = transaction
            context = active; host.retarget(context: active)
            if let geometry = makeDragGeometry(active: active) {
                _ = self.engine?.updateDesktopDragGeometry(geometry)
            }
            refresh(); return
        }
        bind(layout.home)
    }
    private func bind(_ next: DisplayContext?) {
        guard running else { return }
        guard let next else {
            if dragTransaction != nil { engine?.send(.cancelInteraction); dragTransaction = nil }
            context = nil; cadence = nil; clock.stop(); host.close(); introductionHost.setVisible(false)
            publishControlState(); return
        }
        if let current = context, samePhysicalLayout(current, next) {
            context = next; host.retarget(context: next); return
        }
        context = next
        if engine == nil { engine = CompanionEngine(scene: next.scene, idleSeed: idleSeed, boredomTiming: boredomTiming) }
        else { engine?.reconfigure(scene: next.scene) }
        engine?.setIdleMomentsEnabled(conditions.allowsIdleMoments)
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        engine?.setMovementAmount(preferences.movementIntensity.amount)
        guard let engine else { return }
        host.attach(context: next, snapshot: engine.snapshot)
        resumeClock(); refresh(); introductionHost.setVisible(false); presentIntroduction()
#if DEBUG
        if let moment = debugIdleMoment {
            debugIdleMoment = nil
            performDebugIdleMoment(moment)
        }
#endif
    }
    private func samePhysicalLayout(_ a: DisplayContext, _ b: DisplayContext) -> Bool {
        a.logicalID == b.logicalID && a.hasSameMeasurements(as: b)
    }
    private func apply(_ conditions: RuntimeConditions) {
        let changedSuspension = self.conditions.isSuspended != conditions.isSuspended
        let changedMotion = self.conditions.reduceMotion != conditions.reduceMotion
        self.conditions = conditions
        engine?.setIdleMomentsEnabled(conditions.allowsIdleMoments)
        engine?.setMotionPolicy(conditions.reduceMotion ? .reduced : .full)
        if changedMotion, let introduction { selectIntroductionStep(introduction.step) }
        if changedSuspension { recover() } else { refresh() }
    }
    private func recover() {
        guard running else { return }
        cancelDesktopDrag()
        engine?.send(.cancelInteraction)
        resumeClock(); refresh()
        host.setVisible(controlState.isVisible, restoringOrder: true)
        introductionHost.setVisible(false); presentIntroduction()
    }
    private func resumeClock() {
        guard isAnimating, let context, let engine else { clock.stop(); cadence = nil; return }
        let rate = frameRate(for: engine.snapshot)
        clock.bind(to: context.screen, rate: rate); cadence = rate
    }
    private func tick(_ elapsed: Double) {
        guard isAnimating, let context else { return }
        if engine?.hasPointerCapture == true && !leftButtonIsDown() { cancelDesktopDrag() }
        let p = pointerLocation()
        engine?.send(.pointerMoved(context.scenePoint(global: p)))
        engine?.advance(by: elapsed)
        if let moment = engine?.requestedIdleMoment { perform(moment.command) }
        introduction?.advance(by: elapsed); refresh()
    }
    private func frameRate(for snapshot: CompanionSnapshot) -> Float {
        let companionRate = conditions.frameRate(presence: snapshot.presence, phase: snapshot.phase)
        return introduction?.motionPolicy == .full ? max(companionRate, min(30, conditions.maximumFrameRate)) : companionRate
    }
    private func refresh() {
        defer { publishControlState() }
        guard let engine, let context else { return }
        let frame = engine.snapshot
        if isAnimating {
            let rate = frameRate(for: frame)
            if cadence == nil { resumeClock() }
            else if rate != cadence { clock.setRate(rate); cadence = rate }
        } else { clock.stop(); cadence = nil }
        host.update(snapshot: frame, capturesPointer: engine.hasPointerCapture,
                    pointer: context.scenePoint(global: pointerLocation()), acceptsInput: isAnimating, isPaused: paused)
        host.setVisible(controlState.isVisible)
        if let introduction { introductionHost.update(introduction) }
    }
    private func publishControlState() {
        let state = controlState
        guard publishedControlState != state else { return }
        publishedControlState = state; onControlStateChanged?(state)
    }
    private func send(_ input: CompanionInput) {
        guard isAnimating else { return }
        if dragTransaction != nil {
            switch input {
            case .cancelInteraction, .outsidePressed, .activate, .command:
                cancelDesktopDrag()
            default: break
            }
        }
        guard let context, engine != nil else { return }
        switch input {
        case .pointerPressed(let p): pointer(.pressed(context.globalPoint(scene: p)))
        case .pointerDragged(let p): pointer(.dragged(context.globalPoint(scene: p)))
        case .pointerReleased(let p): pointer(.released(context.globalPoint(scene: p)))
        default: engine?.send(input); refresh()
        }
    }
    private func pointer(_ input: DesktopPointerInput) {
        guard isAnimating, engine != nil, let context else { return }
        let global = input.globalPoint
        guard global.isFinite else { if dragTransaction != nil { cancelDesktopDrag() }; return }
        switch input {
        case .pressed:
            guard dragTransaction == nil else { cancelDesktopDrag(); return }
            engine?.send(.pointerPressed(context.scenePoint(global: global)))
            guard engine?.hasPointerCapture == true, let geometry = makeDragGeometry(active: context),
                  engine?.beginDesktopDrag(geometry: geometry) == true else { refresh(); return }
            dragTransaction = DragTransaction(origin: context, active: context)
            refresh()
        case .dragged:
            guard var transaction = dragTransaction, engine?.hasPointerCapture == true else { return }
            engine?.send(.pointerDragged(transaction.active.scenePoint(global: global)))
            guard engine?.isDragging == true else { refresh(); return }
            if let destination = display(at: global, current: transaction.active),
               !destination.isSameLogicalDisplay(as: transaction.active) {
                guard transfer(to: destination, transaction: &transaction) else { cancelDesktopDrag(); return }
            }
            transaction = dragTransaction ?? transaction
            engine?.send(.pointerDragged(transaction.active.scenePoint(global: global)))
            refresh()
        case .released:
            guard var transaction = dragTransaction, engine?.hasPointerCapture == true else { return }
            let destination = display(at: global, current: transaction.active)
            guard destination != nil else { cancelDesktopDrag(); return }
            engine?.send(.pointerDragged(transaction.active.scenePoint(global: global)))
            if engine?.isDragging == true, let destination, !destination.isSameLogicalDisplay(as: transaction.active) {
                guard transfer(to: destination, transaction: &transaction) else { cancelDesktopDrag(); return }
            }
            guard let finalTransaction = dragTransaction else { return }
            let finalPoint = finalTransaction.active.scenePoint(global: global)
            engine?.send(.pointerDragged(finalPoint))
            let shouldPersist = engine?.isDragging == true
                && !finalTransaction.origin.isSameLogicalDisplay(as: finalTransaction.active)
                && UUID(uuidString: finalTransaction.active.persistentID) != nil
            if engine?.isDragging == true,
               !finalTransaction.origin.isSameLogicalDisplay(as: finalTransaction.active), !shouldPersist {
                cancelDesktopDrag(); return
            }
            if shouldPersist {
                if var updated = dragTransaction { updated.committing = true; dragTransaction = updated }
                var next = preferences; next.homeDisplayID = finalTransaction.active.persistentID
                commitDropPreferences(next)
            }
            engine?.send(.pointerReleased(finalPoint))
            dragTransaction = nil; refresh()
        }
    }
    private func transfer(to destination: DisplayContext, transaction: inout DragTransaction) -> Bool {
        let source = transaction.active
        let translation = DesktopDragCoordinates.translation(from: source.frame, to: destination.frame)
        guard let geometry = makeDragGeometry(active: destination),
              engine?.transferDrag(scene: destination.scene, translation: translation, geometry: geometry) == true else { return false }
        context = destination; transaction.active = destination; dragTransaction = transaction
        host.retarget(context: destination); resumeClock(); refresh()
        return true
    }
    private func display(at global: Point, current: DisplayContext) -> DisplayContext? {
        let matches = availableContexts.filter { $0.frame.contains(global) }
        if let same = matches.first(where: { $0.isSameLogicalDisplay(as: current) }) { return same }
        return matches.first
    }
    private func makeDragGeometry(active: DisplayContext) -> DragGeometry? {
        let contexts = availableContexts.isEmpty ? [active] : availableContexts
        var surfaces: [DragSurface] = []; var left = Double.infinity, top = Double.infinity
        var right = -Double.infinity, bottom = -Double.infinity
        for display in contexts {
            let x = display.frame.minX - active.frame.minX
            let y = active.frame.maxY - display.frame.maxY
            let bounds = Rect(x: x, y: y, width: display.frame.width, height: display.frame.height)
            let occlusion = display.scene.homeOcclusion
            let housing = Rect(x: x + occlusion.x, y: y + occlusion.y,
                               width: occlusion.width, height: occlusion.height)
            surfaces.append(DragSurface(bounds: bounds, housing: housing))
            let minX = x + display.scene.leftLimit, maxX = x + display.scene.rightLimit
            let minY = y + display.scene.ceiling, maxY = y + display.scene.floor
            left = min(left, minX); right = max(right, maxX); top = min(top, minY); bottom = max(bottom, maxY)
        }
        guard left.isFinite, top.isFinite, right > left, bottom > top else { return nil }
        let geometry = DragGeometry(surfaces: surfaces, heldBounds: Rect(x: left, y: top, width: right - left, height: bottom - top))
        return geometry.isValid ? geometry : nil
    }
    private func cancelDesktopDrag() {
        guard dragTransaction != nil else { return }
        dragTransaction = nil; engine?.send(.cancelInteraction)
        bind(layoutHome); refresh()
    }
    private func commitDropPreferences(_ next: CompanionPreferences) {
        preferences = next; preferenceStore.save(next)
        environment.configureHome(next)
        onSettingsChanged?(settingsState)
    }
}
