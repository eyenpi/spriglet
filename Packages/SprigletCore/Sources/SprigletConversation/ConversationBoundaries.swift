import Foundation
import SprigletCore

/// The language-model seam. The app's FoundationModels adapter is the only
/// production conformer; tests and harnesses supply fakes. Later providers
/// (Private Cloud Compute, tool-enabled sessions) conform here too.
@MainActor
public protocol ConversationModel: AnyObject {
    var availability: ModelAvailability { get }

    /// Replaces any existing session. The next `respond` uses these instructions.
    func prepareSession(instructions: String)
    func prewarm()
    func respond(to prompt: String, plainText: Bool, maximumResponseTokens: Int) async throws(ConversationFailure) -> ReplyDraft
    func discardSession()
}

/// The pet's side of a conversation. The runtime applies its own eligibility
/// and never records a conversation as petting or plays a sound for it.
@MainActor
public protocol CompanionPresence: AnyObject {
    var conversationSnapshot: CompanionSnapshot { get }
    func conversationAttentionBegan()
    func conversationAttentionEnded(with gesture: CompanionGesture)
}

public enum ConversationDeadline: Hashable, CaseIterable, Sendable {
    case purge, attentionTimeout

    var toleranceSeconds: Double {
        switch self {
        case .purge: 30
        case .attentionTimeout: 1
        }
    }
}

/// One pending deadline per key; scheduling a key replaces its previous deadline.
@MainActor
public protocol ConversationScheduling: AnyObject {
    func schedule(_ key: ConversationDeadline, at deadline: MonotonicTimestamp, _ action: @escaping @MainActor () -> Void)
    func cancel(_ key: ConversationDeadline)
}

public struct ConversationClock: Sendable {
    public var monotonicNow: @Sendable () -> MonotonicTimestamp
    public var wallNow: @Sendable () -> Date
    public var timeZone: @Sendable () -> TimeZone

    public init(monotonicNow: @escaping @Sendable () -> MonotonicTimestamp,
                wallNow: @escaping @Sendable () -> Date,
                timeZone: @escaping @Sendable () -> TimeZone) {
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.timeZone = timeZone
    }

    public static let system = ConversationClock(
        monotonicNow: { MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime) ?? .zero },
        wallNow: { Date() },
        timeZone: { TimeZone.current }
    )
}

/// Sleeps in a task per key. Nothing runs unless a deadline is pending.
@MainActor
public final class TaskConversationScheduler: ConversationScheduling {
    private var tasks: [ConversationDeadline: Task<Void, Never>] = [:]
    private var generations: [ConversationDeadline: UInt64] = [:]
    private let now: @Sendable () -> MonotonicTimestamp

    public init(now: @escaping @Sendable () -> MonotonicTimestamp = ConversationClock.system.monotonicNow) {
        self.now = now
    }

    isolated deinit {
        for task in tasks.values { task.cancel() }
    }

    public func schedule(_ key: ConversationDeadline, at deadline: MonotonicTimestamp, _ action: @escaping @MainActor () -> Void) {
        cancel(key)
        let generation = generations[key, default: 0]
        let delay = max(0, deadline.seconds - now().seconds)
        tasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay), tolerance: .seconds(key.toleranceSeconds))
            } catch { return }
            guard let self, self.generations[key, default: 0] == generation else { return }
            self.tasks[key] = nil
            action()
        }
    }

    public func cancel(_ key: ConversationDeadline) {
        generations[key, default: 0] &+= 1
        tasks.removeValue(forKey: key)?.cancel()
    }
}
