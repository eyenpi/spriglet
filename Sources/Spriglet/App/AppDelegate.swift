import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: CompanionRuntime
    private var settings: SettingsWindowController?
    init(runtime: CompanionRuntime = CompanionRuntime()) { self.runtime = runtime; super.init() }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Observe session inactivity before NSWorkspace's launch-time signal.
        runtime.onShowSettings = { [weak self] in self?.showSettings() }
        runtime.onSettingsChanged = { [weak self] state in self?.settings?.update(state) }
        runtime.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(root); root.submenu = appMenu
        let settings = NSMenuItem(title: AppText.settingsMenu, action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings); appMenu.addItem(.separator())
        let quit = NSMenuItem(title: AppText.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit); NSApp.mainMenu = menu
    }
    func applicationWillTerminate(_ notification: Notification) {
        settings?.close(); settings?.onChange = nil; settings = nil
        runtime.onShowSettings = nil; runtime.onSettingsChanged = nil; runtime.stop()
    }
    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(state: runtime.settingsState)
            controller.onChange = { [weak self] preferences in self?.runtime.updatePreferences(preferences) }
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
