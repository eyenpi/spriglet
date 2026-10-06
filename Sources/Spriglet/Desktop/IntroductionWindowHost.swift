import AppKit
import CompanionCore
import CompanionRendering

@MainActor private final class IntroductionBackgroundView: NSView {
    enum Kind { case main, footer }
    let kind: Kind
    init(kind: Kind) { self.kind = kind; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("Use init(kind:)") }
    override func updateLayer() {
        layer?.backgroundColor = (kind == .main ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = kind == .footer ? NSColor.separatorColor.cgColor : nil
        layer?.borderWidth = kind == .footer ? 0.5 : 0
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
}

@MainActor private final class IntroductionStepRow: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.systemPurple.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
}

/// Drawing receives immutable demo values, just like the everyday character.
@MainActor final class IntroductionDemoView: NSView {
    private let renderer = ScenePreviewRenderer()
    private(set) var snapshot: CompanionSnapshot
    private var pointer: Point
    private var pressed: Bool
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    init(snapshot: CompanionSnapshot, pointer: Point, pressed: Bool) {
        self.snapshot = snapshot; self.pointer = pointer; self.pressed = pressed
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(AppText.introductionDemoLabel)
    }
    required init?(coder: NSCoder) { fatalError("Use init(snapshot:pointer:pressed:)") }
    func update(snapshot: CompanionSnapshot, pointer: Point, pressed: Bool) {
        self.snapshot = snapshot; self.pointer = pointer; self.pressed = pressed
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scaleX(by: bounds.width / snapshot.scene.bounds.width,
                         yBy: bounds.height / snapshot.scene.bounds.height)
        transform.concat()
        renderer.draw(snapshot, pointer: pointer, pressed: pressed)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// Owns the introduction's native controls and window, never simulation or time.
@MainActor final class IntroductionWindowHost: NSObject, NSWindowDelegate {
    var onStepSelected: ((IntroductionStep) -> Void)?
    var onDismiss: (() -> Void)?
    private var panel: NSPanel?
    private var demoView: IntroductionDemoView?
    private var stepButtons: [NSButton] = []
    private var stepRows: [NSView] = []
    private var headingLabel: NSTextField?
    private var instructionLabel: NSTextField?
    private var motionNote: NSTextField?
    private var backButton: NSButton?
    private var nextButton: NSButton?
    private var step = IntroductionStep.hover
    var isVisible: Bool { panel?.isVisible == true }

    func present(on screen: NSScreen, demo: IntroductionDemo) {
        if panel == nil { buildWindow(demo: demo) }
        update(demo)
        // First launch does not activate the app. Clicking a control in this
        // nonactivating panel can give it keyboard focus for navigation/Escape.
        if let panel, !panel.isVisible {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        }
        panel?.orderFrontRegardless()
    }
    func setVisible(_ visible: Bool) {
        if visible { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
    }
    func update(_ demo: IntroductionDemo) {
        // AppKit toggles a selected button before invoking its action. Restore
        // selection from the demo even when replaying the same step.
        for button in stepButtons {
            let selection: NSControl.StateValue = button.tag == demo.step.rawValue ? .on : .off
            if button.state != selection { button.state = selection }
        }
        refreshSelectionAppearance(for: demo.step)
        let presentationChanged = step != demo.step || motionNote?.isHidden != (demo.motionPolicy == .full)
        if demo.motionPolicy == .full || presentationChanged {
            demoView?.update(snapshot: demo.snapshot, pointer: demo.pointer, pressed: demo.pressed)
        }
        guard headingLabel?.stringValue != title(for: demo.step) || presentationChanged else { return }
        step = demo.step
        headingLabel?.stringValue = title(for: step)
        instructionLabel?.stringValue = instruction(for: step)
        motionNote?.isHidden = demo.motionPolicy == .full
        backButton?.isEnabled = step != .hover
        nextButton?.title = step == .returnHome ? AppText.introductionDone : AppText.introductionNext
        demoView?.setAccessibilityHelp(instruction(for: step))
        panel?.title = "\(AppText.introductionTitle) — \(step.rawValue + 1) / \(IntroductionStep.allCases.count)"
    }
    func close() {
        panel?.delegate = nil; panel?.orderOut(nil); panel?.close()
        panel = nil; demoView = nil; stepButtons = []; stepRows = []; headingLabel = nil; instructionLabel = nil
        motionNote = nil; backButton = nil; nextButton = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onDismiss?(); return false }
    @objc private func dismiss(_ sender: Any?) { onDismiss?() }
    @objc private func selectStep(_ sender: NSButton) {
        guard let step = IntroductionStep(rawValue: sender.tag) else { return }
        onStepSelected?(step)
    }
    @objc private func back(_ sender: Any?) {
        if let previous = IntroductionStep(rawValue: step.rawValue - 1) { onStepSelected?(previous) }
    }
    @objc private func next(_ sender: Any?) {
        if let next = IntroductionStep(rawValue: step.rawValue + 1) { onStepSelected?(next) }
        else { onDismiss?() }
    }
    private func title(for step: IntroductionStep) -> String {
        switch step {
        case .hover: AppText.introductionHoverTitle
        case .invite: AppText.introductionInviteTitle
        case .drag: AppText.introductionDragTitle
        case .catchHome: AppText.introductionCatchTitle
        case .returnHome: AppText.introductionHomeTitle
        }
    }
    private func instruction(for step: IntroductionStep) -> String {
        switch step {
        case .hover: AppText.introductionHoverBody
        case .invite: AppText.introductionInviteBody
        case .drag: AppText.introductionDragBody
        case .catchHome: AppText.introductionCatchBody
        case .returnHome: AppText.introductionHomeBody
        }
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = KeyboardButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; return button
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.alignment = alignment
        return label
    }
    private func refreshSelectionAppearance(for selectedStep: IntroductionStep) {
        for (index, row) in stepRows.enumerated() {
            (row as? IntroductionStepRow)?.isSelected = index == selectedStep.rawValue
        }
    }
    private func buildWindow(demo: IntroductionDemo) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
        let panel = NSPanel(contentRect: content.bounds, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self; panel.contentView = content

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(sidebar)
        let main = IntroductionBackgroundView(kind: .main)
        main.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(main)
        let footer = IntroductionBackgroundView(kind: .footer)
        footer.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(footer)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 176),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            main.topAnchor.constraint(equalTo: content.topAnchor),
            main.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 68)
        ])

