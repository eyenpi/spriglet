import AppKit

/// Owns the persistent recovery entry and the menus shared by all app controls.
/// Actions carry values; registration and character behavior stay with their owners.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private(set) var statusItem: NSStatusItem?
    private let state: () -> CompanionControlState
    private let loginState: () -> LaunchAtLoginState
    private let onAction: (AppControlAction) -> Void

    init(state: @escaping () -> CompanionControlState, loginState: @escaping () -> LaunchAtLoginState,
         onAction: @escaping (AppControlAction) -> Void) {
        self.state = state; self.loginState = loginState; self.onAction = onAction
        super.init()
        populate(menu)
    }
    func start() {
        guard statusItem == nil else { return }
        populate(menu)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: AppText.appName) {
            image.isTemplate = true; item.button?.image = image
        } else { item.button?.title = AppText.appName }
        item.button?.setAccessibilityLabel(AppText.menuBarLabel)
        item.button?.toolTip = AppText.menuBarLabel
        item.menu = menu
        item.behavior = []
        statusItem = item
    }
    func stop() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }
    func makeHelpMenu() -> NSMenu {
        let menu = NSMenu(title: AppText.helpMenu)
        menu.autoenablesItems = false
        for (action, title) in [(AppControlAction.introduction, AppText.introductionMenu), (.help, AppText.supportTitle)] {
            let item = NSMenuItem(title: title, action: #selector(chooseAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = action.rawValue; menu.addItem(item)
        }
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    /// Update existing recovery controls without rebuilding a tracked menu.
    func update(_ state: CompanionControlState) {
        for item in menu.items where item.action != nil {
            guard let action = AppControlAction(rawValue: item.tag) else { continue }
            switch action {
            case .toggleVisibility:
                item.title = state.isVisible ? AppText.hideMallow : AppText.showMallow
                item.isEnabled = state.canShow
            case .togglePause: item.title = state.isPaused ? AppText.resumeMallow : AppText.pauseMallow
            default: break
            }
        }
    }
    private func populate(_ menu: NSMenu) {
        let controls = state(), login = loginState()
        menu.delegate = self; menu.autoenablesItems = false; menu.removeAllItems()
        for action in AppControlAction.allCases {
            if action == .toggleLaunchAtLogin || action == .settings || action == .quit { menu.addItem(.separator()) }
            let title = switch action {
            case .toggleVisibility: controls.isVisible ? AppText.hideMallow : AppText.showMallow
            case .togglePause: controls.isPaused ? AppText.resumeMallow : AppText.pauseMallow
            case .bringHome: AppText.bringHome
            case .toggleLaunchAtLogin: AppText.launchAtLogin
            case .openLoginItemsSettings: AppText.openLoginItemsSettings
            case .settings: AppText.settingsMenu
            case .introduction: AppText.introductionMenu
            case .help: AppText.supportTitle
            case .quit: AppText.quitApp
            }
            let key = switch action {
            case .settings: ","
            case .quit: "q"
            case .bringHome: "h"
            case .togglePause: "p"
            case .toggleVisibility: "m"
            default: ""
            }
            let item = NSMenuItem(title: title, action: #selector(chooseAction(_:)), keyEquivalent: key)
            if [.bringHome, .togglePause, .toggleVisibility].contains(action) { item.keyEquivalentModifierMask = [.command, .shift] }
            item.target = self; item.tag = action.rawValue
            if action == .toggleVisibility { item.isEnabled = controls.canShow }
            if action == .toggleLaunchAtLogin {
                item.state = login.checkmark; item.isEnabled = login.registration != .unknown
                item.toolTip = login.statusText
            }
            menu.addItem(item)
            if action == .toggleLaunchAtLogin {
                addStatus(login.statusText, to: menu)
                if let failure = login.failure, let title = login.failureTitle {
                    addStatus(AppText.loginLastAttempt + " " + title, to: menu, detail: failure.message)
                }
            }
        }
    }
    private func addStatus(_ title: String, to menu: NSMenu, detail: String? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = -1; item.isEnabled = false; item.indentationLevel = 1; item.toolTip = detail
        menu.addItem(item)
    }
    @objc private func chooseAction(_ sender: NSMenuItem) {
        guard let action = AppControlAction(rawValue: sender.tag) else { return }
        onAction(action)
    }
}
