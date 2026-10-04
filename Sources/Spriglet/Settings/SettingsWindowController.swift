import AppKit

@MainActor private final class SettingsCheckbox: NSButton {
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        // Use the same action boundary as mouse/keyboard input. The runtime
        // publishes the resulting state back to the controls.
        return sendAction(action, to: target)
    }
}

/// Owns one ordinary native window and emits complete value changes. It never
/// reads storage, samples displays or retains the simulation/runtime.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onChange: ((CompanionPreferences) -> Void)?
    var onAction: ((AppControlAction) -> Void)?
    var onRefreshLoginState: (() -> Void)?
    private var preferences = CompanionPreferences()
    private var displayIDs: [String?] = []
    private let size = NSPopUpButton()
    private let movement = NSPopUpButton()
    private let display = NSPopUpButton()
    private let location = NSPopUpButton()
    private let visibility = SettingsCheckbox(checkboxWithTitle: AppText.showMallow, target: nil, action: nil)
    private let animation = SettingsCheckbox(checkboxWithTitle: AppText.animateMallow, target: nil, action: nil)
    private let login = SettingsCheckbox(checkboxWithTitle: AppText.launchAtLogin, target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginFailure = NSTextField(wrappingLabelWithString: "")

    init(state: SettingsState, loginState: LaunchAtLoginState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppText.settingsTitle; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        size.addItems(withTitles: [AppText.sizeSmall, AppText.sizeMedium, AppText.sizeLarge])
        movement.addItems(withTitles: [AppText.movementGentle, AppText.movementStandard, AppText.movementLively])
        location.addItems(withTitles: [AppText.homeAutomatic, AppText.homeLeft, AppText.homeCenter, AppText.homeRight])
        let controls = [size, movement, display, location]
        let labels = [AppText.characterSize, AppText.movementIntensity, AppText.homeDisplay, AppText.homeLocation]
        for (control, label) in zip(controls, labels) {
            control.target = self; control.setAccessibilityLabel(label)
            control.widthAnchor.constraint(equalToConstant: 230).isActive = true
        }
        size.action = #selector(sizeChanged); movement.action = #selector(movementChanged)
        display.action = #selector(displayChanged); location.action = #selector(locationChanged)
        let grid = NSGridView(views: zip(labels, controls).map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 14; grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center
        let note = NSTextField(wrappingLabelWithString: AppText.settingsNote)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor
        visibility.target = self; visibility.action = #selector(toggleVisibility)
        animation.target = self; animation.action = #selector(togglePause)
        let sessionControls = NSStackView(views: [visibility, animation])
        sessionControls.orientation = .horizontal; sessionControls.spacing = 24
        login.target = self; login.action = #selector(toggleLaunchAtLogin); login.allowsMixedState = true
        login.setAccessibilityLabel(AppText.launchAtLogin)
        let loginSettings = NSButton(title: AppText.openLoginItemsSettings, target: self, action: #selector(openLoginItemsSettings))
        loginSettings.bezelStyle = .rounded
        loginStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize); loginStatus.textColor = .secondaryLabelColor
        loginFailure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loginFailure.maximumNumberOfLines = 3; loginFailure.lineBreakMode = .byTruncatingTail
        let loginControls = NSStackView(views: [login, loginStatus, loginFailure, loginSettings])
        loginControls.orientation = .vertical; loginControls.alignment = .leading; loginControls.spacing = 8
        let stack = NSStackView(views: [grid, sessionControls, loginControls, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginFailure.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.center(); update(state); updateLoginState(loginState)
    }
    required init?(coder: NSCoder) { fatalError("Use init(state:loginState:)") }

    func present() {
        // Only an explicit Settings action activates the accessory app.
        NSApp.activate(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func update(_ state: SettingsState) {
        preferences = state.preferences
        size.selectItem(at: CharacterSize.allCases.firstIndex(of: preferences.characterSize) ?? 1)
        movement.selectItem(at: MovementIntensity.allCases.firstIndex(of: preferences.movementIntensity) ?? 1)
        location.selectItem(at: HomeLocation.allCases.firstIndex(of: preferences.homeLocation) ?? 0)
        display.removeAllItems(); displayIDs = [nil]
        display.addItem(withTitle: AppText.primaryDisplay)
        for (index, choice) in state.displays.enumerated() {
            // A numbered label distinguishes identical display model names.
            display.addItem(withTitle: "\(index + 1). \(choice.name)"); displayIDs.append(choice.id)
        }
        if let savedID = preferences.homeDisplayID, !displayIDs.contains(savedID) {
            display.addItem(withTitle: AppText.disconnectedDisplay); displayIDs.append(savedID)
            display.lastItem?.isEnabled = false
        }
        display.selectItem(at: displayIDs.firstIndex(of: preferences.homeDisplayID) ?? 0)
        updateControls(state.controls)
    }
    func updateControls(_ state: CompanionControlState) {
        visibility.state = state.isVisible ? .on : .off
        visibility.isEnabled = state.canShow
        animation.state = state.isPaused ? .off : .on
    }
    func updateLoginState(_ state: LaunchAtLoginState) {
        login.state = state.checkmark; login.isEnabled = state.registration != .unknown
        login.setAccessibilityHelp(state.statusText)
        loginStatus.stringValue = state.statusText
        loginFailure.isHidden = state.failure == nil
        if let failure = state.failure, let title = state.failureTitle {
            loginFailure.stringValue = AppText.loginLastAttempt + " " + title + "\n" + failure.message
            loginFailure.toolTip = failure.message
        } else { loginFailure.stringValue = "" }
    }
    func windowDidBecomeKey(_ notification: Notification) { onRefreshLoginState?() }
    @objc private func toggleLaunchAtLogin() { onAction?(.toggleLaunchAtLogin) }
    @objc private func openLoginItemsSettings() { onAction?(.openLoginItemsSettings) }
    @objc private func toggleVisibility() { onAction?(.toggleVisibility) }
    @objc private func togglePause() { onAction?(.togglePause) }
    @objc private func sizeChanged() {
        preferences.characterSize = CharacterSize.allCases[size.indexOfSelectedItem]; onChange?(preferences)
    }
    @objc private func movementChanged() {
        preferences.movementIntensity = MovementIntensity.allCases[movement.indexOfSelectedItem]; onChange?(preferences)
    }
    @objc private func displayChanged() {
        guard displayIDs.indices.contains(display.indexOfSelectedItem) else { return }
        preferences.homeDisplayID = displayIDs[display.indexOfSelectedItem]; onChange?(preferences)
    }
    @objc private func locationChanged() {
        preferences.homeLocation = HomeLocation.allCases[location.indexOfSelectedItem]; onChange?(preferences)
    }
}
