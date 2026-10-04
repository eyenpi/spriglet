import AppKit
import CompanionCore

/// Nonactivation alone still permits some panels to take keyboard focus.
@MainActor private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Native window mechanics only. Has no behavioral state machine or clock.
@MainActor final class CompanionWindowHost {
    var onInput: ((CompanionInput) -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    var onShowSettings: (() -> Void)?
    var onDraw: ((Double) -> Void)?
    private var panel: NSPanel?
    private var view: CompanionView?
    private var requestedFrame: Rect?
    func attach(context: DisplayContext, snapshot: CompanionSnapshot) {
        close()
        let view = CompanionView(context: context, snapshot: snapshot)
        view.onInput = { [weak self] input in self?.onInput?(input) }
        view.makeContextMenu = makeContextMenu
        view.onShowSettings = { [weak self] in self?.onShowSettings?() }
        view.onDraw = onDraw
        let panel = CompanionPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true; panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.title = AppText.companionName; panel.contentView = view; panel.ignoresMouseEvents = true
        self.panel = panel; self.view = view
        update(snapshot: snapshot, capturesPointer: false, pointer: context.point(NSEvent.mouseLocation))
    }
    func update(snapshot: CompanionSnapshot, capturesPointer: Bool, pointer: Point, acceptsInput: Bool = true) {
        guard let panel, let view else { return }
        let frame = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: view.context.frame,
                                               scale: snapshot.scene.scale, visibleBounds: snapshot.hitBounds)
        // Avoid window-server work for the stationary home. Compare requested
        // positions, since macOS may clamp the actual panel to the display.
        if requestedFrame.map({ abs(frame.x - $0.x) > 0.05 || abs(frame.y - $0.y) > 0.05
            || abs(frame.width - $0.width) > 0.05 || abs(frame.height - $0.height) > 0.05 }) ?? true {
            panel.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            requestedFrame = frame
        }
        let actual = panel.frame
        view.drawingOrigin = WindowGeometry.drawingOrigin(
            window: Rect(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height), display: view.context.frame
        )
        let passThrough = !acceptsInput || (!capturesPointer && !snapshot.contains(pointer))
        if panel.ignoresMouseEvents != passThrough { panel.ignoresMouseEvents = passThrough }
        view.refresh(snapshot: snapshot)
    }
    func setVisible(_ visible: Bool, restoringOrder: Bool = false) {
        guard let panel, restoringOrder || panel.isVisible != visible else { return }
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    func close() { panel?.orderOut(nil); panel?.close(); panel = nil; view = nil; requestedFrame = nil }
}