        let railTitle = label(AppText.introductionTitle, size: 20, weight: .semibold)
        railTitle.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(railTitle)
        let rail = NSStackView(); rail.orientation = .vertical; rail.alignment = .leading; rail.spacing = 8
        rail.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(rail)
        NSLayoutConstraint.activate([
            railTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            railTitle.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),
            railTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            rail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            rail.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            rail.topAnchor.constraint(equalTo: railTitle.bottomAnchor, constant: 24)
        ])
        let tabTitles = [AppText.introductionHoverTab, AppText.introductionInviteTab, AppText.introductionDragTab,
                         AppText.introductionCatchTab, AppText.introductionHomeTab]
        for step in IntroductionStep.allCases {
            let row = IntroductionStepRow()
            row.translatesAutoresizingMaskIntoConstraints = false
            let number = NSTextField(labelWithString: String(format: "%02d", step.rawValue + 1))
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            number.textColor = .secondaryLabelColor; number.alignment = .center
            number.setAccessibilityElement(false)
            number.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(number)
            let tab = button(tabTitles[step.rawValue], action: #selector(selectStep(_:)))
            tab.tag = step.rawValue; tab.setButtonType(.pushOnPushOff); tab.isBordered = false
            tab.setAccessibilityLabel("\(step.rawValue + 1) / \(IntroductionStep.allCases.count): \(tab.title)")
            tab.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(tab)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 48),
                number.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 7),
                number.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                number.widthAnchor.constraint(equalToConstant: 30),
                tab.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 4),
                tab.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                tab.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                tab.heightAnchor.constraint(equalToConstant: 36)
            ])
            rail.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
            stepRows.append(row); stepButtons.append(tab)
        }

        let heading = label("", size: 20, weight: .semibold)
        let instruction = label("", size: 14)
        instruction.textColor = .secondaryLabelColor
        let demoView = IntroductionDemoView(snapshot: demo.snapshot, pointer: demo.pointer, pressed: demo.pressed)
        demoView.wantsLayer = true; demoView.layer?.cornerRadius = 11; demoView.layer?.masksToBounds = true
        demoView.layer?.borderWidth = 1; demoView.layer?.borderColor = NSColor.separatorColor.cgColor
        let motionNote = label(AppText.introductionReducedMotion, size: 11)
        motionNote.textColor = .secondaryLabelColor
        [heading, instruction, demoView, motionNote].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; main.addSubview($0) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            heading.topAnchor.constraint(equalTo: main.topAnchor, constant: 24),
            heading.heightAnchor.constraint(equalToConstant: 24),
            instruction.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            instruction.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            instruction.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            instruction.heightAnchor.constraint(equalToConstant: 56),
            demoView.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            demoView.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            demoView.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 16),
            demoView.heightAnchor.constraint(equalTo: demoView.widthAnchor, multiplier: 0.5),
            motionNote.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            motionNote.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            motionNote.topAnchor.constraint(equalTo: demoView.bottomAnchor, constant: 12),
            motionNote.heightAnchor.constraint(equalToConstant: 30)
        ])

        let controls = NSStackView(); controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(controls)
        let skip = button(AppText.introductionSkip, action: #selector(dismiss(_:))); skip.keyEquivalent = "\u{1b}"
        let back = button(AppText.introductionBack, action: #selector(back(_:)))
        let next = button(AppText.introductionNext, action: #selector(next(_:))); next.keyEquivalent = "\r"
        [skip, back, next].forEach { $0.heightAnchor.constraint(equalToConstant: 32).isActive = true }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        controls.addArrangedSubview(skip); controls.addArrangedSubview(spacer)
        controls.addArrangedSubview(back); controls.addArrangedSubview(next)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            controls.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            controls.heightAnchor.constraint(equalToConstant: 32)
        ])
        let keyViews: [NSView] = stepButtons + [skip, back, next]
        panel.autorecalculatesKeyViewLoop = false
        for (index, view) in keyViews.enumerated() { view.nextKeyView = keyViews[(index + 1) % keyViews.count] }
        panel.initialFirstResponder = stepButtons.first
        self.panel = panel; self.demoView = demoView; headingLabel = heading; instructionLabel = instruction
        self.motionNote = motionNote; backButton = back; nextButton = next
        refreshSelectionAppearance(for: demo.step)
    }
}
