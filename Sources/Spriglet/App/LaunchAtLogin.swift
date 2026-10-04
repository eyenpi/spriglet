import ServiceManagement

enum LaunchAtLoginRegistration: Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }

    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

struct LaunchAtLoginFailure: Equatable {
    enum Operation { case enable, disable }
    let operation: Operation
    let message: String
}

struct LaunchAtLoginState: Equatable {
    let registration: LaunchAtLoginRegistration
    let failure: LaunchAtLoginFailure?
}

/// This boundary permits deterministic tests without modifying the user's login items.
@MainActor protocol LaunchAtLoginService {
    var registration: LaunchAtLoginRegistration { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor struct MainAppLoginService: LaunchAtLoginService {
    var registration: LaunchAtLoginRegistration { LaunchAtLoginRegistration(SMAppService.mainApp.status) }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// macOS owns the registration. Launching and refreshing only read it; there is
/// no saved boolean, migration or automatic registration to override user consent.
@MainActor final class LaunchAtLoginController {
    var onStateChanged: ((LaunchAtLoginState) -> Void)?
    private let service: any LaunchAtLoginService
    private(set) var state: LaunchAtLoginState

    init(service: any LaunchAtLoginService = MainAppLoginService()) {
        self.service = service
        state = LaunchAtLoginState(registration: service.registration, failure: nil)
    }

    @discardableResult func refresh() -> LaunchAtLoginState {
        publish(LaunchAtLoginState(registration: service.registration, failure: state.failure))
        return state
    }

    @discardableResult func setEnabled(_ enabled: Bool) -> LaunchAtLoginState {
        let current = refresh().registration
        guard current != .unknown else { return state }
        var failure: LaunchAtLoginFailure?
        do {
            // Avoid already-registered/job-not-found errors and never retry a
            // registration awaiting the user's approval in System Settings.
            if enabled && !current.isRegistered { try service.register() }
            else if !enabled && current != .notRegistered { try service.unregister() }
        } catch {
            failure = LaunchAtLoginFailure(operation: enabled ? .enable : .disable,
                                          message: error.localizedDescription)
        }
        // Even a successful call is not proof of consent, or of a state change.
        publish(LaunchAtLoginState(registration: service.registration, failure: failure))
        return state
    }

    func openSystemSettings() { service.openSystemSettings() }
    private func publish(_ state: LaunchAtLoginState) {
        guard self.state != state else { return }
        self.state = state
        onStateChanged?(state)
    }
}
