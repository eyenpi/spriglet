import AppKit
import Foundation
import SprigletCore

@main
@MainActor
struct ContextCheck {
    static func main() async {
        do {
            NSApplication.shared.setActivationPolicy(.accessory)
            let report = try await verify()
            let data = try JSONEncoder().encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Context validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verify() async throws -> ContextValidationReport {
        let inputIdleReadCount = try verifyDemandDrivenInputIdle()
        let coalesced = try verifyActivationCoalescingAndCleanup()
        let lifecycle = try await verifyExistingLifecycleBridge()
        let coordinatorFacts = try verifyCoordinatorLifecycle()
        return ContextValidationReport(
            inputIdleReadCount: inputIdleReadCount,
            coalescedContextEvents: coalesced.map(\.reportName),
            lifecycleBridgeEvents: lifecycle.map(\.reportName),
            coordinatorFacts: coordinatorFacts.map(\.reportName)
        )
    }

    private static func verifyDemandDrivenInputIdle() throws -> Int {
        var reads = 0
        let source = UserActivitySource(
            policy: UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20)!,
            readIdleDuration: {
                reads += 1
                return 4
            }
        )

        let stoppedEvaluation = source.refresh(isSleeping: false)
        try require(reads == 0 && stoppedEvaluation == nil,
                    "Input inactivity must not be read before a lifecycle start")
        source.start()
        let firstEvaluation = source.refresh(isSleeping: false)
        try require(reads == 1 && firstEvaluation?.bucket == .recent,
                    "An explicit refresh must read aggregate input inactivity once")
        source.stop()
        let stoppedAgain = source.refresh(isSleeping: false)
        try require(reads == 1 && stoppedAgain == nil,
                    "Stopping must prevent later input-idle reads and callbacks")
        source.start()
        let secondEvaluation = source.refresh(isSleeping: false)
        try require(reads == 2 && secondEvaluation?.bucket == .recent,
                    "Restarting must retain the configured policy without retaining an idle value")
        source.stop()
        return reads
    }

    private static func verifyActivationCoalescingAndCleanup() throws -> [GenericContextStimulus] {
        let workspace = NSWorkspace.shared
        let center = NotificationCenter()
        let scheduler = ManualDeadlineScheduler()
        let clock = ManualClock(seconds: 100)
        let source = ContextSource(
            workspace: workspace,
            notificationCenter: center,
            scheduler: scheduler,
            now: { clock.timestamp },
            collapseDelaySeconds: 0.15
        )
        var callbacks: [[GenericContextStimulus]] = []
        source.onContext = { callbacks.append($0) }
        source.start()
        source.start()

        center.post(
            NSWorkspace.DidActivateApplicationMessage(application: .current),
            subject: workspace
        )
        center.post(
            NSWorkspace.DidActivateApplicationMessage(application: .current),
            subject: workspace
        )
        source.submit(.spaceChanged)
        source.submit(.displayWoke)
        try require(scheduler.deadline(for: .contextRefresh) == MonotonicTimestamp(seconds: 100.15),
                    "Context bursts must use one shared refresh deadline")
        scheduler.fire(.contextRefresh)
        let expected: [GenericContextStimulus] = [.appChanged, .spaceChanged, .displayWoke]
        try require(callbacks == [expected],
                    "Activation identity must stay private while generic facts coalesce deterministically")

        source.stop()
        center.post(
            NSWorkspace.DidActivateApplicationMessage(application: .current),
            subject: workspace
        )
        scheduler.fire(.contextRefresh)
        try require(callbacks == [expected],
                    "Stopping must remove activation observation and cancel the pending refresh")
        source.start()
        center.post(
            NSWorkspace.DidActivateApplicationMessage(application: .current),
            subject: workspace
        )
        scheduler.fire(.contextRefresh)
        try require(callbacks == [expected, [.appChanged]],
                    "Restarting must use a fresh generation and retain no old identity or deadline")
        source.stop()
        return expected
    }

    private static func verifyExistingLifecycleBridge() async throws -> [GenericContextStimulus] {
        let workspace = NSWorkspace.shared
        let workspaceCenter = NotificationCenter()
        let processCenter = NotificationCenter()
        let source = AppKitEnvironmentSource(
            workspace: workspace,
            defaultNotificationCenter: processCenter,
            workspaceNotificationCenter: workspaceCenter
        )
        let recorder = GenericRecorder()
        source.onEvent = { event in
            if let context = genericContext(from: event) {
                recorder.record(context)
            }
        }
        source.start()
        defer { source.stop() }

        let space = try await recorder.waitForNext {
            workspaceCenter.post(NSWorkspace.ActiveSpaceDidChangeMessage(), subject: workspace)
        }
        let display = try await recorder.waitForNext {
            workspaceCenter.post(NSWorkspace.ScreensDidWakeMessage(), subject: workspace)
        }
        let session = try await recorder.waitForNext {
            workspaceCenter.post(NSWorkspace.SessionDidBecomeActiveMessage(), subject: workspace)
        }
        try require([space, display, session] == [.spaceChanged, .displayWoke, .sessionActivated],
                    "Existing lifecycle events must bridge to future generic context facts")
        return [space, display, session]
    }

    private static func verifyCoordinatorLifecycle() throws -> [UserActivityContextFact.Kind] {
        let context = FakeContextSource()
        let activity = FakeUserActivity()
        let wakeMovement = FakeWakeMovementSource()
        let scheduler = ManualDeadlineScheduler()
        let clock = ManualClock(seconds: 100)
        let coordinator = PetContextCoordinator(
            context: context,
            userActivity: activity,
            wakeMovement: wakeMovement,
            scheduler: scheduler,
            now: { clock.timestamp },
            configuration: PetContextConfiguration(appGlanceCooldown: 20)!
        )
        var facts: [UserActivityContextFact.Kind] = []
        coordinator.onFact = { facts.append($0.kind) }
        var awake = PetContextPolicy(
            isSleeping: false, isVisible: true, isPaused: false,
            isSessionActive: true, isSystemAwake: true, isDisplayAwake: true,
            isThermallyConstrained: false, automaticMomentsEnabled: true
        )
        coordinator.update(policy: awake)
        try require(context.startCount == 1 && activity.startCount == 1 && wakeMovement.startCount == 0,
                    "Awake context starts demand sources but never a sleep wake monitor")

        activity.nextEvaluation = UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20)!
            .evaluate(idleDuration: 10)
        context.emit([.appChanged])
        try require(facts == [.appGlance],
                    "A coalesced app change should produce one cooldown-gated semantic glance")
        try require(scheduler.deadline(for: .userIdle) == MonotonicTimestamp(seconds: 110),
                    "Ordinary idle time should schedule one next-boundary evaluation")
        let refreshesAfterSchedule = activity.refreshCount
        coordinator.update(policy: awake)
        try require(activity.refreshCount == refreshesAfterSchedule
                        && scheduler.deadline(for: .userIdle) == MonotonicTimestamp(seconds: 110),
                    "An unchanged runtime reconciliation must preserve one existing idle deadline")

        awake.automaticMomentsEnabled = false
        coordinator.update(policy: awake)
        try require(context.stopCount == 1 && activity.stopCount == 1 && scheduler.isEmpty,
                    "Disabling automatic moments must stop context and idle work")
        let readsAfterDisable = activity.refreshCount
        scheduler.fireRetired(.userIdle)
        try require(activity.refreshCount == readsAfterDisable,
                    "A canceled idle closure must be rejected by its coordinator revision")
        activity.nextEvaluation = UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20)!
            .evaluate(idleDuration: 10)
        awake.automaticMomentsEnabled = true
        coordinator.update(policy: awake)
        try require(activity.refreshCount == refreshesAfterSchedule + 1
                        && scheduler.deadline(for: .userIdle) == MonotonicTimestamp(seconds: 110),
                    "Enabling automatic moments must demand one fresh idle read and re-arm its edge")
        let readsBeforeReplacement = activity.refreshCount
        context.emit([.spaceChanged])
        try require(activity.refreshCount == readsBeforeReplacement + 1,
                    "A context fact may replace the one retained idle deadline after one demand read")
        let readsAfterReplacement = activity.refreshCount
        scheduler.fireRetired(.userIdle)
        try require(activity.refreshCount == readsAfterReplacement,
                    "A replaced idle closure must be rejected by its coordinator revision")
        context.emit([.appChanged])
        try require(facts == [.appGlance], "App glance cooldown must collapse repeated activations")

