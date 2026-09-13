import AppKit

@main
enum DesktopValidationApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = FixtureController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
private final class FixtureController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let board = FixtureBoard(frame: NSRect(x: 0, y: 0, width: 1_024, height: 740))
    private var window: NSWindow?
    private var activations = 0
    private var deactivations = 0
    private var keyGains = 0
    private var keyLosses = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Desktop Validation")
        appMenu.addItem(withTitle: "Quit Desktop Validation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        let window = NSWindow(
            contentRect: board.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window = window
        window.title = "Desktop Validation — disposable input fixture"
        window.identifier = NSUserInterfaceItemIdentifier("desktop-validation.fixture")
        window.contentView = board
        window.contentMinSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.disableSnapshotRestoration()
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateFocus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        activations += 1
        updateFocus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        deactivations += 1
        updateFocus()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        keyGains += 1
        updateFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        keyLosses += 1
        updateFocus()
    }

    private func updateFocus() {
        board.focusStatus.stringValue = "App active: \(NSApp.isActive) (gained \(activations), lost \(deactivations))  •  Window key: \(window?.isKeyWindow == true) (gained \(keyGains), lost \(keyLosses))"
        board.refreshTypingStatus()
    }
}

/// Labels remain accessible but do not intercept target mouse-downs.
@MainActor
private final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) -> PassiveLabel {
    let result = PassiveLabel(wrappingLabelWithString: text)
    result.font = .systemFont(ofSize: size)
    result.textColor = color
    return result
}

@MainActor
private final class FixtureBoard: NSView, NSTextFieldDelegate {
    let focusStatus = label("Focus events pending")
    private let title = label("Desktop input and transparency", size: 23)
    private let instructions = label("Place Spriglet over either target. Click blank regions or buttons, then scroll. Only test text belongs in this disposable fixture.")
    private let predictionStatus = label("Mark a point by clicking a blank target. Then place Spriglet over the crosshair and inspect that point.")
    private let typingStatus = label("Typing focus: false  •  Text changes: 0  •  Characters: 0")
    private let typingField = NSTextField(string: "")
    private let inspectButton = FirstClickButton(title: "Inspect marked point", target: nil, action: nil)
    private let resetButton = FirstClickButton(title: "Reset targets and test text", target: nil, action: nil)
    private let lightTarget = ProbeTarget(name: "Light target", background: NSColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 1), foreground: NSColor(srgbRed: 0.12, green: 0.15, blue: 0.20, alpha: 1))
    private let darkTarget = ProbeTarget(name: "Dark target", background: NSColor(srgbRed: 0.10, green: 0.15, blue: 0.24, alpha: 1), foreground: .white)
    private weak var markedTarget: ProbeTarget?
    private var markedPoint: NSPoint?
    private var textChanges = 0
    private var inspections = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [title, instructions, lightTarget, darkTarget, predictionStatus, inspectButton, resetButton, focusStatus, typingField, typingStatus] {
            addSubview(view)
        }
        lightTarget.onMark = { [weak self] target, point in self?.mark(target: target, point: point) }
        darkTarget.onMark = { [weak self] target, point in self?.mark(target: target, point: point) }
        inspectButton.target = self
        inspectButton.action = #selector(inspectMarkedPoint)
        inspectButton.bezelStyle = .push
        inspectButton.isEnabled = false
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.bezelStyle = .push
        typingField.placeholderString = "Type a short test phrase, click the pet, then keep typing here. Text is not saved."
        typingField.delegate = self
        typingField.font = .systemFont(ofSize: 16)
        typingField.setAccessibilityLabel("Disposable typing field")
        focusStatus.setAccessibilityIdentifier("fixture.focus")
        typingStatus.setAccessibilityIdentifier("fixture.typing")
        predictionStatus.setAccessibilityIdentifier("fixture.prediction")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:).") }

    override func layout() {
        super.layout()
        let width = bounds.width - 48
        let targetWidth = (width - 20) / 2
        title.frame = NSRect(x: 24, y: bounds.height - 45, width: width, height: 30)
        instructions.frame = NSRect(x: 24, y: bounds.height - 89, width: width, height: 38)
        lightTarget.frame = NSRect(x: 24, y: 260, width: targetWidth, height: bounds.height - 355)
        darkTarget.frame = NSRect(x: 44 + targetWidth, y: 260, width: targetWidth, height: bounds.height - 355)
        predictionStatus.frame = NSRect(x: 24, y: 208, width: width, height: 42)
        inspectButton.frame = NSRect(x: 24, y: 169, width: 200, height: 32)
        resetButton.frame = NSRect(x: 238, y: 169, width: 240, height: 32)
        focusStatus.frame = NSRect(x: 24, y: 124, width: width, height: 34)
        typingField.frame = NSRect(x: 24, y: 77, width: width, height: 34)
        typingStatus.frame = NSRect(x: 24, y: 22, width: width, height: 44)
    }

    private func mark(target: ProbeTarget, point: NSPoint) {
        lightTarget.markedPoint = target === lightTarget ? point : nil
        darkTarget.markedPoint = target === darkTarget ? point : nil
        markedTarget = target
        markedPoint = point
        inspectButton.isEnabled = true
        predictionStatus.stringValue = "Marked \(target.name) at local (\(Int(point.x)), \(Int(point.y))). Inspect after placing Spriglet over this point; a prediction does not replace a received event."
    }

    @objc private func inspectMarkedPoint() {
        guard let window, let markedTarget, let markedPoint else { return }
        let screenPoint = window.convertPoint(toScreen: markedTarget.convert(markedPoint, to: nil))
        let predicted = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        inspections += 1
        predictionStatus.stringValue = "Inspection \(inspections) — screen (\(Int(screenPoint.x)), \(Int(screenPoint.y)))  •  Predicted mouse-down window: \(predicted)  •  Fixture window: \(window.windowNumber)\nPrediction only. Compare actual target/button counts; inspect again after moving any window."
        refreshTypingStatus()
    }

    @objc private func reset() {
        lightTarget.reset()
        darkTarget.reset()
        markedTarget = nil
        markedPoint = nil
        inspections = 0
        inspectButton.isEnabled = false
        typingField.stringValue = ""
        textChanges = 0
        predictionStatus.stringValue = "Mark a point by clicking a blank target. Then place Spriglet over the crosshair and inspect that point."
        refreshTypingStatus()
    }

    func controlTextDidBeginEditing(_ obj: Notification) { refreshTypingStatus() }
    func controlTextDidEndEditing(_ obj: Notification) { refreshTypingStatus() }
    func controlTextDidChange(_ obj: Notification) {
        textChanges += 1
        refreshTypingStatus()
    }

    func refreshTypingStatus() {
        let editor = typingField.currentEditor()
        let focused = NSApp.isActive && window?.isKeyWindow == true && editor != nil && window?.firstResponder === editor
        typingStatus.stringValue = "Typing focus: \(focused)  •  Text changes: \(textChanges)  •  Characters: \(typingField.stringValue.count)\nFocus totals include launch and automation activation. Counters and text stay in memory; closing this fixture ends the test."
    }
}

