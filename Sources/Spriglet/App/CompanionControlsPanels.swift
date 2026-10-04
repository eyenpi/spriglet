import AppKit

/// Mouse-operated utility panels preserve the user's keyboard focus.
@MainActor private final class ControlsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(title: String, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false; hidesOnDeactivate = false; level = .floating
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        center()
    }
}

@MainActor private final class ControlsCheckbox: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func performClick(_ sender: Any?) {
        // NSButton's simulated click activates an accessory app even when its
        // panel cannot become key. State comes back from the runtime callback.
        _ = dispatchAction()
    }
    override func accessibilityPerformPress() -> Bool { dispatchAction() }
    private func dispatchAction() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }
}

/// Presents shared controls and offline guidance; owns no companion state.
@MainActor final class CompanionControlsPanels: NSObject {
    private let onAction: (AppControlAction) -> Void
    private var settingsPanel: NSPanel?
    private var helpPanel: NSPanel?
    private var visibilityButton: NSButton?
    private var animationButton: NSButton?

    init(onAction: @escaping (AppControlAction) -> Void) { self.onAction = onAction; super.init() }
    func showSettings(state: CompanionControlState) {
        if settingsPanel == nil {
            let panel = ControlsPanel(title: AppText.settingsTitle, size: NSSize(width: 380, height: 160))
            let visibility = checkbox(AppText.showMallow, action: #selector(toggleVisibility))
            let animation = checkbox(AppText.animateMallow, action: #selector(togglePause))
            let explanation = label(AppText.settingsHelp)
            explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            explanation.textColor = .secondaryLabelColor
            install([visibility, animation, explanation], in: panel)
            settingsPanel = panel; visibilityButton = visibility; animationButton = animation
        }
        update(state)
        settingsPanel?.orderFrontRegardless()
    }
    func showHelp() {
        if helpPanel == nil {
            let panel = ControlsPanel(title: AppText.supportTitle, size: NSSize(width: 440, height: 340))
            let heading = label(AppText.companionName)
            heading.font = .boldSystemFont(ofSize: 20)
            install([heading, label(AppText.interactionHelp), label(AppText.menuControlsHelp),
                     label(AppText.recoveryHelp), label(AppText.localHelp)], in: panel)
            helpPanel = panel
        }
        helpPanel?.orderFrontRegardless()
    }
    func update(_ state: CompanionControlState) {
        visibilityButton?.state = state.isVisible ? .on : .off
        visibilityButton?.isEnabled = state.canShow
        animationButton?.state = state.isPaused ? .off : .on
    }
    func close() {
        settingsPanel?.close(); helpPanel?.close()
        settingsPanel = nil; helpPanel = nil; visibilityButton = nil; animationButton = nil
    }
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }
    private func checkbox(_ title: String, action: Selector) -> NSButton {
        let button = ControlsCheckbox(title: title, target: self, action: action)
        button.setButtonType(.switch)
        return button
    }
    private func install(_ views: [NSView], in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
    }
    @objc private func toggleVisibility() { onAction(.toggleVisibility) }
    @objc private func togglePause() { onAction(.togglePause) }
}
