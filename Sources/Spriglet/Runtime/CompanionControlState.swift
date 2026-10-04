/// Read-only presentation state. System suspension affects visibility without
/// changing the user's pause choice, which survives recovery.
struct CompanionControlState: Equatable {
    let isVisible: Bool
    let isPaused: Bool
    let canShow: Bool
}
