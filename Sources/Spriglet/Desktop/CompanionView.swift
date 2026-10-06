import AppKit
import QuartzCore
import CompanionCore
import CompanionRendering

@MainActor final class CompanionView: NSView {
    var onInput: ((CompanionInput) -> Void)?
    var onPointerInput: ((DesktopPointerInput) -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    var onControlAction: ((AppControlAction) -> Void)?
    /// Optional instrumentation owned by the finite profiling tool.
    var onDraw: ((Double) -> Void)?
    var context: DisplayContext
    var snapshot: CompanionSnapshot
    var drawingOrigin = Point.zero
    private let renderer = MallowRenderer()
    private var presenceDescription = ""
    private var acceptsInput = true
    private var isPaused = false
    init(context: DisplayContext, snapshot: CompanionSnapshot) {
        self.context = context; self.snapshot = snapshot
        super.init(frame: NSRect(x: 0, y: 0, width: WindowGeometry.width * context.scene.scale,
                                height: WindowGeometry.height * context.scene.scale))
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(AppText.companionName); setAccessibilityHelp(AppText.accessibleCharacterHelp)
        refresh(snapshot: snapshot)
    }
    required init?(coder: NSCoder) { fatalError("Use init(context:snapshot:)") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let started = onDraw == nil ? nil : CACurrentMediaTime()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: drawingOrigin.x, yBy: drawingOrigin.y); transform.concat()
        renderer.draw(snapshot)
        NSGraphicsContext.restoreGraphicsState()
        if let started { onDraw?(CACurrentMediaTime() - started) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return snapshot.contains(Point(x: p.x - drawingOrigin.x, y: p.y - drawingOrigin.y)) ? self : nil
    }
    override func accessibilityFrame() -> NSRect {
        let hit = snapshot.hitBounds
        return NSRect(x: context.frame.minX + hit.minX, y: context.frame.maxY - hit.maxY, width: hit.width, height: hit.height)
    }
    override func accessibilityPerformPress() -> Bool {
        guard acceptsInput, let onInput else { return false }
        onInput(.activate); return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        if acceptsInput {
            for (command, title) in [(CompanionCommand.greet, AppText.inviteMallow),
                                     (.swing, AppText.swingMallow),
                                     (.stretch, AppText.stretchMallow)] {
                actions.append(NSAccessibilityCustomAction(name: title) { [weak self] in
                    guard let self, self.acceptsInput, let onInput = self.onInput else { return false }
                    onInput(.command(command)); return true
                })
            }
        }
        let offeredWhilePaused = isPaused
        for (action, title) in [(AppControlAction.bringHome, AppText.bringHome),
                                (.togglePause, isPaused ? AppText.resumeMallow : AppText.pauseMallow),
                                (.toggleVisibility, AppText.hideMallow), (.settings, AppText.settingsMenu),
                                (.introduction, AppText.introductionMenu), (.help, AppText.supportTitle)] {
            actions.append(NSAccessibilityCustomAction(name: title) { [weak self] in
                guard let self, self.window?.isVisible == true, let onControlAction = self.onControlAction else { return false }
                // VoiceOver may retain actions across updates. A named Pause
                // must never resume, and a retained Hide must never show.
                if action == .togglePause && self.isPaused != offeredWhilePaused { return false }
                onControlAction(action); return true
            })
        }
        return actions
    }
    func refresh(snapshot: CompanionSnapshot, acceptsInput: Bool = true, isPaused: Bool = false) {
        self.snapshot = snapshot; self.acceptsInput = acceptsInput; self.isPaused = isPaused
        let description: String
        if isPaused { description = AppText.pausedPresence }
        else {
            description = switch snapshot.phase {
            case .held: snapshot.canCatch ? AppText.catchReadyPresence : AppText.heldPresence
            case .falling, .jumping, .preparingJump: AppText.movingPresence
            case .catching: AppText.returningPresence
            case .grounded: AppText.groundedPresence
            case .hanging:
                switch snapshot.presence {
                case .peek: AppText.restingPresence
                case .engaged: AppText.engagedPresence
                case .playing: AppText.playingPresence
                }
            }
        }
        if description != presenceDescription {
            presenceDescription = description; setAccessibilityValue(description)
            if window != nil { NSAccessibility.post(element: self, notification: .valueChanged) }
        }
        needsDisplay = true
    }
    func retarget(context: DisplayContext) {
        self.context = context
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
    private func globalPoint(_ event: NSEvent) -> Point {
        let screenPoint = window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        return Point(x: screenPoint.x, y: screenPoint.y)
    }
    override func mouseDown(with event: NSEvent) { onPointerInput?(.pressed(globalPoint(event))) }
    override func mouseDragged(with event: NSEvent) { onPointerInput?(.dragged(globalPoint(event))) }
    override func mouseUp(with event: NSEvent) { onPointerInput?(.released(globalPoint(event))) }
    override func rightMouseDown(with event: NSEvent) {
        onInput?(.command(.returnHome))
        if let menu = makeContextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
