import AppKit

/// Owns app-level controls and feedback, independently of character behavior.
@MainActor final class AppMenuController: NSObject, NSMenuDelegate {
    private let launchAtLogin: LaunchAtLoginController

    init(launchAtLogin: LaunchAtLoginController) {
        self.launchAtLogin = launchAtLogin
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        update(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { update(menu) }

    private func statusText(_ registration: LaunchAtLoginRegistration) -> String {
        switch registration {
        case .notRegistered: AppText.loginNotRegistered
        case .enabled: AppText.loginEnabled
        case .requiresApproval: AppText.loginRequiresApproval
        case .notFound: AppText.loginNotFound
        case .unknown: AppText.loginUnknown
        }
    }

    private func failureTitle(_ failure: LaunchAtLoginFailure) -> String {
        failure.operation == .enable ? AppText.loginEnableFailed : AppText.loginDisableFailed
    }

    private func update(_ menu: NSMenu) {
        let state = launchAtLogin.refresh()
        menu.removeAllItems()
        menu.autoenablesItems = false
        let toggle = NSMenuItem(title: AppText.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        toggle.target = self
        toggle.state = state.registration == .enabled ? .on : state.registration == .requiresApproval ? .mixed : .off
        toggle.isEnabled = state.registration != .unknown
        menu.addItem(toggle)
        let status = NSMenuItem(title: statusText(state.registration), action: nil, keyEquivalent: "")
        status.isEnabled = false; status.indentationLevel = 1
        menu.addItem(status)
        if let failure = state.failure {
            let error = NSMenuItem(title: AppText.loginLastAttempt + " " + failureTitle(failure), action: nil, keyEquivalent: "")
            error.isEnabled = false; error.indentationLevel = 1; error.toolTip = failure.message
            menu.addItem(error)
        }
        let settings = NSMenuItem(title: AppText.openLoginItemsSettings, action: #selector(openLoginItemsSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppText.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func toggleLaunchAtLogin() {
        let current = launchAtLogin.refresh().registration
        let state = launchAtLogin.setEnabled(!current.isRegistered)
        guard state.failure != nil || state.registration == .requiresApproval else { return }
        let alert = NSAlert()
        if let failure = state.failure {
            alert.alertStyle = .warning
            alert.messageText = failureTitle(failure)
            alert.informativeText = failure.message + "\n\n" + statusText(state.registration)
        } else {
            alert.messageText = AppText.loginRequiresApproval
            alert.informativeText = AppText.loginApprovalHelp
        }
        alert.addButton(withTitle: AppText.dismissLoginFeedback)
        alert.addButton(withTitle: AppText.openLoginItemsSettings)
        if alert.runModal() == .alertSecondButtonReturn { launchAtLogin.openSystemSettings() }
    }

    @objc private func openLoginItemsSettings() { launchAtLogin.openSystemSettings() }
}