        clock.timestamp = MonotonicTimestamp(seconds: 110)!
        activity.nextEvaluation = UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20)!
            .evaluate(idleDuration: 20)
        scheduler.fire(.userIdle)
        try require(facts == [.appGlance, .napEligible],
                    "A true aggregate idle threshold must emit a nap fact without polling")

        awake.isPaused = true
        coordinator.update(policy: awake)
        try require(context.stopCount == 2 && activity.stopCount == 2 && wakeMovement.stopCount == 0 && scheduler.isEmpty,
                    "Paused context must stop all active source work and the one idle deadline")

        var sleeping = awake
        sleeping.isPaused = false
        sleeping.isSleeping = true
        sleeping.automaticMomentsEnabled = false
        coordinator.update(policy: sleeping)
        try require(wakeMovement.startCount == 1 && scheduler.isEmpty,
                    "Sleeping permits one movement wake monitor even when automatic moments are off")
        let sleepingRefreshes = activity.refreshCount
        sleeping.automaticMomentsEnabled = true
        coordinator.update(policy: sleeping)
        coordinator.update(policy: sleeping)
        sleeping.automaticMomentsEnabled = false
        coordinator.update(policy: sleeping)
        try require(wakeMovement.startCount == 1 && wakeMovement.stopCount == 0
                        && activity.refreshCount == sleepingRefreshes,
                    "Automatic-moment toggles must not disturb or poll a sleeping wake monitor")
        activity.nextEvaluation = UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20)!
            .evaluate(idleDuration: 10, isSleeping: true)
        let refreshesBeforeStaleMovement = activity.refreshCount
        wakeMovement.emit()
        try require(wakeMovement.stopCount == 1 && wakeMovement.startCount == 2
                        && activity.refreshCount == refreshesBeforeStaleMovement + 1
                        && facts == [.appGlance, .napEligible],
                    "A non-recent sleep movement read must rearm exactly one later wake monitor without polling")
        activity.nextEvaluation = UserActivityPolicy(recentInputThreshold: 5, napThreshold: 20)!
            .evaluate(idleDuration: 0, isSleeping: true)
        wakeMovement.emit()
        try require(wakeMovement.stopCount == 2 && activity.refreshCount >= 3
                        && facts == [.appGlance, .napEligible, .wakeRequested],
                    "One sleep movement must stop its monitor and delegate a recent-input wake query")

        sleeping.isVisible = false
        coordinator.update(policy: sleeping)
        try require(context.stopCount == 3 && activity.stopCount == 3 && scheduler.isEmpty,
                    "Hidden sleeping state must leave no wake monitor or context work active")

        awake.isPaused = false
        awake.automaticMomentsEnabled = false
        coordinator.update(policy: awake)
        try require(wakeMovement.stopCount == 2 && context.startCount == 3 && activity.startCount == 3
                        && context.stopCount == 3 && activity.stopCount == 3 && scheduler.isEmpty,
                    "Manual awake mode retains no context observer, idle source, deadline, or sleep monitor")
        coordinator.stop()
        return facts
    }

    private static func genericContext(from event: EnvironmentEvent) -> GenericContextStimulus? {
        switch event {
        case .context(let stimulus):
            stimulus
        case .activeSpaceChanged, .suspension, .policyChanged:
            nil
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ContextValidationFailure(message) }
    }
}

