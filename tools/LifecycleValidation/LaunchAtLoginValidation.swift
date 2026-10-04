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
    static func launchAtLogin() throws {
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
                let menus = AppMenuController(launchAtLogin: controller)
                let menu = menus.makeMenu()
                menus.menuNeedsUpdate(menu)
                try require(controller.refresh().registration == expected, "Startup replaced actual macOS registration")
                try require(menu.items[0].state == checkmark && menu.items[1].title == title,
                            "Menu did not distinguish enabled, off, approval or unavailable registration")
                try require(menu.items[0].isEnabled == (expected != .unknown), "Unknown registration allowed an unsafe toggle")
                try require(!menu.items[1].isEnabled, "Registration status row was actionable")
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
        let menus = AppMenuController(launchAtLogin: controller), menu = menus.makeMenu()
        try require(menu.items[0].state == .off && menu.items[2].title == AppText.loginLastAttempt + " " + AppText.loginEnableFailed
                    && menu.items[2].toolTip == "Registration denied", "Registration failure was hidden by the menu")
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
        try require(menu.items[0].state == .on && menu.items[2].title == AppText.loginLastAttempt + " " + AppText.loginDisableFailed,
                    "Unregister failure lost the enabled checkmark")

        service.unregisterError = nil; service.unregisteredState = .notRegistered
        try require(controller.setEnabled(false).failure == nil, "Successful retry retained obsolete failure")
        service.registerError = nil; service.registeredState = .enabled
        menus.menuNeedsUpdate(menu)
        menu.performActionForItem(at: 0)
        try require(controller.state.registration == .enabled, "Menu toggle did not enable registration")
        menus.menuNeedsUpdate(menu)
        menu.performActionForItem(at: 0)
        try require(controller.state.registration == .notRegistered, "Menu toggle did not disable registration")
        menu.performActionForItem(at: 2)
        try require(service.settingsOpens == 2, "Menu did not open Login Items settings")

        // Change macOS state after the menu was built; the action must re-read it.
        service.registration = .enabled
        menu.performActionForItem(at: 0)
        try require(controller.state.registration == .notRegistered, "Stale menu toggled using cached registration")
        print("Launch at login passed: default off, read-only startup, external changes, idempotence, approval, failures and menu actions.")
    }
}
