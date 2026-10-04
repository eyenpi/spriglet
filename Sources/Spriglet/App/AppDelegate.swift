import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: CompanionRuntime
    init(runtime: CompanionRuntime = CompanionRuntime()) { self.runtime = runtime; super.init() }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Observe session inactivity before NSWorkspace's launch-time signal.
        runtime.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(root); root.submenu = appMenu
        let quit = NSMenuItem(title: AppText.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        let help = NSMenuItem(title: AppText.helpMenu, action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: AppText.helpMenu)
        let introduction = NSMenuItem(title: AppText.introductionMenu, action: #selector(showIntroduction(_:)), keyEquivalent: "")
        introduction.target = self; helpMenu.addItem(introduction); help.submenu = helpMenu; menu.addItem(help)
        NSApp.mainMenu = menu; NSApp.helpMenu = helpMenu
        runtime.showIntroductionIfNeeded()
    }
    @objc private func showIntroduction(_ sender: Any?) { runtime.showIntroduction() }
    func applicationWillTerminate(_ notification: Notification) { runtime.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.reopen()
        return true
    }
}
