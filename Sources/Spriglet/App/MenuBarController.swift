import AppKit

enum AppControlAction: Int, CaseIterable {
    case toggleVisibility, togglePause, bringHome, settings, help, quit
}

/// Owns the persistent recovery entry point; commands carry no window or engine.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private(set) var statusItem: NSStatusItem?
    private let state: () -> CompanionControlState
    private let onAction: (AppControlAction) -> Void

    init(state: @escaping () -> CompanionControlState, onAction: @escaping (AppControlAction) -> Void) {
        self.state = state; self.onAction = onAction
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for action in AppControlAction.allCases {
            if action == .settings || action == .quit { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "", action: #selector(chooseAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = action.rawValue
            menu.addItem(item)
        }
        update(state())
    }
    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: AppText.appName) {
            image.isTemplate = true; item.button?.image = image
        } else { item.button?.title = AppText.appName }
        item.button?.setAccessibilityLabel(AppText.menuBarLabel)
        item.button?.toolTip = AppText.menuBarLabel
        item.menu = menu
        // No removalAllowed behavior: hiding Mallow cannot remove its recovery control.
        item.behavior = []
        statusItem = item
    }
    func stop() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    func menuWillOpen(_ menu: NSMenu) { update(state()) }
    func update(_ state: CompanionControlState) {
        for item in menu.items where !item.isSeparatorItem {
            guard let action = AppControlAction(rawValue: item.tag) else { continue }
            item.title = switch action {
            case .toggleVisibility: state.isVisible ? AppText.hideMallow : AppText.showMallow
            case .togglePause: state.isPaused ? AppText.resumeMallow : AppText.pauseMallow
            case .bringHome: AppText.bringHome
            case .settings: AppText.settings
            case .help: AppText.supportTitle
            case .quit: AppText.quitApp
            }
            item.isEnabled = action != .toggleVisibility || state.canShow
        }
    }
    @objc private func chooseAction(_ sender: NSMenuItem) {
        guard let action = AppControlAction(rawValue: sender.tag) else { return }
        onAction(action)
    }
}
