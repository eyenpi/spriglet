import AppKit
import CompanionCore

/// WindowServer skips completely transparent drag destinations. A faint native
/// backing keeps this surface eligible without drawing a visible drop target.
@MainActor final class IntakeDropPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = NSColor.white.withAlphaComponent(0.01); hasShadow = false
        level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = content; setAccessibilityElement(false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Keep the circular destination centered on Mallow at the display edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Native drag destination exists only for a fresh external drag near Mallow.
/// Its panel never participates in ordinary click/drag play.
@MainActor final class IntakeDropHost {
    var onHover: ((Bool) -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?
    private var panel: NSPanel?
    private var destination: IntakeDropView?
    private var pasteboardCount = NSPasteboard(name: .drag).changeCount
    private var externalDrag = false
    private var hovering = false
    func update(context: DisplayContext, snapshot: CompanionSnapshot, enabled: Bool, playing: Bool) {
        let board = NSPasteboard(name: .drag)
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if !buttonDown, destination?.hasNativeDrag != true { externalDrag = false; pasteboardCount = board.changeCount }
        else if board.changeCount != pasteboardCount {
            pasteboardCount = board.changeCount; externalDrag = IntakeDropView.accepts(board)
        }
        let point = NSEvent.mouseLocation
        let center = context.globalPoint(scene: Point(x: snapshot.hitBounds.midX, y: snapshot.hitBounds.midY))
        let near = hypot(point.x - center.x, point.y - center.y) <= 80
        guard enabled, !playing, externalDrag, near else { hide(); return }
        if panel == nil {
            let view = IntakeDropView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
            view.onDrop = { [weak self] in self?.onDrop?($0) ?? false }
            view.onHover = { [weak self] in self?.setHover($0) }
            let panel = IntakeDropPanel(content: view)
            self.panel = panel; destination = view
        }
        panel?.setFrame(NSRect(x: center.x - 80, y: center.y - 80, width: 160, height: 160), display: false)
        panel?.orderFrontRegardless(); setHover(true)
    }
    private func setHover(_ value: Bool) { guard value != hovering else { return }; hovering = value; onHover?(value) }
    private func hide() { panel?.orderOut(nil); setHover(false) }
    func close() { hide(); panel?.close(); panel = nil; destination = nil; externalDrag = false }
}
@MainActor final class IntakeDropView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onHover: ((Bool) -> Void)?
    private(set) var hasNativeDrag = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .URL, .fileURL, .tiff, NSPasteboard.PasteboardType("public.png")])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    static func accepts(_ board: NSPasteboard) -> Bool {
        board.availableType(from: [.fileURL, .URL, .string, .tiff, NSPasteboard.PasteboardType("public.png")]) != nil
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasNativeDrag = true
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let near = hypot(p.x - bounds.midX, p.y - bounds.midY) <= 80 && Self.accepts(sender.draggingPasteboard)
        // NSTextView/TextEdit advertises .generic for external selected-text
        // drags. Negotiate that transfer when .copy is unavailable; never move.
        let mask = sender.draggingSourceOperationMask
        let operation: NSDragOperation = mask.contains(.copy) ? .copy : (mask.contains(.generic) ? .generic : [])
        onHover?(near && !operation.isEmpty)
        return near ? operation : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { hasNativeDrag = false; onHover?(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { hasNativeDrag = false; onHover?(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !draggingUpdated(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { return false }
        onHover?(false); return onDrop?(sender.draggingPasteboard) ?? false
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { hasNativeDrag = false; onHover?(false) }
}
