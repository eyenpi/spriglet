import AppKit

extension LifecycleValidation {
    @MainActor static func simpleMenuBar() throws {
        var stateReads = 0, loginReads = 0
        var state = CompanionControlState(isVisible: true, isPaused: false, canShow: true)
        let loginService = FakeLoginService()
        loginService.registration = .enabled
        let loginController = LaunchAtLoginController(service: loginService)
        var actions: [AppControlAction] = []
        let controller = MenuBarController(state: {
            stateReads += 1
            return state
        }, loginState: {
            loginReads += 1
            return loginController.refresh()
        }, onAction: { actions.append($0) })
        defer { controller.stop() }

        func checkLeaf(_ context: String) throws {
            let items = controller.menu.items
            try require(items.count == 2, "Leaf menu added an item during \(context)")
            try require(items.map(\.tag) == [AppControlAction.settings.rawValue, AppControlAction.quit.rawValue],
                        "Leaf menu actions or order changed during \(context)")
            try require(items.map(\.title) == [AppText.settingsMenu, AppText.quitApp],
                        "Leaf menu labels changed during \(context)")
            try require(items.allSatisfy { !$0.isHidden && $0.submenu == nil && $0.isEnabled },
                        "Leaf menu contains hidden, nested or disabled content during \(context)")
            try require(items.allSatisfy { $0.target === controller && $0.action.map(NSStringFromSelector) == "chooseAction:" },
                        "Leaf menu lost its controller action target during \(context)")
            try require(items[0].keyEquivalent == "," && items[0].keyEquivalentModifierMask == .command
                        && items[1].keyEquivalent == "q" && items[1].keyEquivalentModifierMask == .command,
                        "Leaf menu lost Command-comma Settings or Command-Q Quit during \(context)")
        }

        // The menu's action stays private to production code; compare the stable selector name.
        try require(controller.menu.items.count == 2, "Initial leaf menu was not minimal")
        try checkLeaf("initialization")
        let initialStateReads = stateReads, initialLoginReads = loginReads
        controller.update(CompanionControlState(isVisible: false, isPaused: true, canShow: false))
        controller.menuNeedsUpdate(controller.menu)
        try checkLeaf("first open")
        controller.menuNeedsUpdate(controller.menu)
        controller.update(CompanionControlState(isVisible: true, isPaused: false, canShow: true))
        try checkLeaf("repeated open and update")
        controller.start()
        try checkLeaf("start")
        let statusIdentity = controller.statusItem
        try require(statusIdentity?.menu === controller.menu, "Status item is not attached to its two-action leaf menu")
        controller.start()
        try checkLeaf("repeated start")
        try require(controller.statusItem === statusIdentity, "Repeated start replaced the status item")
        try require(stateReads == initialStateReads && loginReads == initialLoginReads,
                    "Leaf initialization, start, update or opening sampled character/login state")

        for isVisible in [false, true] {
            for isPaused in [false, true] {
                for canShow in [false, true] {
                    controller.update(CompanionControlState(isVisible: isVisible, isPaused: isPaused, canShow: canShow))
                    controller.menuNeedsUpdate(controller.menu)
                    try checkLeaf("visibility=\(isVisible), paused=\(isPaused), canShow=\(canShow)")
                }
            }
        }

        for registration in [LaunchAtLoginRegistration.notRegistered, .enabled, .requiresApproval, .notFound, .unknown] {
            loginService.registration = registration
            controller.menuNeedsUpdate(controller.menu)
            try checkLeaf("login state \(registration)")
        }
        try require(stateReads == initialStateReads && loginReads == initialLoginReads,
                    "Leaf opening sampled state after character/login state changes")
        try require(loginService.registrations == 0 && loginService.unregistrations == 0 && loginService.settingsOpens == 0,
                    "Leaf initialization or opening caused login registration side effects")
        try require(actions.isEmpty, "Leaf initialization or opening dispatched an action")
        controller.menu.performActionForItem(at: 0)
        controller.menu.performActionForItem(at: 1)
        try require(actions == [.settings, .quit], "Leaf Settings/Quit did not dispatch through the typed callback")

        let full = controller.makeMenu()
        let fullActions = full.items.filter { $0.action != nil }.compactMap { AppControlAction(rawValue: $0.tag) }
        try require(fullActions == AppControlAction.allCases,
                    "Full character/application menu lost a typed action")
        try require(full.items.contains { $0.title == AppText.bringHome }
                    && full.items.contains { $0.title == AppText.launchAtLogin }
                    && full.items.contains { $0.title == AppText.openLoginItemsSettings },
                    "Full menu lost Bring Home or Launch at Login controls")
        let fullLoginReads = loginReads, fullStateReads = stateReads
        state = CompanionControlState(isVisible: false, isPaused: true, canShow: true)
        loginService.registration = .requiresApproval
        controller.menuNeedsUpdate(full)
        try require(stateReads == fullStateReads + 1 && loginReads == fullLoginReads + 1,
                    "Full menu stopped refreshing character and login state")
        try require(full.items.contains { $0.title == AppText.showMallow }
                    && full.items.contains { $0.title == AppText.resumeMallow }
                    && full.items.contains { $0.title == AppText.loginRequiresApproval },
                    "Full menu did not refresh visibility, animation and login guidance")

        let help = controller.makeHelpMenu()
        try require(help.items.map(\.tag) == [AppControlAction.introduction.rawValue, AppControlAction.help.rawValue]
                    && help.items.map(\.title) == [AppText.introductionMenu, AppText.supportTitle],
                    "Native Help menu changed while simplifying the leaf")
        print("Simple leaf menu passed: only Settings and Quit, stable shortcuts/dispatch, no state or login reads, full menu and Help retained.")
    }
}
