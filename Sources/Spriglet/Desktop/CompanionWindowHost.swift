import AppKit
import CompanionCore

/// Native window mechanics only. Has no behavioral state machine or clock.
@MainActor final class CompanionWindowHost {
    var onInput: ((CompanionInput) -> Void)?
    var onDraw: ((Double) -> Void)?
    private var panel: NSPanel?
    private var view: CompanionView?
    private var requestedOrigin: Point?
    func attach(context: DisplayContext, snapshot: CompanionSnapshot) {
        close()
        let view = CompanionView(context: context, snapshot: snapshot)
        view.onInput = { [weak self] input in self?.onInput?(input) }
        view.onDraw = onDraw
        let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary]
        panel.title = AppText.companionName; panel.contentView = view; panel.ignoresMouseEvents = true
        self.panel = panel; self.view = view
        update(snapshot: snapshot, capturesPointer: false, pointer: context.point(NSEvent.mouseLocation))
        panel.orderFrontRegardless()
    }
    func update(snapshot: CompanionSnapshot, capturesPointer: Bool, pointer: Point) {
        guard let panel, let view else { return }
        let origin = WindowGeometry.desiredOrigin(feet: snapshot.windowAnchor, display: view.context.frame)
        // Avoid window-server work for the stationary home. Compare requested
        // positions, since macOS may clamp the actual panel to the display.
        if requestedOrigin.map({ origin.distance(to: $0) > 0.05 }) ?? true {
            panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y)); requestedOrigin = origin
        }
        let actual = panel.frame
        view.drawingOrigin = WindowGeometry.drawingOrigin(
            window: Rect(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height), display: view.context.frame
        )
        let passThrough = !capturesPointer && !snapshot.contains(pointer)
        if panel.ignoresMouseEvents != passThrough { panel.ignoresMouseEvents = passThrough }
        view.refresh(snapshot: snapshot)
    }
    func setVisible(_ visible: Bool) {
        if visible { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
    }
    func close() { panel?.orderOut(nil); panel?.close(); panel = nil; view = nil; requestedOrigin = nil }
}
