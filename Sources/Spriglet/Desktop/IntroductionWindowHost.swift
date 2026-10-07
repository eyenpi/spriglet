import AppKit
import CompanionCore
import CompanionRendering

@MainActor private final class IntroductionBackgroundView: NSView {
    enum Kind { case window, card }
    static let windowColor = NSColor(name: NSColor.Name("SprigletIntroductionWindow")) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(calibratedRed: 0.13, green: 0.125, blue: 0.145, alpha: 1)
        } else {
            NSColor(calibratedRed: 0.955, green: 0.938, blue: 0.910, alpha: 1)
        }
    }
    static let cardColor = NSColor(name: NSColor.Name("SprigletIntroductionCard")) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(calibratedRed: 0.19, green: 0.18, blue: 0.20, alpha: 1)
        } else {
            NSColor(calibratedRed: 0.995, green: 0.985, blue: 0.965, alpha: 1)
        }
    }
    static let borderColor = NSColor(name: NSColor.Name("SprigletIntroductionBorder")) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(calibratedRed: 0.31, green: 0.29, blue: 0.33, alpha: 1)
        } else {
            NSColor(calibratedRed: 0.88, green: 0.85, blue: 0.81, alpha: 1)
        }
    }
    static let accentColor = NSColor(name: NSColor.Name("SprigletIntroductionAccent")) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(calibratedRed: 0.70, green: 0.59, blue: 0.87, alpha: 1)
        } else {
            NSColor(calibratedRed: 0.48, green: 0.35, blue: 0.69, alpha: 1)
        }
    }
    static let primaryColor = NSColor(name: NSColor.Name("SprigletIntroductionPrimary")) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(calibratedRed: 0.39, green: 0.29, blue: 0.50, alpha: 1)
        } else {
            NSColor(calibratedRed: 0.30, green: 0.20, blue: 0.37, alpha: 1)
        }
    }
    let kind: Kind
    init(kind: Kind) { self.kind = kind; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("Use init(kind:)") }
    override func updateLayer() {
        layer?.backgroundColor = (kind == .window ? Self.windowColor : Self.cardColor).cgColor
        layer?.borderColor = Self.borderColor.cgColor
        layer?.borderWidth = kind == .card ? 1 : 0
        layer?.cornerRadius = kind == .card ? 14 : 0
        layer?.masksToBounds = kind == .card
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
}

