import AppKit
import ColorSync
import SprigletCore

/// The desktop host owns placement and input; it is independent of the renderer.
@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel

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
    /// AppKit may round the panel origin; the renderer applies the remainder
    /// to its image layer before committing the corresponding authored image.
    var onImageOffsetChanged: (@MainActor (CGPoint) -> Void)? {
        didSet { onImageOffsetChanged?(imageOffset) }
    }
    private(set) var isMoving = false
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
        guard let screen = currentScreen, let displayUUID = stableDisplayUUID(for: screen) else { return nil }
        return PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: effectiveOrigin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
    }

    private let interactionView: PetInteractionView
    private var joinsAllSpaces = true
    private var screenObservation: NotificationCenter.ObservationToken?
    private var authoredStart: NSPoint?
    private var authoredScreenID: CGDirectDisplayID?
    private var authoredGeneration: UInt64 = 0
    private var positionGeneration: UInt64 = 0
    private var dragImageOffset: CGPoint?
    private var isChangingDisplaySize = false

    /// `hitTest` receives a point in `contentView` coordinates, respecting flipped views.
    init(
        contentView: NSView,
        size: NSSize = NSSize(width: 224, height: 224),
        hitTest: @escaping @MainActor (NSPoint) -> Bool = { _ in true }
    ) {
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
            constrainToVisibleArea()
            rememberSettledPlacement()
        }

        // Foundation's actor-isolated observation is available in macOS 26.
        // AppKit's own typed screen-parameters message is not in the 26.5 SDK.
        screenObservation = NotificationCenter.default.addObserver(
            of: NSApplication.shared,
            for: ScreenParametersChanged.self
        ) { [weak self] _ in
            guard let self else { return }
            stopMovement()
            interactionView.cancelInteraction()
            if let savedPlacement {
                applyPlacement(savedPlacement)
            } else {
                constrainToVisibleArea()
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
        constrainToVisibleArea()
        // Neither makes the panel key nor activates its owning application.
        panel.orderFrontRegardless()
    }

    func hide() {
        stopMovement()
        interactionView.cancelInteraction()
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
        stopMovement()
        interactionView.cancelInteraction()
        placeAtRestingPosition()
        rememberSettledPlacement()
    }

    private func placeAtRestingPosition() {
        guard let screen = currentScreen else { return }
        positionWindow(at: PetPlacement.restingOrigin(
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }

    func moveToNextDisplay() {
        stopMovement()
        interactionView.cancelInteraction()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let index = currentScreen.flatMap { screenIndex(matching: $0, in: screens) } ?? -1
        let nextScreen = screens[(index + 1) % screens.count]
        positionWindow(at: PetPlacement.restingOrigin(
            windowSize: panel.frame.size,
            visibleFrame: nextScreen.visibleFrame
        ))
        rememberSettledPlacement()
    }

    /// An accessible alternative to dragging, bounded to the current usable area.
    func nudge(dx: CGFloat, dy: CGFloat) {
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
        panel.ignoresMouseEvents = enabled
    }

    func updateAccessibility(name: String, status: String, canPress: Bool, actions: [NSAccessibilityCustomAction]) {
        interactionView.updateAccessibility(name: name, status: status, canPress: canPress, actions: actions)
    }

    func setAllSpaces(_ enabled: Bool) {
        joinsAllSpaces = enabled
        updateCollectionBehavior()
    }

    /// Compatibility entry point for diagnostics; timing belongs to the authored
    /// clip, and this host never starts a separate movement clock.
    func beginWalk(duration: TimeInterval = 3) {
        guard duration.isFinite, duration > 0 else { return }
        onWalkRequested?()
    }

    func canFitRootMotion(_ offsets: [SamplePoint]) -> Bool {
        guard !isChangingDisplaySize, let screen = currentScreen,
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
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Bridge the stable AppKit notification into Foundation's macOS 26 typed API.
private struct ScreenParametersChanged: NotificationCenter.MainActorMessage {
    typealias Subject = NSApplication

    static var name: Notification.Name { NSApplication.didChangeScreenParametersNotification }

    static func makeMessage(_ notification: Notification) -> Self? { Self() }
}
