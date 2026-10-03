import AppKit

@main enum SprigletApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = CompanionRuntime()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(root); root.submenu = appMenu
        let quit = NSMenuItem(title: AppText.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit); NSApp.mainMenu = menu
        runtime.start()
    }
    func applicationWillTerminate(_ notification: Notification) { runtime.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.perform(.returnHome)
        // A deliberate reopen exposes the ordinary app menu for Command-Q.
        // Launch and companion touches never activate or steal keyboard focus.
        NSApp.activate()
        return true
    }
}