@MainActor
private final class ManualDeadlineScheduler: DeadlineScheduling {
    private var entries: [DeadlineSlot: (MonotonicTimestamp, @MainActor @Sendable () -> Void)] = [:]
    private var retiredActions: [DeadlineSlot: [@MainActor @Sendable () -> Void]] = [:]

    func schedule(_ slot: DeadlineSlot, at: MonotonicTimestamp, action: @escaping @MainActor @Sendable () -> Void) {
        if let (_, existingAction) = entries[slot] {
            retiredActions[slot, default: []].append(existingAction)
        }
        entries[slot] = (at, action)
    }

    func cancel(_ slot: DeadlineSlot) {
        if let (_, action) = entries.removeValue(forKey: slot) {
            retiredActions[slot, default: []].append(action)
        }
    }
    func cancelAll() {
        for (slot, entry) in entries {
            retiredActions[slot, default: []].append(entry.1)
        }
        entries.removeAll()
    }
    func deadline(for slot: DeadlineSlot) -> MonotonicTimestamp? { entries[slot]?.0 }
    var isEmpty: Bool { entries.isEmpty }

    func fire(_ slot: DeadlineSlot) {
        guard let (_, action) = entries.removeValue(forKey: slot) else { return }
        action()
    }

    func fireRetired(_ slot: DeadlineSlot) {
        let actions = retiredActions.removeValue(forKey: slot) ?? []
        for action in actions { action() }
    }
}

