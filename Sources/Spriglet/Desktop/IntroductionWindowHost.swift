import AppKit
import CompanionCore
import CompanionRendering

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
}

/// Owns the introduction's native controls and window, never simulation or time.
@MainActor final class IntroductionWindowHost: NSObject, NSWindowDelegate {
    var onStepSelected: ((IntroductionStep) -> Void)?
    var onDismiss: (() -> Void)?
    private var panel: NSPanel?
    private var demoView: IntroductionDemoView?
    private var stepButtons: [NSButton] = []
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
        panel = nil; demoView = nil; stepButtons = []; headingLabel = nil; instructionLabel = nil
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
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; return button
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.alignment = .center
        return label
    }
    private func buildWindow(demo: IntroductionDemo) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 608, height: 628))
        let panel = NSPanel(contentRect: content.bounds, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self; panel.contentView = content
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22)
        ])
        let title = label(AppText.introductionTitle, size: 24, weight: .semibold)
        stack.addArrangedSubview(title); title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let tabs = NSStackView(); tabs.orientation = .horizontal; tabs.alignment = .centerY
        tabs.distribution = .fillEqually; tabs.spacing = 8
        let tabTitles = [AppText.introductionHoverTab, AppText.introductionInviteTab, AppText.introductionDragTab,
                         AppText.introductionCatchTab, AppText.introductionHomeTab]
        for step in IntroductionStep.allCases {
            let tab = button(tabTitles[step.rawValue], action: #selector(selectStep(_:)))
            tab.tag = step.rawValue; tab.setButtonType(.pushOnPushOff)
            tab.setAccessibilityLabel("\(step.rawValue + 1) / \(IntroductionStep.allCases.count): \(tab.title)")
            tabs.addArrangedSubview(tab); stepButtons.append(tab)
        }
        stack.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let demoView = IntroductionDemoView(snapshot: demo.snapshot, pointer: demo.pointer, pressed: demo.pressed)
        stack.addArrangedSubview(demoView)
        NSLayoutConstraint.activate([demoView.widthAnchor.constraint(equalToConstant: 560), demoView.heightAnchor.constraint(equalToConstant: 280)])
        let heading = label("", size: 20, weight: .semibold)
        let instruction = label("", size: 14)
        instruction.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading); stack.addArrangedSubview(instruction)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        instruction.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        instruction.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let controls = NSStackView(); controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 10
        let skip = button(AppText.introductionSkip, action: #selector(dismiss(_:))); skip.keyEquivalent = "\u{1b}"
        let back = button(AppText.introductionBack, action: #selector(back(_:)))
        let next = button(AppText.introductionNext, action: #selector(next(_:))); next.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        controls.addArrangedSubview(skip); controls.addArrangedSubview(spacer)
        controls.addArrangedSubview(back); controls.addArrangedSubview(next)
        stack.addArrangedSubview(controls); controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        controls.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let motionNote = label(AppText.introductionReducedMotion, size: 11)
        motionNote.textColor = .secondaryLabelColor; stack.addArrangedSubview(motionNote)
        motionNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        self.panel = panel; self.demoView = demoView; headingLabel = heading; instructionLabel = instruction
        self.motionNote = motionNote; backButton = back; nextButton = next
    }
}
