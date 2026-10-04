import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: CompanionRuntime
    private var settings: SettingsWindowController?
    private(set) var menuBar: MenuBarController?
    private var help: CompanionHelpPanel?

    init(runtime: CompanionRuntime = CompanionRuntime()) { self.runtime = runtime; super.init() }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Observe session inactivity before NSWorkspace's launch-time signal.
        runtime.onShowSettings = { [weak self] in self?.showSettings() }
        runtime.onSettingsChanged = { [weak self] state in self?.settings?.update(state) }
        runtime.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController(state: { [runtime] in runtime.controlState },
                                        onAction: { [weak self] in self?.perform($0) })
        self.menuBar = menuBar; help = CompanionHelpPanel()
        help?.onShowIntroduction = { [weak self] in self?.runtime.showIntroduction() }
        runtime.onControlStateChanged = { [weak self] state in
            self?.menuBar?.update(state); self?.settings?.updateControls(state)
        }
        menuBar.start()
        let menu = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(root); root.submenu = appMenu
        let settings = NSMenuItem(title: AppText.settingsMenu, action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings); appMenu.addItem(.separator())
        let quit = NSMenuItem(title: AppText.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        let helpItem = NSMenuItem(title: AppText.helpMenu, action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: AppText.helpMenu)
        let introduction = NSMenuItem(title: AppText.introductionMenu, action: #selector(showIntroduction(_:)), keyEquivalent: "")
        introduction.target = self; helpMenu.addItem(introduction)
        let support = NSMenuItem(title: AppText.supportTitle, action: #selector(showHelp), keyEquivalent: "")
        support.target = self; helpMenu.addItem(support); helpItem.submenu = helpMenu; menu.addItem(helpItem)
        NSApp.mainMenu = menu; NSApp.helpMenu = helpMenu
        runtime.showIntroductionIfNeeded()
    }
    func applicationWillTerminate(_ notification: Notification) {
        settings?.close(); settings?.onChange = nil; settings?.onAction = nil; settings = nil
        menuBar?.stop(); help?.close(); help?.onShowIntroduction = nil; menuBar = nil; help = nil
        runtime.onShowSettings = nil; runtime.onSettingsChanged = nil
        runtime.onControlStateChanged = nil; runtime.stop()
    }
    func perform(_ action: AppControlAction) {
        switch action {
        case .toggleVisibility: runtime.setVisible(!runtime.controlState.isVisible)
        case .togglePause: runtime.setPaused(!runtime.controlState.isPaused)
        case .bringHome: runtime.bringHome()
        case .settings: showSettings()
        case .help: help?.present()
        case .quit: NSApp.terminate(nil)
        }
    }
    @objc private func showIntroduction(_ sender: Any?) { runtime.showIntroduction() }
    @objc private func showHelp() { help?.present() }
    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(state: runtime.settingsState)
            controller.onChange = { [weak self] preferences in self?.runtime.updatePreferences(preferences) }
            controller.onAction = { [weak self] action in self?.perform(action) }
            settings = controller
        }
        settings?.update(runtime.settingsState); settings?.present()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.reopen()
        return true
    }
}
