import AppKit

/// The help panel preserves the user's keyboard focus.
@MainActor private final class HelpPanel: NSPanel {
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

/// Presents offline guidance without retaining companion state or taking focus.
@MainActor final class CompanionHelpPanel {
    private var panel: NSPanel?

    func present() {
        if panel == nil {
            let help = HelpPanel(title: AppText.supportTitle, size: NSSize(width: 440, height: 340))
            let heading = label(AppText.companionName)
            heading.font = .boldSystemFont(ofSize: 20)
            install([heading, label(AppText.interactionHelp), label(AppText.menuControlsHelp),
                     label(AppText.recoveryHelp), label(AppText.localHelp)], in: help)
            panel = help
        }
        panel?.orderFrontRegardless()
    }
    func close() { panel?.close(); panel = nil }
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
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
}
