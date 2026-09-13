import AppKit

/// Local hit testing and dragging need no global event monitor or polling loop.
@MainActor
final class PetInteractionView: NSView {
    var onUserInteractionChanged: (@MainActor (Bool) -> Void)?
    var onPressed: (@MainActor () -> Void)?
    var onClicked: (@MainActor () -> Void)?
    var onDragged: (@MainActor (NSPoint, NSPoint) -> Void)?
    var onDragEnded: (@MainActor () -> Void)?

    private let renderedContent: NSView
    private let containsPet: @MainActor (NSPoint) -> Bool
    private var drag: Drag?
    private var isInteracting = false

    init(contentView: NSView, hitTest: @escaping @MainActor (NSPoint) -> Bool) {
        renderedContent = contentView
        containsPet = hitTest
        super.init(frame: contentView.frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Spriglet")
        setAccessibilityHelp("Click to play. Drag to move the companion. Controls are also available in the menu bar.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(contentView:hitTest:).") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint),
              containsPet(renderedContent.convert(localPoint, from: self)) else { return nil }
        // Returning nil outside the pet only controls AppKit view routing. It is
        // not a promise that WindowServer passes transparent pixels to other apps.
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        cancelInteraction()
        setInteracting(true)
        guard isInteracting else { return }
        onPressed?()
        guard isInteracting else { return }
        drag = Drag(
            pointerStart: window.convertPoint(toScreen: event.locationInWindow),
            windowStart: window.frame.origin
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, var drag else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let dx = pointer.x - drag.pointerStart.x
        let dy = pointer.y - drag.pointerStart.y
        if !drag.didMove, dx * dx + dy * dy >= 9 {
            drag.didMove = true
        }
        self.drag = drag
        guard drag.didMove else { return }
        onDragged?(
            NSPoint(x: drag.windowStart.x + dx, y: drag.windowStart.y + dy),
            pointer
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { setInteracting(false) }
        guard let drag else { return }
        self.drag = nil
        if drag.didMove {
            onDragEnded?()
        } else {
            let point = renderedContent.convert(event.locationInWindow, from: nil)
            if containsPet(point) {
                onClicked?()
            }
        }
    }

    override func mouseCancelled(with event: NSEvent) {
        cancelInteraction()
    }

    override func accessibilityPerformPress() -> Bool {
        cancelInteraction()
        setInteracting(true)
        defer { cancelInteraction() }
        guard isInteracting else { return false }
        onPressed?()
        guard isInteracting else { return false }
        onClicked?()
        return true
    }

    func cancelInteraction() {
        drag = nil
        setInteracting(false)
    }

    private func setInteracting(_ interacting: Bool) {
        guard isInteracting != interacting else { return }
        isInteracting = interacting
        onUserInteractionChanged?(interacting)
    }

    private struct Drag {
        let pointerStart: NSPoint
        let windowStart: NSPoint
        var didMove = false
    }
}
