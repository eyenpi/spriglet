import AppKit

/// Local hit testing and dragging need no global event monitor or polling loop.
@MainActor
final class PetInteractionView: NSView {
    var onUserInteractionChanged: (@MainActor (Bool) -> Void)?
    var onPressed: (@MainActor () -> Void)?
    var onDragBegan: (@MainActor () -> Void)?
    var onClicked: (@MainActor () -> Void)?
    var onDragged: (@MainActor (NSPoint, NSPoint) -> Void)?
    var onDragEnded: (@MainActor () -> Void)?
    /// A live runtime acceptance check for assistive activation. The fallback
    /// keeps standalone desktop hosts compatible with their ordinary callback.
    var onAccessibilityPress: (@MainActor () -> Bool)?
    /// Opt-in diagnostics describe received entry points without input content.
    var onInputEvent: (@MainActor (String) -> Void)?

    private let renderedContent: NSView
    private let containsPet: @MainActor (NSPoint) -> Bool
    private var drag: Drag?
    private var isInteracting = false
    private var accessibilityCanPress = true

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
        setAccessibilityIdentifier("spriglet.pet.interaction")
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
        onInputEvent?("mouseDown")
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
            onInputEvent?("dragBegan")
            onDragBegan?()
            guard isInteracting else { return }
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
            onInputEvent?("mouseUp-drag")
            onDragEnded?()
        } else {
            let point = renderedContent.convert(event.locationInWindow, from: nil)
            if containsPet(point) {
                onInputEvent?("mouseUp-click")
                onClicked?()
            }
        }
    }

    override func mouseCancelled(with event: NSEvent) {
        onInputEvent?("mouseCancelled")
        cancelInteraction()
    }

    /// Availability applies only to the primary action. Disabling the complete
    /// element would also hide useful custom Resume or Park actions from clients.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return accessibilityCanPress }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    /// Runtime state updates are infrequent; authored frame ticks never call this.
    func updateAccessibility(name: String, status: String, canPress: Bool, actions: [NSAccessibilityCustomAction]) {
        let labelChanged = accessibilityLabel() != name
        let statusChanged = (accessibilityValue() as? String) != status
        let actionsChanged = accessibilityCustomActions()?.map(\.name) != actions.map(\.name)
        let availabilityChanged = accessibilityCanPress != canPress
        accessibilityCanPress = canPress
        setAccessibilityLabel(name)
        setAccessibilityValue(status)
        setAccessibilityCustomActions(actions)
        setAccessibilityHelp(canPress
            ? "Pet the companion with the default action. More actions and placement controls are available in the actions menu or Spriglet menu."
            : "Petting is currently unavailable. Use an available custom action or the Spriglet menu to change its state.")
        // Keep the element available for custom actions when its primary press
        // is disallowed. The public selector query advertises that distinction.
        setAccessibilityEnabled(true)
        if labelChanged { NSAccessibility.post(element: self, notification: .titleChanged) }
        if statusChanged { NSAccessibility.post(element: self, notification: .valueChanged) }
        if actionsChanged || availabilityChanged { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    override func accessibilityPerformPress() -> Bool {
        onInputEvent?("accessibilityPress")
        guard accessibilityCanPress else { return false }
        cancelInteraction()
        setInteracting(true)
        defer { cancelInteraction() }
        guard isInteracting, accessibilityCanPress else { return false }
        onPressed?()
        guard isInteracting, accessibilityCanPress else { return false }
        if let onAccessibilityPress { return onAccessibilityPress() }
        guard let onClicked else { return false }
        onClicked()
        return true
    }

    func cancelInteraction() {
        let wasInteracting = drag != nil || isInteracting
        drag = nil
        setInteracting(false)
        if wasInteracting { onInputEvent?("interactionCancelled") }
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
