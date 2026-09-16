import Foundation
import SprigletCore

/// Named one-shot reasons that share the runtime's single deadline wake.
/// Additional semantic slots do not create another timer or polling loop.
enum DeadlineSlot: Hashable, Sendable {
    case autonomousBehavior
    case pointerDwell
    case pointerDeparture
    case contextRefresh
    case userIdle

    /// Lower values run first when several semantic deadlines are already due.
    /// Policy/context work must settle before autonomous behavior is considered.
    fileprivate var duePriority: Int {
        switch self {
        case .contextRefresh: 0
        case .userIdle: 1
        case .pointerDwell: 2
        case .pointerDeparture: 3
        case .autonomousBehavior: 4
        }
    }
}

@MainActor
protocol DeadlineScheduling: AnyObject {
    func schedule(_ slot: DeadlineSlot, at: MonotonicTimestamp, action: @escaping @MainActor @Sendable () -> Void)
    func cancel(_ slot: DeadlineSlot)
    func cancelAll()
}

/// A replaceable set of semantic deadlines backed by one cancellable task for
/// the earliest deadline only. It never polls while no deadline is pending.
@MainActor
final class DeadlineScheduler: DeadlineScheduling {
    private struct Entry {
        let deadline: MonotonicTimestamp
        let revision: UInt64
        let action: @MainActor @Sendable () -> Void
    }

    private let now: @MainActor () -> MonotonicTimestamp
    private var entries: [DeadlineSlot: Entry] = [:]
    private var wakeTask: Task<Void, Never>?
    private var armedDeadline: MonotonicTimestamp?
    private var wakeRevision: UInt64 = 0
    private var entryRevision: UInt64 = 0
    private var isFiring = false

    init(now: @escaping @MainActor () -> MonotonicTimestamp = {
        MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime) ?? .zero
    }) {
        self.now = now
    }

    isolated deinit {
        cancelAll()
    }

    func schedule(_ slot: DeadlineSlot, at deadline: MonotonicTimestamp, action: @escaping @MainActor @Sendable () -> Void) {
        entryRevision &+= 1
        entries[slot] = Entry(deadline: deadline, revision: entryRevision, action: action)
        reconcileWake()
    }

    func cancel(_ slot: DeadlineSlot) {
        guard entries.removeValue(forKey: slot) != nil else { return }
        reconcileWake()
    }

    func cancelAll() {
        guard !entries.isEmpty || wakeTask != nil else { return }
        entries.removeAll(keepingCapacity: true)
        wakeRevision &+= 1
        wakeTask?.cancel()
        wakeTask = nil
        armedDeadline = nil
    }

    private func reconcileWake() {
        guard !isFiring else { return }
        let earliest = entries.values.map(\.deadline).min()
        guard earliest != armedDeadline else { return }

        wakeRevision &+= 1
        wakeTask?.cancel()
        wakeTask = nil
        armedDeadline = earliest
        guard let earliest else { return }
        let revision = wakeRevision
        let delay = max(0, earliest.seconds - now().seconds)
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fire(wakeRevision: revision)
        }
    }

    private func fire(wakeRevision: UInt64) {
        guard self.wakeRevision == wakeRevision else { return }
        wakeTask = nil
        armedDeadline = nil
        isFiring = true
        defer {
            isFiring = false
            reconcileWake()
        }
        let currentTime = now()
        let due = entries
            .filter { $0.value.deadline <= currentTime }
            .sorted { lhs, rhs in
                if lhs.key.duePriority != rhs.key.duePriority {
                    return lhs.key.duePriority < rhs.key.duePriority
                }
                if lhs.value.deadline != rhs.value.deadline {
                    return lhs.value.deadline < rhs.value.deadline
                }
                return String(describing: lhs.key) < String(describing: rhs.key)
            }

        // Remove and invoke one entry at a time. Earlier callbacks may cancel
        // or replace later entries, and the stored revision makes that change
        // authoritative even though `due` is an immutable snapshot.
        for (slot, candidate) in due {
            guard let current = entries[slot], current.revision == candidate.revision else { continue }
            entries.removeValue(forKey: slot)
            current.action()
        }
    }
}
