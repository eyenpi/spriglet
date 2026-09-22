import AppKit
import Foundation
import SprigletCore

/// Generic, value-only context changes. Application identity is used only to
/// suppress repeated activation notices while this source is running; it never
/// leaves this boundary.
@MainActor
protocol ContextObserving: AnyObject {
    var onContext: (([GenericContextStimulus]) -> Void)? { get set }

    func start()
    func stop()
    func submit(_ stimulus: GenericContextStimulus)
}

/// Observes foreground application changes and coalesces them with generic
/// workspace context facts supplied by `AppKitEnvironmentSource`.
///
/// Workspace wake, session, display, and Space observation remains owned by
/// the existing lifecycle source. This source deliberately installs only the
/// typed application-activation observer, so it cannot duplicate wake
/// listeners while the pet is suspended.
@MainActor
final class ContextSource: ContextObserving {
    var onContext: (([GenericContextStimulus]) -> Void)?

    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let scheduler: any DeadlineScheduling
    private let now: @MainActor () -> MonotonicTimestamp
    private let collapseDelaySeconds: TimeInterval
    private var tokens: [NotificationCenter.ObservationToken] = []
    private var pending: Set<GenericContextStimulus> = []
    private var activeApplicationIdentifier: String?
    private var hasObservedApplication = false
    private var generation: UInt64 = 0
    private var isRunning = false

    init(
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter? = nil,
        scheduler: any DeadlineScheduling,
        now: @escaping @MainActor () -> MonotonicTimestamp = {
            MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime) ?? .zero
        },
        collapseDelaySeconds: TimeInterval = 0.15
    ) {
        precondition(collapseDelaySeconds.isFinite && collapseDelaySeconds >= 0)
        self.workspace = workspace
        self.notificationCenter = notificationCenter ?? workspace.notificationCenter
        self.scheduler = scheduler
        self.now = now
        self.collapseDelaySeconds = collapseDelaySeconds
    }

    isolated deinit { stop() }

    func start() {
        guard !isRunning else { return }

        generation &+= 1
        let generation = generation
        isRunning = true
        tokens.append(notificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.DidActivateApplicationMessage.self
        ) { [weak self] message in
            self?.observeActivation(message.application.bundleIdentifier, generation: generation)
        })
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false
        generation &+= 1
        tokens.removeAll()
        scheduler.cancel(.contextRefresh)
        pending.removeAll(keepingCapacity: false)
        activeApplicationIdentifier = nil
        hasObservedApplication = false
    }

    /// Accepts a generic fact from the single workspace lifecycle source or
    /// this source's activation observer. Callers never pass platform objects.
    func submit(_ stimulus: GenericContextStimulus) {
        guard isRunning else { return }
        pending.insert(stimulus)
        scheduleRefresh()
    }

    private func observeActivation(_ bundleIdentifier: String?, generation: UInt64) {
        guard isRunning, generation == self.generation else { return }
        guard !hasObservedApplication || activeApplicationIdentifier != bundleIdentifier else { return }

        hasObservedApplication = true
        activeApplicationIdentifier = bundleIdentifier
        submit(.appChanged)
    }

    private func scheduleRefresh() {
        let generation = generation
        guard let deadline = MonotonicTimestamp(seconds: now().seconds + collapseDelaySeconds) else { return }
        scheduler.schedule(.contextRefresh, at: deadline) { [weak self] in
            self?.flush(generation: generation)
        }
    }

    private func flush(generation: UInt64) {
        guard isRunning, generation == self.generation, !pending.isEmpty else { return }
        let values = GenericContextStimulus.ordered.filter(pending.contains)
        pending.removeAll(keepingCapacity: true)
        onContext?(values)
    }
}

private extension GenericContextStimulus {
    static let ordered: [Self] = [.appChanged, .spaceChanged, .displayWoke, .sessionActivated]
}
