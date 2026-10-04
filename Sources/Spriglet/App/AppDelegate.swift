import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: CompanionRuntime
    private(set) var menuBar: MenuBarController?
    private var panels: CompanionControlsPanels?
    init(runtime: CompanionRuntime = CompanionRuntime()) { self.runtime = runtime; super.init() }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Observe session inactivity before NSWorkspace's launch-time signal.
        runtime.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController(state: { [runtime] in runtime.controlState },
                                        onAction: { [weak self] in self?.perform($0) })
        let panels = CompanionControlsPanels(onAction: { [weak self] in self?.perform($0) })
        self.menuBar = menuBar; self.panels = panels
        runtime.onControlStateChanged = { [weak menuBar, weak panels] state in
            menuBar?.update(state); panels?.update(state)
        }
        menuBar.start()
        let menu = NSMenu(), root = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(root); root.submenu = appMenu
        let quit = NSMenuItem(title: AppText.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit); NSApp.mainMenu = menu
    }
    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.stop(); panels?.close(); runtime.onControlStateChanged = nil
        menuBar = nil; panels = nil; runtime.stop()
    }
    func perform(_ action: AppControlAction) {
        switch action {
        case .toggleVisibility: runtime.setVisible(!runtime.controlState.isVisible)
        case .togglePause: runtime.setPaused(!runtime.controlState.isPaused)
        case .bringHome: runtime.bringHome()
        case .settings: panels?.showSettings(state: runtime.controlState)
        case .help: panels?.showHelp()
        case .quit: NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.reopen()
        return true
    }
}