@MainActor
private final class ManualClock {
    var timestamp: MonotonicTimestamp
    init(seconds: TimeInterval) { timestamp = MonotonicTimestamp(seconds: seconds)! }
}

@MainActor
private final class FakeContextSource: ContextObserving {
    var onContext: (([GenericContextStimulus]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var submitted: [GenericContextStimulus] = []
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }
    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }
    func submit(_ stimulus: GenericContextStimulus) { submitted.append(stimulus) }
    func emit(_ values: [GenericContextStimulus]) { onContext?(values) }
}

@MainActor
private final class FakeUserActivity: UserActivityObserving {
    var nextEvaluation: UserActivityEvaluation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }
    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }
    func refresh(isSleeping: Bool) -> UserActivityEvaluation? {
        refreshCount += 1
        return isRunning ? nextEvaluation : nil
    }
}

@MainActor
private final class FakeWakeMovementSource: WakeMovementObserving {
    var onWakeMovement: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }

    func emit() {
        guard isRunning else { return }
        stop()
        onWakeMovement?()
    }
}

@MainActor
private final class GenericRecorder {
    private var nextWaiter: CheckedContinuation<GenericContextStimulus, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func record(_ value: GenericContextStimulus) {
        timeoutTask?.cancel()
        timeoutTask = nil
        nextWaiter?.resume(returning: value)
        nextWaiter = nil
    }

    func waitForNext(while triggering: () -> Void) async throws -> GenericContextStimulus {
        try await withCheckedThrowingContinuation { continuation in
            precondition(nextWaiter == nil, "Only one generic context expectation may be pending")
            nextWaiter = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                self?.timeOut()
            }
            triggering()
        }
    }

    private func timeOut() {
        guard let nextWaiter else { return }
        self.nextWaiter = nil
        timeoutTask = nil
        nextWaiter.resume(throwing: ContextValidationFailure("Timed out waiting for a typed context message"))
    }
}

private extension GenericContextStimulus {
    var reportName: String {
        switch self {
        case .appChanged: "appChanged"
        case .spaceChanged: "spaceChanged"
        case .displayWoke: "displayWoke"
        case .sessionActivated: "sessionActivated"
        }
    }
}

private extension UserActivityContextFact.Kind {
    var reportName: String {
        switch self {
        case .wakeRequested: "wakeRequested"
        case .napEligible: "napEligible"
        case .appGlance: "appGlance"
        }
    }
}

private struct ContextValidationReport: Encodable {
    let inputIdleReadCount: Int
    let coalescedContextEvents: [String]
    let lifecycleBridgeEvents: [String]
    let coordinatorFacts: [String]
}

private struct ContextValidationFailure: LocalizedError {
    let errorDescription: String?
    init(_ errorDescription: String) { self.errorDescription = errorDescription }
}
