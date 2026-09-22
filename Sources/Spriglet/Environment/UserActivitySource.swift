import CoreGraphics
import Foundation
import SprigletCore

/// `kCGAnyInputEventType` is a C macro (`~0`) that CoreGraphics does not import
/// into Swift. The installed SDK preserves that documented sentinel through the
/// failable raw-value initializer for aggregate keyboard, mouse, and tablet
/// inactivity.
private let anyInputEventType = CGEventType(rawValue: UInt32.max)!

/// Explicit, demand-driven access to true combined-session input inactivity.
/// It installs no event tap, monitor, timer, or keyboard subscription.
@MainActor
protocol UserActivityObserving: AnyObject {
    func start()
    func stop()
    func refresh(isSleeping: Bool) -> UserActivityEvaluation?
}

/// Reads only the aggregate time since any user input when a shared deadline or
/// meaningful context event asks for it. The value is never retained here.
@MainActor
final class UserActivitySource: UserActivityObserving {
    private let policy: UserActivityPolicy
    private let readIdleDuration: @MainActor () -> TimeInterval
    private var isRunning = false

    init(
        policy: UserActivityPolicy = .standard,
        readIdleDuration: @escaping @MainActor () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: anyInputEventType
            )
        }
    ) {
        self.policy = policy
        self.readIdleDuration = readIdleDuration
    }

    isolated deinit { stop() }

    func start() { isRunning = true }

    func stop() {
        isRunning = false
    }

    func refresh(isSleeping: Bool = false) -> UserActivityEvaluation? {
        guard isRunning else { return nil }
        return policy.evaluate(idleDuration: readIdleDuration(), isSleeping: isSleeping)
    }
}
