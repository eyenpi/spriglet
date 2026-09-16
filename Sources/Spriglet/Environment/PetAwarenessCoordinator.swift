import AppKit
import Foundation
import SprigletCore

/// Runtime facts that permit ephemeral pointer observation. The coordinator
/// receives these from the world/runtime; it does not observe lifecycle state
/// itself, so the low-frequency workspace source remains able to wake work.
struct PointerAwarenessPolicy: Equatable, Sendable {
    var isAwake: Bool
    var isVisible: Bool
    var isSuspended: Bool
    var isPaused: Bool
    var isInteracting: Bool
    var isConstrained: Bool
    var isLowPower: Bool

    var allowsObservation: Bool {
        isAwake && isVisible && !isSuspended && !isPaused && !isInteracting && !isConstrained
    }
}

/// One in-process awareness handoff. `perception` retains one ephemeral sample
/// for a future reducer; `attention` is coordinate-free and safe to route to
/// behavior or rendering bridges. Neither value is persisted or logged here.
struct PointerAwarenessUpdate: Equatable, Sendable {
    let perception: PointerPerception
    let attention: PointerAttentionState
}

/// Starts pointer monitoring only during useful awake, visible, unconstrained
/// work. Environment lifecycle observation intentionally lives elsewhere: a
/// stopped pointer source cannot wake the pet after sleep or session changes.
@MainActor
final class PetAwarenessCoordinator {
    var onStimulus: ((PointerAwarenessUpdate) -> Void)?
    var counters: PointerSourceCounters { source.counters }

    private let source: any PointerObserving
    private let scheduler: any DeadlineScheduling
    private let now: @MainActor () -> MonotonicTimestamp
    private let perceptionConfiguration: PointerPerceptionConfiguration
    private let attentionConfiguration: PointerAttentionConfiguration
    private var policy = PointerAwarenessPolicy(
        isAwake: false, isVisible: false, isSuspended: true, isPaused: false,
        isInteracting: false, isConstrained: true, isLowPower: false
    )
    private var target: PointerPoint?
    private var perception = PointerPerception.empty
    private var attention = PointerAttentionState.neutral
    private var lastUpdate: PointerAwarenessUpdate?
    private var lifecycleGeneration: UInt64 = 0

    init(
        source: any PointerObserving,
        scheduler: any DeadlineScheduling,
        now: @escaping @MainActor () -> MonotonicTimestamp = {
            MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime) ?? .zero
        },
        perceptionConfiguration: PointerPerceptionConfiguration = .standard,
        attentionConfiguration: PointerAttentionConfiguration = .standard
    ) {
        self.source = source
        self.scheduler = scheduler
        self.now = now
        self.perceptionConfiguration = perceptionConfiguration
        self.attentionConfiguration = attentionConfiguration
        source.onSample = { [weak self] sample in self?.receive(sample) }
    }

    isolated deinit {
        source.onSample = nil
        source.stop()
        scheduler.cancel(.pointerDwell)
        scheduler.cancel(.pointerDeparture)
    }

    /// Updates the pet's screen bounds and active-work policy atomically. A
    /// location change clears a stationary pointer history before the next
    /// sample, so moving the pet never creates synthetic pointer approach.
    func update(policy: PointerAwarenessPolicy, petBounds: CGRect?) {
        let nextTarget = Self.target(from: petBounds)
        let targetChanged = target != nextTarget
        self.policy = policy
        target = nextTarget
        if targetChanged {
            perception = .empty
            attention = .neutral
            publish()
        }

        guard policy.allowsObservation, nextTarget != nil else {
            suspendActiveWork()
            return
        }
        source.start(cadence: policy.isLowPower ? .lowPower : .normal)
        reconcileDeadlines(generation: lifecycleGeneration)
    }

    func stop() {
        policy.isSuspended = true
        suspendActiveWork()
    }

    private func receive(_ sample: PointerSample) {
        guard policy.allowsObservation, let target else { return }
        guard (perception.latestSample?.timestamp ?? .zero) <= sample.timestamp else { return }
        perception = PointerPerception.reduce(
            perception, sample: sample, toward: target, configuration: perceptionConfiguration
        )
        attention = PointerAttention.reduce(
            attention, perception: perception, toward: target, at: sample.timestamp,
            perceptionConfiguration: perceptionConfiguration, configuration: attentionConfiguration
        )
        publish()
        reconcileDeadlines(generation: lifecycleGeneration)
    }

    private func handleDwellDeadline(generation: UInt64) {
        guard generation == lifecycleGeneration, policy.allowsObservation else { return }
        let timestamp = now()
        perception = perception.evaluatingDwell(at: timestamp, configuration: perceptionConfiguration)
        attention = PointerAttention.evaluate(
            attention, perception: perception, at: timestamp, perceptionConfiguration: perceptionConfiguration
        )
        publish()
        reconcileDeadlines(generation: generation)
    }

    private func handleDepartureDeadline(generation: UInt64) {
        guard generation == lifecycleGeneration, policy.allowsObservation else { return }
        let timestamp = now()
        attention = PointerAttention.evaluate(
            attention, perception: perception, at: timestamp, perceptionConfiguration: perceptionConfiguration
        )
        publish()
        reconcileDeadlines(generation: generation)
    }

    private func reconcileDeadlines(generation: UInt64) {
        if let deadline = attention.dwellDeadline, attention.mode != .dwelling {
            scheduler.schedule(.pointerDwell, at: deadline) { [weak self] in
                self?.handleDwellDeadline(generation: generation)
            }
        } else {
            scheduler.cancel(.pointerDwell)
        }
        if let deadline = attention.departureDeadline, attention.mode == .departureHold {
            scheduler.schedule(.pointerDeparture, at: deadline) { [weak self] in
                self?.handleDepartureDeadline(generation: generation)
            }
        } else {
            scheduler.cancel(.pointerDeparture)
        }
    }

    private func suspendActiveWork() {
        lifecycleGeneration &+= 1
        source.stop()
        scheduler.cancel(.pointerDwell)
        scheduler.cancel(.pointerDeparture)
        perception = .empty
        attention = .neutral
        publish()
    }

    private func publish() {
        let update = PointerAwarenessUpdate(perception: perception, attention: attention)
        guard update != lastUpdate else { return }
        lastUpdate = update
        onStimulus?(update)
    }

    private static func target(from bounds: CGRect?) -> PointerPoint? {
        guard let bounds, bounds.width.isFinite, bounds.height.isFinite,
              bounds.midX.isFinite, bounds.midY.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return PointerPoint(x: bounds.midX, y: bounds.midY)
    }
}