@MainActor private final class IntroductionStepMarker: NSView {
    let number: Int
    var isSelected = false { didSet { needsDisplay = true } }
    init(number: Int) { self.number = number; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Use init(number:)") }
    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 24
        let circle = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2,
                            width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: circle)
        if isSelected {
            IntroductionBackgroundView.accentColor.setFill(); path.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
        let numberText = String(number) as NSString
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let color = isSelected ? NSColor.white : NSColor.secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = numberText.size(withAttributes: attributes)
        numberText.draw(at: NSPoint(x: circle.midX - textSize.width / 2,
                                   y: circle.midY - textSize.height / 2), withAttributes: attributes)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor private final class IntroductionPrimaryButtonSurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; layer?.cornerRadius = 9
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func updateLayer() {
        layer?.backgroundColor = IntroductionBackgroundView.primaryColor.cgColor
        layer?.cornerRadius = 9
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
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
        layer?.borderColor = IntroductionBackgroundView.borderColor.cgColor
    }
}

/// Owns the introduction's native controls and window, never simulation or time.
@MainActor final class IntroductionWindowHost: NSObject, NSWindowDelegate {
    var onStepSelected: ((IntroductionStep) -> Void)?
    var onDismiss: (() -> Void)?
    private var panel: NSPanel?
    private var demoView: IntroductionDemoView?
    private var stepButtons: [NSButton] = []
    private var stepMarkers: [IntroductionStepMarker] = []
    private var eyebrowLabel: NSTextField?
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
        eyebrowLabel?.stringValue = eyebrow(for: step)
        headingLabel?.stringValue = title(for: step)
        instructionLabel?.stringValue = instruction(for: step)
        motionNote?.isHidden = demo.motionPolicy == .full
        backButton?.isEnabled = step != .hover
        setNextTitle(step == .returnHome ? AppText.introductionDone : AppText.introductionNext)
        demoView?.setAccessibilityHelp(instruction(for: step))
        panel?.title = "\(AppText.introductionTitle) — \(step.rawValue + 1) / \(IntroductionStep.allCases.count)"
    }
    func close() {
        panel?.delegate = nil; panel?.orderOut(nil); panel?.close()
        panel = nil; demoView = nil; stepButtons = []; stepMarkers = []; eyebrowLabel = nil
        headingLabel = nil; instructionLabel = nil
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
    private func eyebrow(for step: IntroductionStep) -> String {
        String(format: "%02d / %@", step.rawValue + 1, buttonTitle(for: step))
    }
    private func buttonTitle(for step: IntroductionStep) -> String {
        [AppText.introductionHoverTab, AppText.introductionInviteTab, AppText.introductionDragTab,
         AppText.introductionCatchTab, AppText.introductionHomeTab][step.rawValue]
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
    private func headlineFont() -> NSFont {
        let fallback = NSFont.systemFont(ofSize: 25, weight: .semibold)
        guard let descriptor = fallback.fontDescriptor.withDesign(.serif) else { return fallback }
        return NSFont(descriptor: descriptor, size: 25) ?? fallback
    }
    private func refreshSelectionAppearance(for selectedStep: IntroductionStep) {
        for (index, marker) in stepMarkers.enumerated() {
            marker.isSelected = index == selectedStep.rawValue
        }
        for button in stepButtons {
            let selection: NSControl.StateValue = button.tag == selectedStep.rawValue ? .on : .off
            if button.state != selection { button.state = selection }
        }
    }
    private func setNextTitle(_ title: String) {
        guard let nextButton else { return }
        nextButton.title = title
        nextButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: nextButton.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.white
        ])
    }
    private func buildWindow(demo: IntroductionDemo) {
        let content = IntroductionBackgroundView(kind: .window)
        content.frame = NSRect(x: 0, y: 0, width: 620, height: 570)
        let panel = NSPanel(contentRect: content.bounds, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self; panel.contentView = content

        let card = IntroductionBackgroundView(kind: .card)
        card.identifier = NSUserInterfaceItemIdentifier("introduction.card")
        card.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            card.heightAnchor.constraint(equalToConstant: 434)
        ])

