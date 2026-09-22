import Foundation
import SprigletCore

/// The runtime facts that allow context activity. The coordinator never infers
/// these states; it receives one coherent value from the host world boundary.
struct PetContextPolicy: Equatable, Sendable {
    var isSleeping: Bool
    var isVisible: Bool
    var isPaused: Bool
    var isSessionActive: Bool
    var isSystemAwake: Bool
    var isDisplayAwake: Bool
    var isThermallyConstrained: Bool
    var automaticMomentsEnabled: Bool

    var permitsContextWork: Bool {
        isVisible && !isPaused && isSessionActive && isSystemAwake
            && isDisplayAwake && !isThermallyConstrained
    }

    var permitsAutomaticEvaluation: Bool {
        permitsContextWork && !isSleeping && automaticMomentsEnabled
    }

    var permitsSleepWakeMovement: Bool {
        permitsContextWork && isSleeping
    }
}

struct PetContextConfiguration: Equatable, Sendable {
    var appGlanceCooldown: TimeInterval

    init?(appGlanceCooldown: TimeInterval = 20) {
        guard appGlanceCooldown.isFinite, appGlanceCooldown >= 0 else { return nil }
        self.appGlanceCooldown = appGlanceCooldown
    }

    static let standard = PetContextConfiguration()!
}

/// Bridges context, demand-driven aggregate input-idle values, and a single
/// sleep-only movement wake signal into semantic core facts. It owns no
/// renderer, world reducer, display link, polling loop, or pointer coordinate.
@MainActor
final class PetContextCoordinator {
    private enum WorkMode: Equatable {
        case stopped
        case sleeping
        case awakeManual
        case awakeAutomatic
    }

    private enum ActivityOutcome: Equatable {
        case unavailable
        case staleWhileSleeping
        case wakeRequested
        case idleDeadlineScheduled
        case napEligible
    }

    var onFact: ((UserActivityContextFact) -> Void)?

    private let context: any ContextObserving
    private let userActivity: any UserActivityObserving
    private let wakeMovement: any WakeMovementObserving
    private let scheduler: any DeadlineScheduling
    private let now: @MainActor () -> MonotonicTimestamp
    private let configuration: PetContextConfiguration
    private var policy = PetContextPolicy(
        isSleeping: false, isVisible: false, isPaused: false,
        isSessionActive: false, isSystemAwake: false, isDisplayAwake: false,
        isThermallyConstrained: true, automaticMomentsEnabled: false
    )
    private var idleDeadlineRevision: UInt64 = 0
    private var lastAppGlance: MonotonicTimestamp?

