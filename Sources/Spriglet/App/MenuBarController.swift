import AppKit
import CompanionCore

/// Owns the persistent Settings recovery entry and the full character/application menus.
/// Actions carry values; registration and character behavior stay with their owners.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    var pocketItems: (() -> [PocketEntry])?
    var onPocketSelect: ((UUID) -> Void)?
    let menu = NSMenu()
    private(set) var statusItem: NSStatusItem?
    private let state: () -> CompanionControlState
    private let loginState: () -> LaunchAtLoginState
    private let onAction: (AppControlAction) -> Void

    init(state: @escaping () -> CompanionControlState, loginState: @escaping () -> LaunchAtLoginState,
         onAction: @escaping (AppControlAction) -> Void) {
        self.state = state; self.loginState = loginState; self.onAction = onAction
        super.init()
        populateStatusMenu()
    }
    func start() {
        guard statusItem == nil else { return }
        populateStatusMenu()
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
        populateFullMenu(menu)
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
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Pocket" { populatePocket(menu); return }
        if menu === self.menu { populateStatusMenu() }
        else { populateFullMenu(menu) }
    }

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
    private func populateStatusMenu() {
        menu.delegate = self; menu.autoenablesItems = false; menu.removeAllItems()
        menu.addItem(makeItem(.settings, title: AppText.settingsMenu, keyEquivalent: ",", modifiers: .command))
        if pocketItems != nil {
            let item = NSMenuItem(title: "Pocket", action: nil, keyEquivalent: "")
            let pocket = NSMenu(title: "Pocket"); populatePocket(pocket); item.submenu = pocket; item.tag = -2
            menu.addItem(item)
        }
        menu.addItem(makeItem(.quit, title: AppText.quitApp, keyEquivalent: "q", modifiers: .command))
    }

    private func populatePocket(_ menu: NSMenu) {
        menu.delegate = self; menu.autoenablesItems = false; menu.removeAllItems()
        let entries = pocketItems?() ?? []
        if entries.isEmpty { let empty = NSMenuItem(title: "Pocket is empty", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty) }
        for entry in entries.reversed() {
            let item = NSMenuItem(title: entry.item.label, action: #selector(reopenPocket(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry.id.uuidString; menu.addItem(item)
        }
    }
    @objc private func reopenPocket(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        onPocketSelect?(id)
    }
    private func populateFullMenu(_ menu: NSMenu) {
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
            let modifiers: NSEvent.ModifierFlags = switch action {
            case .settings, .quit: .command
            case .bringHome, .togglePause, .toggleVisibility: [.command, .shift]
            default: []
            }
            let item = makeItem(action, title: title, keyEquivalent: key, modifiers: modifiers)
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

    private func makeItem(_ action: AppControlAction, title: String, keyEquivalent: String = "",
                          modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseAction(_:)), keyEquivalent: keyEquivalent)
        item.target = self; item.tag = action.rawValue
        item.keyEquivalentModifierMask = modifiers
        return item
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