@MainActor
private final class ProbeTarget: NSView {
    let name: String
    var onMark: ((ProbeTarget, NSPoint) -> Void)?
    var markedPoint: NSPoint? { didSet { needsDisplay = true } }
    private let background: NSColor
    private let foreground: NSColor
    private let heading: PassiveLabel
    private let counts: PassiveLabel
    private let scrollStatus: PassiveLabel
    private let button = FirstClickButton(title: "Test underlying button", target: nil, action: nil)
    private var mouseDowns = 0
    private var buttonActions = 0
    private var scrollEvents = 0

    init(name: String, background: NSColor, foreground: NSColor) {
        self.name = name
        self.background = background
        self.foreground = foreground
        heading = label(name + " — click or scroll anywhere", size: 17, color: foreground)
        counts = label("Blank mouse-downs: 0  •  Button actions: 0", color: foreground)
        scrollStatus = label("Scroll events: 0  •  Last delta: none", color: foreground)
        super.init(frame: .zero)
        for view in [heading, counts, scrollStatus, button] { addSubview(view) }
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(buttonPressed)
        button.setAccessibilityLabel(name + " button")
        counts.setAccessibilityIdentifier(name + ".counts")
        scrollStatus.setAccessibilityIdentifier(name + ".scroll")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(name:background:foreground:).") }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 16, y: bounds.height - 36, width: bounds.width - 32, height: 28)
        counts.frame = NSRect(x: 16, y: 91, width: bounds.width - 32, height: 20)
        scrollStatus.frame = NSRect(x: 16, y: 53, width: bounds.width - 32, height: 36)
        button.frame = NSRect(x: 16, y: 15, width: bounds.width - 32, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        NSBezierPath(rect: bounds).fill()
        foreground.withAlphaComponent(0.09).setStroke()
        let grid = NSBezierPath()
        for x in stride(from: CGFloat(0), through: bounds.width, by: 48) {
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: 48) {
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.stroke()
        if let markedPoint {
            foreground.setStroke()
            let cross = NSBezierPath()
            cross.lineWidth = 2
            cross.move(to: NSPoint(x: markedPoint.x - 12, y: markedPoint.y))
            cross.line(to: NSPoint(x: markedPoint.x + 12, y: markedPoint.y))
            cross.move(to: NSPoint(x: markedPoint.x, y: markedPoint.y - 12))
            cross.line(to: NSPoint(x: markedPoint.x, y: markedPoint.y + 12))
            cross.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDowns += 1
        updateCounts()
        onMark?(self, convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        scrollEvents += 1
        let unit = event.hasPreciseScrollingDeltas ? "points" : "coarse units"
        scrollStatus.stringValue = String(format: "Scroll events: %d  •  Last delta: %.1f, %.1f %@\nMomentum phase: %lu", scrollEvents, event.scrollingDeltaX, event.scrollingDeltaY, unit, event.momentumPhase.rawValue)
    }

    @objc private func buttonPressed() {
        buttonActions += 1
        updateCounts()
    }

    func reset() {
        mouseDowns = 0
        buttonActions = 0
        scrollEvents = 0
        markedPoint = nil
        updateCounts()
        scrollStatus.stringValue = "Scroll events: 0  •  Last delta: none"
    }

    private func updateCounts() {
        counts.stringValue = "Blank mouse-downs: \(mouseDowns)  •  Button actions: \(buttonActions)"
    }
}
