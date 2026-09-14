import Foundation
import Observation
import ServiceManagement

enum LoginItemStatus: String, Sendable {
    case notRegistered, enabled, requiresApproval, notFound

    /// Registration can be on while macOS still requires explicit user approval.
    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemAdapter: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

/// Reads macOS's authoritative state. Construction and refresh never register.
@MainActor @Observable
final class LoginItemService {
    private let adapter: any LoginItemAdapter
    let allowsChanges: Bool
    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var lastError: String?

    init(adapter: any LoginItemAdapter = SystemLoginItemAdapter(), allowsChanges: Bool = LoginItemService.defaultAllowsChanges) {
        self.adapter = adapter
        self.allowsChanges = allowsChanges
        refresh()
    }

    static var defaultAllowsChanges: Bool {
        permitsChanges(arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func permitsChanges(arguments: [String], bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == "dev.spriglet.app" else { return false }
        let diagnosticFlags: Set<String> = [
            "--probe", "--soak", "--sample-review", "--welcome-review",
            "--desktop-acceptance", "--everyday-services-validation", "--everyday-review",
            "--settings-review", "--diagnostics"
        ]
        return !arguments.contains { diagnosticFlags.contains($0) }
    }

    func refresh() { status = adapter.status }

    /// Call only for the user's explicit settings change, never during launch.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        refresh()
        guard allowsChanges else {
            lastError = "Launch at login cannot be changed from this review or validation copy."
            return false
        }
        lastError = nil
        if enabled == status.isRegistered { return true }
        do {
            if enabled { try adapter.register() } else { try adapter.unregister() }
            refresh()
            guard enabled == status.isRegistered else {
                lastError = "macOS hasn’t confirmed the login item change. Check Login Items in System Settings."
                return false
            }
            return true
        } catch {
            refresh()
            lastError = "macOS couldn’t change launch at login. \(error.localizedDescription)"
            return false
        }
    }

    /// Opening settings is also an explicit UI action; it is never automatic.
    func openSettings() {
        guard allowsChanges else { return }
        adapter.openSettings()
    }
}

@MainActor
final class SystemLoginItemAdapter: LoginItemAdapter {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
