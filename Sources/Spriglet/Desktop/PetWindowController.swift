import AppKit
import ColorSync
import QuartzCore
import SprigletCore

/// The desktop host owns placement and input; it is independent of the renderer.
@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel

    var onPetClicked: (@MainActor () -> Void)?
    /// Covers the entire click hold or drag, as well as accessibility presses.
    var onUserInteractionChanged: (@MainActor (Bool) -> Void)?
    var onMovementChanged: (@MainActor (Bool) -> Void)?
    /// The value is true when AppKit reports some of the panel as visible.
    var onOcclusionChanged: (@MainActor (Bool) -> Void)?
    var onScreenChanged: (@MainActor () -> Void)?
    /// Fires only after a completed drag or an explicit placement command.
    var onPlacementSettled: (@MainActor (PetSavedPlacement) -> Void)?
    private(set) var isMoving = false
    private(set) var movementTickCount: UInt64 = 0
    private(set) var savedPlacement: PetSavedPlacement?

    /// A nonmutating snapshot of the actual position, which may differ after a walk.
    var currentPlacement: PetSavedPlacement? {
        guard let screen = currentScreen, let displayUUID = stableDisplayUUID(for: screen) else { return nil }
        return PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: panel.frame.origin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
    }

    var movementFrameRate: Int = 60 {
        didSet { updateMovementFrameRate() }
    }

    private let interactionView: PetInteractionView
    private var joinsAllSpaces = true
    private var screenObservation: NotificationCenter.ObservationToken?
    private var movementDisplayLink: CADisplayLink?
    private var movementTarget: MovementDisplayLinkTarget?
    private var walk: Walk?

    /// `hitTest` receives a point in `contentView` coordinates, respecting flipped views.
    init(
        contentView: NSView,
        size: NSSize = NSSize(width: 192, height: 192),
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
            self?.onUserInteractionChanged?(interacting)
        }
        interactionView.onPressed = { [weak self] in
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
            updateMovementFrameRate()
            onScreenChanged?()
        }

        placeAtRestingPosition()
    }

    isolated deinit {
        movementDisplayLink?.invalidate()
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
        panel.setFrameOrigin(PetPlacement.restingOrigin(
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
        panel.setFrameOrigin(PetPlacement.restingOrigin(
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
        panel.setFrameOrigin(PetPlacement.clampedOrigin(
            NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy),
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

    func setAllSpaces(_ enabled: Bool) {
        joinsAllSpaces = enabled
        updateCollectionBehavior()
    }

    /// Runs one bounded movement probe. No display link remains when it finishes.
    func beginWalk(duration: TimeInterval = 3) {
        stopMovement()
        interactionView.cancelInteraction()
        guard duration.isFinite, duration > 0, panel.isVisible,
              let screen = currentScreen else { return }

        let start = PetPlacement.clampedOrigin(
            panel.frame.origin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(start)
        let distance = min(240, screen.visibleFrame.width * 0.25)
        let direction: CGFloat = panel.frame.midX < screen.visibleFrame.midX ? 1 : -1
        let end = PetPlacement.clampedOrigin(
            NSPoint(x: start.x + direction * distance, y: start.y),
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        guard abs(end.x - start.x) > 1 else { return }

        walk = Walk(start: start, end: end, startedAt: CACurrentMediaTime(), duration: duration)
        let target = MovementDisplayLinkTarget(owner: self)
        let displayLink = interactionView.displayLink(
            target: target,
            selector: #selector(MovementDisplayLinkTarget.tick(_:))
        )
        movementTarget = target
        movementDisplayLink = displayLink
        updateMovementFrameRate()
        setMoving(true)
        displayLink.add(to: .main, forMode: .common)
    }

    func stopMovement() {
        movementDisplayLink?.invalidate()
        movementDisplayLink = nil
        movementTarget = nil
        walk = nil
        setMoving(false)
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
        // AppKit's view display link follows the new display. Refresh its rate
        // hint, but do not clamp partway through a user's cross-display drag.
        updateMovementFrameRate()
        onScreenChanged?()
    }

    fileprivate func advanceMovement(_ displayLink: CADisplayLink) {
        movementTickCount &+= 1
        guard let walk, panel.isVisible else {
            stopMovement()
            return
        }
        let progress = min(1, max(0, (displayLink.targetTimestamp - walk.startedAt) / walk.duration))
        let easedProgress = progress * progress * (3 - 2 * progress)
        panel.setFrameOrigin(NSPoint(
            x: walk.start.x + (walk.end.x - walk.start.x) * easedProgress,
            y: walk.start.y + (walk.end.y - walk.start.y) * easedProgress
        ))
        if progress >= 1 {
            stopMovement()
        }
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
        panel.setFrameOrigin(origin)
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

    private func updateMovementFrameRate() {
        let rate = Float(max(1, min(movementFrameRate, currentScreen?.maximumFramesPerSecond ?? 60)))
        movementDisplayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(30, rate),
            maximum: rate,
            preferred: rate
        )
    }

    private func move(to origin: NSPoint, following pointer: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? nearestScreen(to: pointer) else { return }
        panel.setFrameOrigin(PetPlacement.clampedOrigin(
            origin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }

    private func constrainToVisibleArea() {
        guard let screen = currentScreen else { return }
        panel.setFrameOrigin(PetPlacement.clampedOrigin(
            panel.frame.origin,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        ))
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

    private struct Walk {
        let start: NSPoint
        let end: NSPoint
        let startedAt: CFTimeInterval
        let duration: TimeInterval
    }
}

@MainActor
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// CADisplayLink retains its target; this proxy does not retain the controller.
@MainActor
private final class MovementDisplayLinkTarget: NSObject {
    private weak var owner: PetWindowController?

    init(owner: PetWindowController) {
        self.owner = owner
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        guard let owner else {
            displayLink.invalidate()
            return
        }
        owner.advanceMovement(displayLink)
    }
}

/// Bridge the stable AppKit notification into Foundation's macOS 26 typed API.
private struct ScreenParametersChanged: NotificationCenter.MainActorMessage {
    typealias Subject = NSApplication

    static var name: Notification.Name { NSApplication.didChangeScreenParametersNotification }

    static func makeMessage(_ notification: Notification) -> Self? { Self() }
}
