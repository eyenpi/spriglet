import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: CompanionRuntime
    private let launchAtLogin: LaunchAtLoginController
    private var settings: SettingsWindowController?
    private(set) var menuBar: MenuBarController?
    private var help: CompanionHelpPanel?

    init(runtime: CompanionRuntime = CompanionRuntime(), launchAtLogin: LaunchAtLoginController = LaunchAtLoginController()) {
        self.runtime = runtime; self.launchAtLogin = launchAtLogin
        super.init()
        menuBar = MenuBarController(state: { [runtime] in runtime.controlState },
                                    loginState: { [launchAtLogin] in launchAtLogin.refresh() },
                                    onAction: { [weak self] in self?.perform($0) })
        runtime.makeContextMenu = { [weak self] in self?.menuBar?.makeMenu() ?? NSMenu() }
        launchAtLogin.onStateChanged = { [weak self] in self?.settings?.updateLoginState($0) }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Observe session inactivity before NSWorkspace's launch-time signal.
        runtime.onControlAction = { [weak self] in self?.perform($0) }
        runtime.onSettingsChanged = { [weak self] state in self?.settings?.update(state) }
        runtime.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        help = CompanionHelpPanel()
        help?.onShowIntroduction = { [weak self] in self?.perform(.introduction) }
        runtime.onControlStateChanged = { [weak self] state in
            self?.menuBar?.update(state); self?.settings?.updateControls(state)
        }
        menuBar?.start()
        let menu = NSMenu(), root = NSMenuItem(title: AppText.appName, action: nil, keyEquivalent: "")
        menu.addItem(root); root.submenu = menuBar?.makeMenu()
        let windowItem = NSMenuItem(title: AppText.windowMenu, action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: AppText.windowMenu)
        windowMenu.addItem(NSMenuItem(title: AppText.closeWindow, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        let helpItem = NSMenuItem(title: AppText.helpMenu, action: nil, keyEquivalent: "")
        let helpMenu = menuBar?.makeHelpMenu()
        helpItem.submenu = helpMenu; menu.addItem(helpItem)
        NSApp.mainMenu = menu; NSApp.helpMenu = helpMenu
        runtime.showIntroductionIfNeeded()
    }
    func applicationWillTerminate(_ notification: Notification) {
        settings?.close(); settings?.onChange = nil; settings?.onAction = nil; settings?.onRefreshLoginState = nil; settings = nil
        menuBar?.stop(); help?.close(); help?.onShowIntroduction = nil; menuBar = nil; help = nil
        runtime.onControlAction = nil; runtime.onSettingsChanged = nil
        runtime.onControlStateChanged = nil; runtime.makeContextMenu = nil; runtime.stop()
        launchAtLogin.onStateChanged = nil
    }
    func perform(_ action: AppControlAction) {
        switch action {
        case .toggleVisibility: runtime.setVisible(!runtime.controlState.isVisible)
        case .togglePause: runtime.setPaused(!runtime.controlState.isPaused)
        case .bringHome: runtime.bringHome()
        case .toggleLaunchAtLogin:
            let current = launchAtLogin.refresh().registration
            presentLoginFeedback(launchAtLogin.setEnabled(!current.isRegistered))
        case .openLoginItemsSettings: launchAtLogin.openSystemSettings()
        case .settings: showSettings()
        case .introduction: runtime.showIntroduction()
        case .help: help?.present()
        case .quit: NSApp.terminate(nil)
        }
    }
    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(state: runtime.settingsState, loginState: launchAtLogin.refresh())
            controller.onChange = { [weak self] preferences in self?.runtime.updatePreferences(preferences) }
            controller.onAction = { [weak self] action in self?.perform(action) }
            controller.onRefreshLoginState = { [weak self] in self?.launchAtLogin.refresh() }
            settings = controller
        }
        settings?.update(runtime.settingsState); settings?.updateLoginState(launchAtLogin.refresh()); settings?.present()
    }
    func applicationDidBecomeActive(_ notification: Notification) { launchAtLogin.refresh() }
    private func presentLoginFeedback(_ state: LaunchAtLoginState) {
        guard state.failure != nil || state.registration == .requiresApproval else { return }
        let alert = NSAlert()
        if let failure = state.failure {
            alert.alertStyle = .warning; alert.messageText = state.failureTitle ?? AppText.loginEnableFailed
            alert.informativeText = failure.message + "\n\n" + state.statusText
        } else {
            alert.messageText = AppText.loginRequiresApproval; alert.informativeText = AppText.loginApprovalHelp
        }
        alert.addButton(withTitle: AppText.dismissLoginFeedback)
        alert.addButton(withTitle: AppText.openLoginItemsSettings)
        if alert.runModal() == .alertSecondButtonReturn { launchAtLogin.openSystemSettings() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.reopen()
        return true
    }
}
