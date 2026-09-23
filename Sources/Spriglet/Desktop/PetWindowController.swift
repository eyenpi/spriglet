import AppKit
import ColorSync
import SprigletCore

/// The desktop host owns placement and input; it is independent of the renderer.
@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {
    let panel: PetPanel

    var onPetClicked: (@MainActor () -> Void)?
    var onAccessibilityPress: (@MainActor () -> Bool)? {
        didSet { interactionView.onAccessibilityPress = onAccessibilityPress }
    }
    var onInputEvent: (@MainActor (String) -> Void)?
    /// Covers the entire click hold or drag, as well as accessibility presses.
    var onUserInteractionChanged: (@MainActor (Bool) -> Void)?
    var onMovementChanged: (@MainActor (Bool) -> Void)?
    /// The value is true when AppKit reports some of the panel as visible.
    var onOcclusionChanged: (@MainActor (Bool) -> Void)?
    var onScreenChanged: (@MainActor () -> Void)?
    /// Fires only after a completed drag or an explicit placement command.
    var onPlacementSettled: (@MainActor (PetSavedPlacement) -> Void)?
    var onMovementInterrupted: (@MainActor () -> Void)?
    var onWalkRequested: (@MainActor () -> Void)?
    var onEyeDockChanged: (@MainActor (Bool) -> Void)?
    /// AppKit may round the panel origin; the renderer applies the remainder
    /// to its image layer before committing the corresponding authored image.
    var onImageOffsetChanged: (@MainActor (CGPoint) -> Void)? {
        didSet { onImageOffsetChanged?(imageOffset) }
    }
    private(set) var isMoving = false
    private(set) var isEyeDocked = false
    private(set) var movementTickCount: UInt64 = 0
    private(set) var savedPlacement: PetSavedPlacement?
    private(set) var appliedRootOffset = SamplePoint.zero
    private(set) var appliedFrameIndex: Int?
    private(set) var imageOffset = CGPoint.zero

    /// The image's precise desktop origin, including the retained subpoint part.
    var effectiveOrigin: CGPoint {
        CGPoint(x: panel.frame.minX + imageOffset.x, y: panel.frame.minY + imageOffset.y)
    }

    /// A nonmutating snapshot of the actual position, which may differ after a walk.
    var currentPlacement: PetSavedPlacement? {
        if isEyeDocked { return savedPlacement }
        guard let screen = currentScreen, let displayUUID = stableDisplayUUID(for: screen) else { return nil }
        return PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: effectiveOrigin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
    }

    private let interactionView: PetInteractionView
    private let habitatProvider: any HabitatProvider

    /// Rebuilt from fresh screen geometry; no NSScreen crosses into the world.
    var currentHabitat: PetHabitat? {
        if isEyeDocked { return nil }
        return currentScreen.flatMap { habitat(on: $0, windowSize: panel.frame.size) }
    }
    private var joinsAllSpaces = true
    private var screenObservation: NotificationCenter.ObservationToken?
    private var authoredStart: NSPoint?
    private var authoredScreenID: CGDirectDisplayID?
    private var authoredGeneration: UInt64 = 0
    private var positionGeneration: UInt64 = 0
    private var dragImageOffset: CGPoint?
    private var isChangingDisplaySize = false
    private let topBarEyes = TopBarEyesController()
    private var lastDragPointer: CGPoint?
    private var transitionGeneration: UInt64 = 0
    private var requestedVisible = false
    private var dragPreviewScale: CGFloat = 1
    private var isDraggingEyesOut = false
    private var eyeDragRestoresClickThrough = false
    private var transitionMotionAllowed = true

    /// `hitTest` receives a point in `contentView` coordinates, respecting flipped views.
    init(
        contentView: NSView,
        size: NSSize = NSSize(width: 224, height: 224),
        habitatProvider: any HabitatProvider = ConservativeFloorHabitatProvider(),
        hitTest: @escaping @MainActor (NSPoint) -> Bool = { _ in true }
    ) {
        self.habitatProvider = habitatProvider
        interactionView = PetInteractionView(contentView: contentView, hitTest: hitTest)
        panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Spriglet"
        panel.identifier = NSUserInterfaceItemIdentifier("spriglet.pet")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = false
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.contentView = interactionView
        panel.delegate = self
        updateCollectionBehavior()

        interactionView.onUserInteractionChanged = { [weak self] interacting in
            guard let self else { return }
            // The input view reports a delta from the original panel origin.
            // Capture this once so successive drag events cannot add it twice.
            dragImageOffset = interacting ? imageOffset : nil
            onUserInteractionChanged?(interacting)
        }
        interactionView.onInputEvent = { [weak self] event in
            self?.onInputEvent?(event)
        }
        interactionView.onDragBegan = { [weak self] in
            self?.stopMovement()
        }
        interactionView.onClicked = { [weak self] in
            self?.onPetClicked?()
        }
        interactionView.onDragged = { [weak self] origin, pointer in
            self?.move(to: origin, following: pointer)
        }
        interactionView.onDragEnded = { [weak self] in
            guard let self else { return }
            defer {
                lastDragPointer = nil
                if !isEyeDocked && dragPreviewScale < 1 {
                    animatePetScale(from: dragPreviewScale, to: 1, duration: 0.2)
                }
                setDragPreviewScale(1)
            }
            if let pointer = lastDragPointer,
               let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
               TopBarEyePlacement.isNearTop(pointer, screenFrame: screen.frame),
               setTopBarMode(true, animated: true, on: screen) { return }
            constrainToVisibleArea()
            rememberSettledPlacement()
        }
        topBarEyes.onReturn = { [weak self] in
            self?.setTopBarMode(false, animated: true)
        }
        topBarEyes.onDragOut = { [weak self] pointer in
            self?.beginEyeDragOut(at: pointer)
        }
        topBarEyes.onDragProgress = { [weak self] pointer in
            self?.updateEyeDragOut(at: pointer)
        }
        topBarEyes.onDragFinished = { [weak self] pointer in
            self?.finishEyeDragOut(at: pointer)
        }

        // Foundation's actor-isolated observation is available in macOS 26.
        // AppKit's own typed screen-parameters message is not in the 26.5 SDK.
        screenObservation = NotificationCenter.default.addObserver(
            of: NSApplication.shared,
            for: ScreenParametersChanged.self
        ) { [weak self] _ in
            guard let self else { return }
            cancelEyeDragOut()
            stopMovement()
            interactionView.cancelInteraction()
            if let savedPlacement {
                applyPlacement(savedPlacement)
            } else {
                constrainToVisibleArea()
            }
            if isEyeDocked, let screen = currentScreen,
               !topBarEyes.show(on: screen, animated: false) {
                setTopBarMode(false, animated: false)
            }
            onScreenChanged?()
        }

        placeAtRestingPosition()
    }

    isolated deinit {
        if let screenObservation {
            NotificationCenter.default.removeObserver(screenObservation)
        }
    }

    func show() {
        requestedVisible = true
        if isEyeDocked {
            if let screen = currentScreen { _ = topBarEyes.show(on: screen, animated: false) }
            return
        }
        constrainToVisibleArea()
        // Neither makes the panel key nor activates its owning application.
        panel.orderFrontRegardless()
    }

    func hide() {
        requestedVisible = false
        cancelEyeDragOut()
        stopMovement()
        interactionView.cancelInteraction()
        panel.allowsTopBarTransition = false
        topBarEyes.hide()
        panel.orderOut(nil)
    }

    /// Sleep, session loss, and other suspension causes may omit mouse-up.
    /// Discard any held press or drag so a later release cannot revive it.
    func cancelInteraction() {
        interactionView.cancelInteraction()
    }

    /// Retains the effective canvas bottom-center on the current display,
    /// clamping only when its new dimensions need room. The baked foot/shadow
    /// baseline scales within the canvas. Saved home intent stays verbatim,
    /// including a preferred display that is currently disconnected.
    func setDisplaySize(_ choice: PetDisplaySize) {
        setDisplaySize(choice.size)
    }

    func setDisplaySize(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              panel.frame.size != size, !isChangingDisplaySize else { return }
        isChangingDisplaySize = true
        defer { isChangingDisplaySize = false }
        stopMovement()
        interactionView.cancelInteraction()
        let oldFrame = CGRect(origin: effectiveOrigin, size: panel.frame.size)
        let desired: CGPoint
        if let screen = currentScreen {
            desired = PetPlacement.clampedOrigin(CGPoint(x: oldFrame.midX - size.width / 2, y: oldFrame.minY),
                                                 windowSize: size, visibleFrame: screen.visibleFrame)
        } else {
            desired = CGPoint(x: oldFrame.midX - size.width / 2, y: oldFrame.minY)
        }
        positionWindow(at: desired, size: size)
    }

    /// Restores silently; the runtime remains responsible for persistence.
    /// Diagnostics can restore an actual-position snapshot while retaining the
    /// user's saved home, including a home on a currently disconnected display.
    func restorePlacement(_ placement: PetSavedPlacement?, preservingSavedPlacement: Bool = false) {
        stopMovement()
        interactionView.cancelInteraction()
        if !preservingSavedPlacement {
            savedPlacement = placement
        }
        if let placement {
            applyPlacement(placement)
        } else if preservingSavedPlacement {
            constrainToVisibleArea()
        } else {
            placeAtRestingPosition()
        }
    }

    /// Restores the pet near the lower edge of its current display.
    func recenter() {
        if isEyeDocked { setTopBarMode(false, animated: false) }
        stopMovement()
        interactionView.cancelInteraction()
        placeAtRestingPosition()
        rememberSettledPlacement()
    }

    private func placeAtRestingPosition() {
        guard let screen = currentScreen else { return }
        positionWindow(at: restingOrigin(on: screen))
    }

    func moveToNextDisplay() {
        if isEyeDocked { setTopBarMode(false, animated: false) }
        stopMovement()
        interactionView.cancelInteraction()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let index = currentScreen.flatMap { screenIndex(matching: $0, in: screens) } ?? -1
        let nextScreen = screens[(index + 1) % screens.count]
        positionWindow(at: restingOrigin(on: nextScreen))
        rememberSettledPlacement()
    }

    private func habitat(on screen: NSScreen, windowSize: CGSize) -> PetHabitat? {
        guard let identity = stableDisplayUUID(for: screen),
              let display = HabitatDisplayGeometry(displayID: identity, visibleFrame: screen.visibleFrame) else { return nil }
        return habitatProvider.habitat(for: display, windowSize: windowSize, margin: 12)
    }

    private func restingOrigin(on screen: NSScreen) -> CGPoint {
        // A display without a persistent UUID still supports existing placement.
        habitat(on: screen, windowSize: panel.frame.size)?.restingOrigin
            ?? PetPlacement.restingOrigin(windowSize: panel.frame.size, visibleFrame: screen.visibleFrame)
    }

    /// An accessible alternative to dragging, bounded to the current usable area.
    func nudge(dx: CGFloat, dy: CGFloat) {
        if isEyeDocked { setTopBarMode(false, animated: false) }
        guard dx.isFinite, dy.isFinite, let screen = currentScreen else { return }
        stopMovement()
        interactionView.cancelInteraction()
        positionWindow(at: PetPlacement.clampedOrigin(
            NSPoint(x: effectiveOrigin.x + dx, y: effectiveOrigin.y + dy),
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        ))
        rememberSettledPlacement()
    }

    /// Whole-window click-through is the supported, deterministic fallback.
    func setClickThrough(_ enabled: Bool) {
        interactionView.cancelInteraction()
        eyeDragRestoresClickThrough = enabled
        panel.ignoresMouseEvents = isDraggingEyesOut || enabled
        topBarEyes.setClickThrough(enabled)
    }

    func updateAccessibility(name: String, status: String, canPress: Bool, actions: [NSAccessibilityCustomAction]) {
        interactionView.updateAccessibility(name: name, status: status, canPress: canPress, actions: actions)
    }

    func setAllSpaces(_ enabled: Bool) {
        joinsAllSpaces = enabled
        updateCollectionBehavior()
        topBarEyes.setAllSpaces(enabled)
    }

    func setEyeMotionAllowed(_ allowed: Bool) {
        transitionMotionAllowed = allowed
        topBarEyes.setMotionAllowed(allowed)
    }

    /// Dragging near the menu bar enters this mode. The reverse transition is
    /// also available from the eyes, the menu, and accessibility activation.
    @discardableResult
    func setTopBarMode(_ enabled: Bool, animated: Bool = true,
                       on preferredScreen: NSScreen? = nil, releasePoint: CGPoint? = nil) -> Bool {
        if isDraggingEyesOut { cancelEyeDragOut() }
        guard enabled != isEyeDocked else { return true }
        let animated = animated && transitionMotionAllowed
        transitionGeneration &+= 1
        let generation = transitionGeneration
        if enabled {
            guard let screen = preferredScreen ?? currentScreen,
                  topBarEyes.show(on: screen, animated: animated) else { return false }
            if !requestedVisible { topBarEyes.hide() }
            stopMovement()
            isEyeDocked = true
            onEyeDockChanged?(true)
            onOcclusionChanged?(true)
            let oldFrame = panel.frame
            let destination = CGPoint(x: topBarEyes.panel.frame.midX - oldFrame.width / 2,
                                      y: topBarEyes.panel.frame.midY - oldFrame.height / 2)
            if animated && panel.isVisible && requestedVisible {
                panel.allowsTopBarTransition = true
                animatePetScale(from: dragPreviewScale, to: 0.14, duration: 0.42)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.42
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrameOrigin(destination)
                    panel.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.transitionGeneration == generation, self.isEyeDocked else { return }
                        self.panel.orderOut(nil)
                        self.panel.setFrame(oldFrame, display: false)
                        self.panel.allowsTopBarTransition = false
                        self.panel.alphaValue = 1
                        self.setDragPreviewScale(1)
                    }
                }
            } else {
                panel.orderOut(nil)
                setDragPreviewScale(1)
            }
            return true
        }

        isEyeDocked = false
        let screen = releasePoint.flatMap { point in NSScreen.screens.first(where: { $0.frame.contains(point) }) }
            ?? currentScreen ?? NSScreen.main
        let size = panel.frame.size
        let destination: CGPoint
        if let releasePoint, let screen {
            destination = PetPlacement.clampedOrigin(
                CGPoint(x: releasePoint.x - size.width / 2, y: releasePoint.y - size.height / 2),
                windowSize: size, visibleFrame: screen.visibleFrame)
        } else if let screen, let savedPlacement,
                  let restored = savedPlacement.restoredOrigin(windowSize: size, visibleFrame: screen.visibleFrame) {
            destination = restored
        } else if let screen {
            destination = restingOrigin(on: screen)
        } else {
            destination = panel.frame.origin
        }
        let eyeFrame = topBarEyes.panel.frame
        topBarEyes.hide(animated: animated && requestedVisible)
        if animated && requestedVisible {
            let start = CGPoint(x: eyeFrame.midX - size.width / 2, y: eyeFrame.midY - size.height / 2)
            panel.allowsTopBarTransition = true
            positionWindow(at: start)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animatePetScale(from: 0.14, to: 1, duration: 0.42)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrameOrigin(destination)
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transitionGeneration == generation, !self.isEyeDocked else { return }
                    self.positionWindow(at: destination)
                    self.panel.allowsTopBarTransition = false
                    self.setDragPreviewScale(1)
                    self.rememberSettledPlacement()
                    self.onEyeDockChanged?(false)
                }
            }
        } else {
            positionWindow(at: destination)
            panel.allowsTopBarTransition = false
            panel.alphaValue = 1
            if requestedVisible { panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
            rememberSettledPlacement()
            onEyeDockChanged?(false)
        }
        onOcclusionChanged?(true)
        return true
    }

    private func beginEyeDragOut(at point: CGPoint) {
        guard isEyeDocked, requestedVisible, !isDraggingEyesOut else { return }
        transitionGeneration &+= 1
        isDraggingEyesOut = true
        eyeDragRestoresClickThrough = panel.ignoresMouseEvents
        topBarEyes.setDraggingOut(true)
        // The eye panel must keep receiving the rest of this mouse sequence.
        // The revealed pet therefore follows the pointer without taking input.
        panel.ignoresMouseEvents = true
        panel.allowsTopBarTransition = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        updateEyeDragOut(at: point)
    }

    private func updateEyeDragOut(at point: CGPoint) {
        guard isDraggingEyesOut, point.x.isFinite, point.y.isFinite else { return }
        let size = panel.frame.size
        positionWindow(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let distance = screen.frame.maxY - point.y
            setDragPreviewScale(min(1, max(0.25, distance / 140)))
        }
    }

    private func finishEyeDragOut(at point: CGPoint) {
        guard isDraggingEyesOut else { return }
        updateEyeDragOut(at: point)
        isDraggingEyesOut = false
        isEyeDocked = false
        topBarEyes.hide()
        panel.ignoresMouseEvents = eyeDragRestoresClickThrough
        panel.allowsTopBarTransition = false
        constrainToVisibleArea()
        if dragPreviewScale < 1 { animatePetScale(from: dragPreviewScale, to: 1, duration: 0.2) }
        setDragPreviewScale(1)
        rememberSettledPlacement()
        onEyeDockChanged?(false)
        onOcclusionChanged?(true)
    }

    private func cancelEyeDragOut() {
        guard isDraggingEyesOut else { return }
        isDraggingEyesOut = false
        topBarEyes.setDraggingOut(false)
        panel.ignoresMouseEvents = eyeDragRestoresClickThrough
        panel.allowsTopBarTransition = false
        panel.orderOut(nil)
        setDragPreviewScale(1)
    }

    private func animatePetScale(from start: CGFloat, to end: CGFloat, duration: TimeInterval) {
        guard let layer = interactionView.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "topBarTransition")
    }

    private func setDragPreviewScale(_ scale: CGFloat) {
        dragPreviewScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        interactionView.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    /// Compatibility entry point for diagnostics; timing belongs to the authored
    /// clip, and this host never starts a separate movement clock.
    func beginWalk(duration: TimeInterval = 3) {
        guard duration.isFinite, duration > 0 else { return }
        onWalkRequested?()
    }

    func canFitRootMotion(_ offsets: [SamplePoint]) -> Bool {
        guard !isEyeDocked, !isChangingDisplaySize, let screen = currentScreen,
              let start = SampleMotionPlacement.fittingStartOrigin(
                preferredOrigin: effectiveOrigin, windowSize: panel.frame.size,
                visibleFrame: screen.visibleFrame, offsets: offsets
              ) else { return false }
        return abs(start.x - effectiveOrigin.x) < 0.001 && abs(start.y - effectiveOrigin.y) < 0.001
    }

    func beginAuthoredMotion(_ offsets: [SamplePoint]) -> Bool {
        guard panel.isVisible, canFitRootMotion(offsets), let screen = currentScreen else { return false }
        authoredGeneration &+= 1
        authoredStart = effectiveOrigin
        authoredScreenID = screen.cgDirectDisplayID
        appliedRootOffset = .zero
        appliedFrameIndex = nil
        return true
    }

    /// Only called with the renderer's newly selected authored frame. A held
    /// image never calls this function, so its planted position also stays fixed.
    func applyAuthoredFrame(_ snapshot: SampleTimelineSnapshot) -> Bool {
        guard let start = authoredStart, panel.isVisible, let screen = currentScreen,
              screen.cgDirectDisplayID == authoredScreenID else { return false }
        let desired = NSPoint(x: start.x + snapshot.rootOffsetPoints.x, y: start.y + snapshot.rootOffsetPoints.y)
        let bounded = PetPlacement.clampedOrigin(desired, windowSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        guard abs(bounded.x - desired.x) < 0.001, abs(bounded.y - desired.y) < 0.001 else { return false }
        let expectedGeneration = authoredGeneration
        guard positionWindow(at: desired), authoredGeneration == expectedGeneration else { return false }
        appliedRootOffset = snapshot.rootOffsetPoints
        appliedFrameIndex = snapshot.timelineFrameIndex
        let moving = snapshot.clip == .walkLeft || snapshot.clip == .walkRight
        if moving { movementTickCount &+= 1 }
        setMoving(moving)
        return true
    }

    func finishAuthoredMotion() {
        authoredGeneration &+= 1
        authoredStart = nil
        authoredScreenID = nil
        setMoving(false)
    }

    func stopMovement() {
        let interrupted = authoredStart != nil
        finishAuthoredMotion()
        if interrupted { onMovementInterrupted?() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if isEyeDocked {
            onOcclusionChanged?(topBarEyes.isVisible)
            return
        }
        let isVisible = panel.occlusionState.contains(.visible)
        if !isVisible {
            stopMovement()
            interactionView.cancelInteraction()
        }
        onOcclusionChanged?(isVisible)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // Do not clamp partway through a user's cross-display drag.
        onScreenChanged?()
    }

    private var currentScreen: NSScreen? {
        // Match against the current topology instead of retaining an NSScreen
        // across a display disconnect. Frame coordinates are in AppKit points.
        let screens = NSScreen.screens
        if let panelScreen = panel.screen,
           let index = screenIndex(matching: panelScreen, in: screens) {
            return screens[index]
        }
        return nearestScreen(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
            ?? NSScreen.main ?? screens.first
    }

    private func rememberSettledPlacement() {
        guard let placement = currentPlacement, placement != savedPlacement else { return }
        savedPlacement = placement
        onPlacementSettled?(placement)
    }

    private func applyPlacement(_ placement: PetSavedPlacement) {
        let screens = NSScreen.screens
        let fallbackIndex = NSScreen.main.flatMap { screenIndex(matching: $0, in: screens) } ?? 0
        guard let index = placement.displayIndex(
            in: screens.map { stableDisplayUUID(for: $0) },
            fallbackIndex: fallbackIndex
        ), let origin = placement.restoredOrigin(
            windowSize: panel.frame.size,
            visibleFrame: screens[index].visibleFrame
        ) else {
            constrainToVisibleArea()
            return
        }
        // Falling back never overwrites the user's preferred display identity.
        positionWindow(at: origin)
    }

    private func screenIndex(matching screen: NSScreen, in screens: [NSScreen]) -> Int? {
        if let displayID = screen.cgDirectDisplayID {
            return screens.firstIndex { $0.cgDirectDisplayID == displayID }
        }
        return screens.firstIndex { $0.frame == screen.frame }
    }

    private func stableDisplayUUID(for screen: NSScreen) -> UUID? {
        // cgDirectDisplayID is the typed macOS 26 API. Persist ColorSync's UUID,
        // not a screen-array index, localized display name, or session display ID.
        guard let displayID = screen.cgDirectDisplayID,
              let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, displayUUID) as String)
    }

    private func updateCollectionBehavior() {
        // Apple explicitly prescribes fullScreenPrimary to opt an overlay out of
        // joining other apps' full-screen Spaces. It is exclusive with
        // fullScreenAuxiliary/fullScreenNone, not with canJoinAllApplications.
        // https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications
        // Hardware acceptance nevertheless observed this complete combination
        // over another app's full-screen Space. Exclusion is not a guarantee;
        // explicit Hide / Pass Clicks Through define the supported behavior.
        // transient hides during Mission Control; do not combine with stationary.
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllApplications,
            .fullScreenPrimary,
            .fullScreenDisallowsTiling,
            .transient,
            .ignoresCycle
        ]
        if joinsAllSpaces {
            behavior.insert(.canJoinAllSpaces)
        }
        panel.collectionBehavior = behavior
    }

    private func move(to origin: NSPoint, following pointer: NSPoint) {
        guard pointer.x.isFinite, pointer.y.isFinite, !NSScreen.screens.isEmpty else { return }
        lastDragPointer = pointer
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            let distance = screen.frame.maxY - pointer.y
            let scale = min(1, max(0.34, distance / 90))
            setDragPreviewScale(scale)
        }
        let offset = dragImageOffset ?? imageOffset
        // Keep the grabbed point under the pointer while crossing display
        // boundaries. Clamping each event sticks at an edge and then jumps by
        // a window width when the pointer enters the next display. The existing
        // drag-end path confines the final placement to one usable display.
        positionWindow(at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y))
    }

    private func constrainToVisibleArea() {
        guard let screen = currentScreen else { return }
        positionWindow(at: PetPlacement.clampedOrigin(
            effectiveOrigin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }

    @discardableResult
    private func positionWindow(at desired: CGPoint, size: NSSize? = nil) -> Bool {
        guard desired.x.isFinite, desired.y.isFinite else { return false }
        positionGeneration &+= 1
        let expectedGeneration = positionGeneration
        if let size {
            panel.setFrame(NSRect(origin: desired, size: size), display: true)
        } else {
            panel.setFrameOrigin(desired)
        }
        // A screen-change callback can synchronously perform a newer placement.
        guard positionGeneration == expectedGeneration else { return false }
        imageOffset = CGPoint(x: desired.x - panel.frame.minX, y: desired.y - panel.frame.minY)
        onImageOffsetChanged?(imageOffset)
        return positionGeneration == expectedGeneration
    }

    private func nearestScreen(to point: NSPoint) -> NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            squaredDistance(from: point, to: lhs.visibleFrame)
                < squaredDistance(from: point, to: rhs.visibleFrame)
        }
    }

    private func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private func setMoving(_ moving: Bool) {
        guard isMoving != moving else { return }
        isMoving = moving
        onMovementChanged?(moving)
    }

}

@MainActor
final class PetPanel: NSPanel {
    var allowsTopBarTransition = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsTopBarTransition ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Bridge the stable AppKit notification into Foundation's macOS 26 typed API.
private struct ScreenParametersChanged: NotificationCenter.MainActorMessage {
    typealias Subject = NSApplication

    static var name: Notification.Name { NSApplication.didChangeScreenParametersNotification }

    static func makeMessage(_ notification: Notification) -> Self? { Self() }
}