        let demoView = IntroductionDemoView(snapshot: demo.snapshot, pointer: demo.pointer, pressed: demo.pressed)
        demoView.wantsLayer = true; demoView.layer?.borderWidth = 1
        demoView.layer?.borderColor = IntroductionBackgroundView.borderColor.cgColor
        demoView.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(demoView)
        let eyebrow = label("", size: 11, weight: .semibold)
        eyebrow.textColor = IntroductionBackgroundView.accentColor
        let heading = label("", size: 25, weight: .semibold); heading.font = headlineFont()
        let instruction = label("", size: 14); instruction.textColor = .secondaryLabelColor
        let motionNote = label(AppText.introductionReducedMotion, size: 11); motionNote.textColor = .secondaryLabelColor
        [eyebrow, heading, instruction, motionNote].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }
        NSLayoutConstraint.activate([
            demoView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            demoView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            demoView.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            demoView.heightAnchor.constraint(equalTo: demoView.widthAnchor, multiplier: 0.5),
            eyebrow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            eyebrow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            eyebrow.topAnchor.constraint(equalTo: demoView.bottomAnchor, constant: 12),
            eyebrow.heightAnchor.constraint(equalToConstant: 16),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),
            heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 4),
            heading.heightAnchor.constraint(equalToConstant: 32),
            instruction.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            instruction.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),
            instruction.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            instruction.heightAnchor.constraint(equalToConstant: 40),
            motionNote.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            motionNote.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),
            motionNote.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 4),
            motionNote.heightAnchor.constraint(equalToConstant: 18),
            motionNote.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])

        let tabTitles = [AppText.introductionHoverTab, AppText.introductionInviteTab, AppText.introductionDragTab,
                         AppText.introductionCatchTab, AppText.introductionHomeTab]
        let markers = NSStackView(); markers.orientation = .horizontal; markers.alignment = .top; markers.distribution = .fillEqually
        markers.identifier = NSUserInterfaceItemIdentifier("introduction.markers")
        markers.spacing = 0; markers.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(markers)
        for step in IntroductionStep.allCases {
            let group = NSView(); group.translatesAutoresizingMaskIntoConstraints = false
            let marker = IntroductionStepMarker(number: step.rawValue + 1)
            marker.identifier = NSUserInterfaceItemIdentifier("introduction.marker.\(step.rawValue)")
            marker.translatesAutoresizingMaskIntoConstraints = false; marker.setAccessibilityElement(false)
            let tab = button(tabTitles[step.rawValue], action: #selector(selectStep(_:)))
            tab.tag = step.rawValue; tab.setButtonType(.pushOnPushOff); tab.isBordered = false
            tab.setAccessibilityLabel("\(step.rawValue + 1) / \(IntroductionStep.allCases.count): \(tab.title)")
            tab.translatesAutoresizingMaskIntoConstraints = false; group.addSubview(marker); group.addSubview(tab)
            markers.addArrangedSubview(group)
            NSLayoutConstraint.activate([
                group.widthAnchor.constraint(equalTo: markers.widthAnchor, multiplier: 0.2),
                group.heightAnchor.constraint(equalToConstant: 52),
                marker.topAnchor.constraint(equalTo: group.topAnchor),
                marker.centerXAnchor.constraint(equalTo: group.centerXAnchor),
                marker.widthAnchor.constraint(equalToConstant: 24),
                marker.heightAnchor.constraint(equalToConstant: 24),
                tab.topAnchor.constraint(equalTo: marker.bottomAnchor, constant: 4),
                tab.centerXAnchor.constraint(equalTo: group.centerXAnchor),
                tab.heightAnchor.constraint(equalToConstant: 24),
                tab.widthAnchor.constraint(lessThanOrEqualTo: group.widthAnchor)
            ])
            stepMarkers.append(marker); stepButtons.append(tab)
        }

        NSLayoutConstraint.activate([
            markers.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            markers.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            markers.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 12),
            markers.heightAnchor.constraint(equalToConstant: 52)
        ])

        let skip = button(AppText.introductionSkip, action: #selector(dismiss(_:))); skip.keyEquivalent = "\u{1b}"
        let back = button(AppText.introductionBack, action: #selector(back(_:)))
        let next = button(AppText.introductionNext, action: #selector(next(_:)))
        next.setButtonType(.momentaryPushIn); next.isBordered = false; next.keyEquivalent = "\r"
        [skip, back, next].forEach { $0.heightAnchor.constraint(equalToConstant: 32).isActive = true }
        let controls = NSView(); controls.identifier = NSUserInterfaceItemIdentifier("introduction.controls")
        controls.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(controls)
        let nextSurface = IntroductionPrimaryButtonSurface(frame: .zero)
        nextSurface.identifier = NSUserInterfaceItemIdentifier("introduction.primary")
        nextSurface.translatesAutoresizingMaskIntoConstraints = false; controls.addSubview(nextSurface)
        skip.translatesAutoresizingMaskIntoConstraints = false; controls.addSubview(skip)
        back.translatesAutoresizingMaskIntoConstraints = false; controls.addSubview(back)
        next.translatesAutoresizingMaskIntoConstraints = false; nextSurface.addSubview(next)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            controls.topAnchor.constraint(equalTo: markers.bottomAnchor, constant: 8),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            skip.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            skip.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            nextSurface.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            nextSurface.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            nextSurface.heightAnchor.constraint(equalToConstant: 32),
            back.trailingAnchor.constraint(equalTo: nextSurface.leadingAnchor, constant: -10),
            back.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            next.leadingAnchor.constraint(equalTo: nextSurface.leadingAnchor, constant: 14),
            next.trailingAnchor.constraint(equalTo: nextSurface.trailingAnchor, constant: -14),
            next.centerYAnchor.constraint(equalTo: nextSurface.centerYAnchor)
        ])
        let keyViews: [NSView] = stepButtons + [skip, back, next]
        panel.autorecalculatesKeyViewLoop = false
        for (index, view) in keyViews.enumerated() { view.nextKeyView = keyViews[(index + 1) % keyViews.count] }
        panel.initialFirstResponder = stepButtons.first
        self.panel = panel; self.demoView = demoView; eyebrowLabel = eyebrow
        headingLabel = heading; instructionLabel = instruction
        self.motionNote = motionNote; backButton = back; nextButton = next
        setNextTitle(AppText.introductionNext)
        refreshSelectionAppearance(for: demo.step)
    }
}