    init(
        context: any ContextObserving,
        userActivity: any UserActivityObserving,
        wakeMovement: any WakeMovementObserving,
        scheduler: any DeadlineScheduling,
        now: @escaping @MainActor () -> MonotonicTimestamp = {
            MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime) ?? .zero
        },
        configuration: PetContextConfiguration = .standard
    ) {
        self.context = context
        self.userActivity = userActivity
        self.wakeMovement = wakeMovement
        self.scheduler = scheduler
        self.now = now
        self.configuration = configuration
        context.onContext = { [weak self] values in self?.receive(context: values) }
        wakeMovement.onWakeMovement = { [weak self] in self?.receiveWakeMovement() }
    }

    isolated deinit {
        context.onContext = nil
        wakeMovement.onWakeMovement = nil
        context.stop()
        userActivity.stop()
        wakeMovement.stop()
        scheduler.cancel(.userIdle)
    }

    /// Reconciles all source lifecycles atomically. Hidden, paused, inactive
    /// session, sleeping system/display, and thermal-constrained states leave
    /// no context callback work, wake monitor, or user-idle deadline active.
    func update(policy: PetContextPolicy) {
        let previous = self.policy
        guard policy != previous else { return }
        self.policy = policy
        let previousMode = workMode(for: previous)
        let mode = workMode(for: policy)
        guard mode != previousMode else { return }

        if mode == .stopped {
            stopAllWork()
            return
        }

        switch mode {
        case .sleeping:
            context.start()
            userActivity.start()
            invalidateIdleDeadline()
            wakeMovement.start()
        case .awakeManual:
            context.stop()
            userActivity.stop()
            wakeMovement.stop()
            invalidateIdleDeadline()
        case .awakeAutomatic:
            context.start()
            userActivity.start()
            wakeMovement.stop()
            // A newly eligible automatic policy has no valid retained idle
            // deadline. Read once now and then retain just its next edge.
            invalidateIdleDeadline()
            _ = refreshActivity(isSleeping: false)
        case .stopped:
            break
        }
    }

    /// Receives the generic fact emitted by the sole lifecycle environment
    /// source. The ContextSource coalesces it before any input-idle query.
    func submit(_ stimulus: GenericContextStimulus) {
        guard policy.permitsContextWork else { return }
        context.submit(stimulus)
    }

    func stop() {
        policy.isVisible = false
        stopAllWork()
    }

    private func receive(context values: [GenericContextStimulus]) {
        guard policy.permitsContextWork, !values.isEmpty else { return }
        if policy.isSleeping {
            _ = refreshActivity(isSleeping: true)
        } else if policy.permitsAutomaticEvaluation,
                  refreshActivity(isSleeping: false) == .napEligible {
            // Nap eligibility has higher semantic priority than an app glance
            // from the same coalesced context burst.
            return
        }
        guard values.contains(.appChanged), policy.permitsAutomaticEvaluation else { return }
        let timestamp = now()
        guard lastAppGlance.map({ timestamp.seconds - $0.seconds >= configuration.appGlanceCooldown }) ?? true else { return }
        lastAppGlance = timestamp
        emit(.appGlance, at: timestamp)
    }

    private func receiveWakeMovement() {
        guard policy.permitsSleepWakeMovement else { return }
        let outcome = refreshActivity(isSleeping: true)
        guard policy.permitsSleepWakeMovement, outcome != .wakeRequested else { return }
        // The source stopped itself before callback. A non-recent or unavailable
        // aggregate read must therefore rearm for a later local/global movement.
        wakeMovement.start()
    }

    private func refreshActivity(isSleeping: Bool) -> ActivityOutcome {
        guard let evaluation = userActivity.refresh(isSleeping: isSleeping) else {
            return .unavailable
        }
        return receive(activity: evaluation)
    }

    private func receive(activity evaluation: UserActivityEvaluation) -> ActivityOutcome {
        guard policy.permitsContextWork else { return .unavailable }
        if policy.isSleeping {
            guard evaluation.shouldWake else { return .staleWhileSleeping }
            wakeMovement.stop()
            emit(.wakeRequested, at: now())
            return .wakeRequested
        }
        guard policy.permitsAutomaticEvaluation else { return .unavailable }
        if evaluation.allowsNap {
            invalidateIdleDeadline()
            emit(.napEligible, at: now())
            return .napEligible
        }
        guard let delay = evaluation.nextIdleDeadlineSeconds,
              let deadline = MonotonicTimestamp(seconds: now().seconds + delay)
        else {
            invalidateIdleDeadline()
            return .unavailable
        }
        idleDeadlineRevision &+= 1
        let revision = idleDeadlineRevision
        scheduler.schedule(.userIdle, at: deadline) { [weak self] in
            self?.evaluateIdleDeadline(revision: revision)
        }
        return .idleDeadlineScheduled
    }

    private func evaluateIdleDeadline(revision: UInt64) {
        guard revision == idleDeadlineRevision, policy.permitsAutomaticEvaluation else { return }
        // Mark this one-shot edge consumed before reading. Any replacement gets
        // its own revision, so even a scheduler delivering a stale closure
        // cannot produce an extra aggregate input query.
        idleDeadlineRevision &+= 1
        _ = refreshActivity(isSleeping: false)
    }

    private func stopAllWork() {
        context.stop()
        userActivity.stop()
        wakeMovement.stop()
        invalidateIdleDeadline()
    }

    private func invalidateIdleDeadline() {
        idleDeadlineRevision &+= 1
        scheduler.cancel(.userIdle)
    }

    private func workMode(for policy: PetContextPolicy) -> WorkMode {
        guard policy.permitsContextWork else { return .stopped }
        if policy.isSleeping { return .sleeping }
        return policy.automaticMomentsEnabled ? .awakeAutomatic : .awakeManual
    }

    private func emit(_ kind: UserActivityContextFact.Kind, at timestamp: MonotonicTimestamp) {
        onFact?(UserActivityContextFact(timestamp: timestamp, kind: kind))
    }
}
