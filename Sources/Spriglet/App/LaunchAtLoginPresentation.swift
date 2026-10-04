import AppKit

/// Shared native presentation of the system-owned state, without cached consent.
extension LaunchAtLoginState {
    var checkmark: NSControl.StateValue {
        switch registration {
        case .enabled: .on
        case .requiresApproval: .mixed
        default: .off
        }
    }
    var statusText: String {
        switch registration {
        case .notRegistered: AppText.loginNotRegistered
        case .enabled: AppText.loginEnabled
        case .requiresApproval: AppText.loginRequiresApproval
        case .notFound: AppText.loginNotFound
        case .unknown: AppText.loginUnknown
        }
    }
    var failureTitle: String? {
        guard let failure else { return nil }
        return failure.operation == .enable ? AppText.loginEnableFailed : AppText.loginDisableFailed
    }
}
