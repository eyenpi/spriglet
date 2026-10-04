import AppKit
import ServiceManagement

@MainActor final class FakeLoginService: LaunchAtLoginService {
    var registration: LaunchAtLoginRegistration = .notRegistered
    var registeredState: LaunchAtLoginRegistration = .enabled
    var unregisteredState: LaunchAtLoginRegistration = .notRegistered
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registrations = 0
    private(set) var unregistrations = 0
    private(set) var settingsOpens = 0

    func register() throws {
        registrations += 1; registration = registeredState
        if let registerError { throw registerError }
    }
    func unregister() throws {
        unregistrations += 1; registration = unregisteredState
        if let unregisterError { throw unregisterError }
    }
    func openSystemSettings() { settingsOpens += 1 }
}

extension LifecycleValidation {
    static func loginItem(in menu: NSMenu) -> NSMenuItem {
        menu.items.first { $0.tag == AppControlAction.toggleLaunchAtLogin.rawValue }!
    }
    static func loginMenus(_ controller: LaunchAtLoginController) -> MenuBarController {
        MenuBarController(state: { CompanionControlState(isVisible: true, isPaused: false, canShow: true) },
                          loginState: { controller.refresh() }, onAction: { action in
            switch action {
            case .toggleLaunchAtLogin: controller.setEnabled(!controller.refresh().registration.isRegistered)
            case .openLoginItemsSettings: controller.openSystemSettings()
            default: break
            }
        })
    }
    static func launchAtLogin() throws {
        // App, status and character menus share the same action owner. Replay
        // and Help remain reachable without invoking windows or registration.
        let menuService = FakeLoginService(), menuLogin = LaunchAtLoginController(service: menuService)
        var actions: [AppControlAction] = []
        let shared = MenuBarController(state: { CompanionControlState(isVisible: true, isPaused: false, canShow: true) },
                                       loginState: { menuLogin.refresh() }, onAction: { actions.append($0) })
        for menu in [shared.menu, shared.makeMenu(), shared.makeMenu()] {
            let items = menu.items.filter { $0.action != nil }
            try require(items.count == AppControlAction.allCases.count && Set(items.map(\.tag)).count == items.count,
                        "Shared menus duplicated or omitted a typed control")
            for action in [AppControlAction.settings, .introduction, .help] {
                guard let item = items.first(where: { $0.tag == action.rawValue }) else {
                    throw ValidationFailure(description: "Shared menu omitted Settings, introduction or Help")
                }
                menu.performActionForItem(at: menu.index(of: item))
                try require(actions.last == action, "Shared menu routed the wrong action")
            }
        }
        let help = shared.makeHelpMenu()
        try require(help.items.map(\.tag) == [AppControlAction.introduction.rawValue, AppControlAction.help.rawValue],
                    "Native Help menu lost replay or existing Help guidance")
        for index in help.items.indices { help.performActionForItem(at: index) }
        try require(actions.suffix(2) == [.introduction, .help] && menuService.registrations == 0,
                    "Help menu bypassed typed actions or changed login registration")

        let states: [(SMAppService.Status?, LaunchAtLoginRegistration, NSControl.StateValue, String)] = [
            (.notRegistered, .notRegistered, .off, AppText.loginNotRegistered),
            (.enabled, .enabled, .on, AppText.loginEnabled),
            (.requiresApproval, .requiresApproval, .mixed, AppText.loginRequiresApproval),
            (.notFound, .notFound, .off, AppText.loginNotFound),
            (nil, .unknown, .off, AppText.loginUnknown)
        ]
        for (native, expected, checkmark, title) in states {
            if let native {
                try require(LaunchAtLoginRegistration(native) == expected, "macOS registration state was mapped incorrectly")
            }
            let service = FakeLoginService()
            service.registration = expected
            for _ in 0..<4 {
                let controller = LaunchAtLoginController(service: service)
                let menus = loginMenus(controller)
                let menu = menus.makeMenu()
                menus.menuNeedsUpdate(menu)
                try require(controller.refresh().registration == expected, "Startup replaced actual macOS registration")
                try require(loginItem(in: menu).state == checkmark && menu.items.contains { $0.title == title },
                            "Menu did not distinguish enabled, off, approval or unavailable registration")
                try require(loginItem(in: menu).isEnabled == (expected != .unknown), "Unknown registration allowed an unsafe toggle")
                try require(menu.items.filter { $0.title == title }.allSatisfy { !$0.isEnabled }, "Registration status row was actionable")
            }
            try require(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpens == 0,
                        "Repeated launches/menu reads changed login registration or opened settings")
            if expected == .unknown {
                let controller = LaunchAtLoginController(service: service)
                controller.setEnabled(true); controller.setEnabled(false)
                try require(service.registrations == 0 && service.unregistrations == 0, "Unknown system state allowed registration changes")
            }
        }

        let missingService = FakeLoginService()
        missingService.registration = .notFound; missingService.registeredState = .notFound
        missingService.registerError = NSError(domain: "LoginValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "App not found"])
        let missingController = LaunchAtLoginController(service: missingService)
        try require(missingController.setEnabled(true).registration == .notFound && missingController.state.failure != nil,
                    "Unavailable service lost its system state or registration failure")
        missingService.registerError = nil; missingService.registeredState = .enabled
        try require(missingController.setEnabled(true) == LaunchAtLoginState(registration: .enabled, failure: nil),
                    "Unavailable service could not recover on an explicit retry")

        let service = FakeLoginService(), controller = LaunchAtLoginController(service: service)
        try require(controller.setEnabled(false).registration == .notRegistered && service.unregistrations == 0,
                    "Default off attempted to unregister")
        try require(controller.setEnabled(true).registration == .enabled, "Explicit opt-in did not read the resulting registration")
        controller.setEnabled(true)
        try require(service.registrations == 1, "Repeated opt-in registered twice")
        service.registration = .requiresApproval
        try require(controller.refresh().registration == .requiresApproval, "External consent revocation was not observed")
        controller.setEnabled(true)
        try require(service.registrations == 1, "Pending approval was silently re-registered")
        try require(controller.setEnabled(false).registration == .notRegistered && service.unregistrations == 1,
                    "Pending approval could not be cancelled")
        controller.setEnabled(false)
        try require(service.unregistrations == 1, "Repeated opt-out unregistered twice")

        service.registeredState = .requiresApproval
        try require(controller.setEnabled(true) == LaunchAtLoginState(registration: .requiresApproval, failure: nil),
                    "Successful registration incorrectly implied approval")
        controller.openSystemSettings()
        try require(service.settingsOpens == 1, "Approval settings action was not routed to macOS")

        service.unregisteredState = .requiresApproval
        try require(controller.setEnabled(false).registration == .requiresApproval, "Successful call optimistically changed registration")
        service.unregisteredState = .notRegistered
        controller.setEnabled(false)
        service.registeredState = .notRegistered
        service.registerError = NSError(domain: "LoginValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
        let failedEnable = controller.setEnabled(true)
        try require(failedEnable.registration == .notRegistered && failedEnable.failure?.operation == .enable
                    && failedEnable.failure?.message == "Registration denied", "Register failure lost actual state or cause")
        let menus = loginMenus(controller), menu = menus.makeMenu()
        try require(loginItem(in: menu).state == .off && menu.items.contains { $0.title == AppText.loginLastAttempt + " " + AppText.loginEnableFailed
                    && $0.toolTip == "Registration denied" }, "Registration failure was hidden by the menu")
        menus.menuNeedsUpdate(menu)
        try require(controller.state.failure == failedEnable.failure, "Opening the menu erased the last failure")

        // A throw can still coincide with a changed system state. Report both.
        service.registeredState = .requiresApproval
        let deniedApproval = controller.setEnabled(true)
        try require(deniedApproval.registration == .requiresApproval && deniedApproval.failure != nil,
                    "Register error suppressed macOS's approval state")
        service.registration = .enabled
        service.unregisteredState = .enabled
        service.unregisterError = NSError(domain: "LoginValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Removal denied"])
        let failedDisable = controller.setEnabled(false)
        try require(failedDisable.registration == .enabled && failedDisable.failure?.operation == .disable,
                    "Unregister failure optimistically turned login off")
        menus.menuNeedsUpdate(menu)
        try require(loginItem(in: menu).state == .on && menu.items.contains { $0.title == AppText.loginLastAttempt + " " + AppText.loginDisableFailed },
                    "Unregister failure lost the enabled checkmark")

        service.unregisterError = nil; service.unregisteredState = .notRegistered
        try require(controller.setEnabled(false).failure == nil, "Successful retry retained obsolete failure")
        service.registerError = nil; service.registeredState = .enabled
        menus.menuNeedsUpdate(menu)
        menu.performActionForItem(at: menu.index(of: loginItem(in: menu)))
        try require(controller.state.registration == .enabled, "Menu toggle did not enable registration")
        menus.menuNeedsUpdate(menu)
        menu.performActionForItem(at: menu.index(of: loginItem(in: menu)))
        try require(controller.state.registration == .notRegistered, "Menu toggle did not disable registration")
        menu.performActionForItem(at: menu.items.firstIndex { $0.tag == AppControlAction.openLoginItemsSettings.rawValue }!)
        try require(service.settingsOpens == 2, "Menu did not open Login Items settings")

        // Change macOS state after the menu was built; the action must re-read it.
        service.registration = .enabled
        menu.performActionForItem(at: menu.index(of: loginItem(in: menu)))
        try require(controller.state.registration == .notRegistered, "Stale menu toggled using cached registration")
        print("Launch at login passed: default off, read-only startup, external changes, idempotence, approval, failures and menu actions.")
    }
    static func loginSettings() throws {
        let service = FakeLoginService(), login = LaunchAtLoginController(service: service)
        let state = SettingsState(preferences: CompanionPreferences(), displays: [],
                                  controls: CompanionControlState(isVisible: true, isPaused: false, canShow: true))
        let settings = SettingsWindowController(state: state, loginState: login.refresh())
        defer { settings.close(); settings.onAction = nil; settings.onRefreshLoginState = nil; login.onStateChanged = nil }
        login.onStateChanged = { [weak settings] state in settings?.updateLoginState(state) }
        settings.onRefreshLoginState = { login.refresh() }
        var actions: [AppControlAction] = []
        settings.onAction = { actions.append($0) }
        guard let window = settings.window, let content = window.contentView else {
            throw ValidationFailure(description: "Settings has no window")
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(content)
        guard let checkbox = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == AppText.launchAtLogin }),
              let systemSettings = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == AppText.openLoginItemsSettings }) else {
            throw ValidationFailure(description: "Settings lacks accessible login controls")
        }
        try require(!window.isVisible && checkbox.state == .off && checkbox.accessibilityLabel() == AppText.launchAtLogin,
                    "Settings construction activated a window or lost default-off login state")
        try require(checkbox.accessibilityPerformPress() && actions == [.toggleLaunchAtLogin],
                    "Accessible Settings press did not use the shared typed login action")
        NSApp.sendAction(systemSettings.action!, to: systemSettings.target, from: systemSettings)
        try require(actions.last == .openLoginItemsSettings && service.settingsOpens == 0,
                    "Settings bypassed the app action owner or opened macOS settings during validation")
        service.registration = .requiresApproval
        settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        try require(checkbox.state == .mixed && checkbox.accessibilityHelp() == AppText.loginRequiresApproval,
                    "Returning to Settings did not expose current approval status accessibly")
        let labels = views.compactMap { $0 as? NSTextField }
        try require(labels.contains { $0.stringValue == AppText.loginRequiresApproval }, "Settings hid actual approval status")
        service.registration = .enabled; login.refresh()
        try require(checkbox.state == .on, "External approval did not update the open Settings controls")
        service.unregisteredState = .enabled
        service.unregisterError = NSError(domain: "LoginValidation", code: 4,
                                         userInfo: [NSLocalizedDescriptionKey: String(repeating: "Removal denied. ", count: 30)])
        login.setEnabled(false)
        try require(checkbox.state == .on && labels.contains { !$0.isHidden && $0.stringValue.contains("Removal denied.") },
                    "Settings failure hid its cause or optimistically disabled registration")
        content.layoutSubtreeIfNeeded()
        for control in views.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            try require(content.bounds.contains(control.convert(control.bounds, to: content)), "Settings login control is clipped")
        }
        service.registration = .unknown; login.refresh()
        try require(!checkbox.isEnabled && !checkbox.accessibilityPerformPress(), "Unknown state permitted an accessible registration change")
        try require(settings.window === window && !window.isVisible && service.settingsOpens == 0,
                    "Login refresh replaced/showed the Settings window or opened macOS settings")
        print("Window-free Settings login passed: shared actions, live external status, accessible approval/errors and bounded layout.")
    }
}
