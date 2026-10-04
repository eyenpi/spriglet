import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: CompanionRuntime
    private let menus: AppMenuController
    init(runtime: CompanionRuntime = CompanionRuntime(), launchAtLogin: LaunchAtLoginController = LaunchAtLoginController()) {
        self.runtime = runtime
        menus = AppMenuController(launchAtLogin: launchAtLogin)
        super.init()
        runtime.makeContextMenu = { [weak menus] in menus?.makeMenu() ?? NSMenu() }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Observe session inactivity before NSWorkspace's launch-time signal.
        runtime.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), root = NSMenuItem()
        menu.addItem(root); root.submenu = menus.makeMenu()
        NSApp.mainMenu = menu
    }
    func applicationWillTerminate(_ notification: Notification) { runtime.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.reopen()
        return true
    }
}
