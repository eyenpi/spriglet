import AppKit
import Foundation
import QuartzCore
import SprigletCore

@main
@MainActor
final class PointerSourceCheck: NSObject, NSApplicationDelegate {
    private var validationTask: Task<Void, Never>?
    private var exitCode: Int32 = 0

    static func main() {
        let application = NSApplication.shared
        let delegate = PointerSourceCheck()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        exit(delegate.exitCode)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let live = CommandLine.arguments.dropFirst().contains("--live")
        validationTask = Task { [weak self] in
            do {
                let report = try await Self.measure(live: live)
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                self?.exitCode = 1
                fputs("Pointer source validation failed: \(error.localizedDescription)\n", stderr)
            }
            NSApp.terminate(nil)
        }
    }

    private static func measure(live: Bool) async throws -> PointerSourceReport {
        let source = AppKitPointerSource()
        let livePanel = live ? LivePointerPanel(source: source) : nil
        source.start(cadence: .normal)
        if let livePanel {
            livePanel.show()
            for remainingTenths in stride(from: 300, to: 0, by: -1) {
                livePanel.update(counters: source.counters, remainingSeconds: Double(remainingTenths) / 10)
                try await Task.sleep(for: .milliseconds(100))
            }
        } else {
            try await Task.sleep(for: .seconds(1))
        }
        let physicalCounters = source.counters
        source.stop()
        livePanel?.close()

        try await verifyCoalescerStopCancellation()
        try await verifyCoalescerDeinitializationCancellation()
        try await verifyDeadlineCoalescingAndCancellation()
        try await verifyConcurrentDeadlineCancellationAndPriority()
        try await verifyAwarenessCoordinator()
        try await verifyPointerRendererPipeline()
        let syntheticCounters = try await measureSyntheticCoalescing()
        let adaptiveSamplerReads = try await measureAdaptiveSampler()
        return PointerSourceReport(
            sourceCadenceHertz: PointerCadence.normal.maximumHertz,
            syntheticMonitorEvents: syntheticCounters.receivedEventCount,
            syntheticCoalescedSamples: syntheticCounters.deliveredSampleCount,
            adaptiveSamplerHertz: PointerCadence.lowPower.maximumHertz,
            adaptiveSamplerReads: adaptiveSamplerReads,
            physicalMonitorEvents: physicalCounters.receivedEventCount,
            physicalCoalescedSamples: physicalCounters.deliveredSampleCount,
            physicalLocalEvents: physicalCounters.localEventCount,
            physicalGlobalEvents: physicalCounters.globalEventCount,
            physicalMonitorEvidence: physicalCounters.receivedEventCount > 0 ? "observed" : "hardware-movement-needed"
        )
    }

    private static func measureSyntheticCoalescing() async throws -> PointerSourceCounters {
        let coalescer = PointerCoalescer(cadence: .normal)
        var received = 0
        coalescer.onSample = { _ in received += 1 }
        for index in 0..<120 {
            guard let timestamp = MonotonicTimestamp(seconds: Double(index) / 200),
                  let point = PointerPoint(x: Double(index), y: 0)
            else { throw PointerValidationFailure("Synthetic pointer input was not finite") }
            coalescer.submit(PointerSample(timestamp: timestamp, location: point))
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        let counters = coalescer.counters
        coalescer.stop()
        guard counters.deliveredSampleCount == UInt64(received),
              counters.deliveredSampleCount > 0,
              counters.deliveredSampleCount < counters.receivedEventCount
        else { throw PointerValidationFailure("Latest-value coalescing did not bound synthetic monitor delivery") }
        return counters
    }

    private static func verifyCoalescerStopCancellation() async throws {
        let coalescer = PointerCoalescer(cadence: .normal)
        guard let timestamp = MonotonicTimestamp(seconds: 1),
              let point = PointerPoint(x: 0, y: 0)
        else { throw PointerValidationFailure("Stop-cancellation input was not finite") }
        coalescer.submit(PointerSample(timestamp: timestamp, location: point))
        coalescer.stop()
        try await Task.sleep(for: .milliseconds(100))
        guard coalescer.counters.deliveredSampleCount == 0 else {
            throw PointerValidationFailure("A cancelled one-shot wake delivered after stop")
        }
    }

    private static func verifyCoalescerDeinitializationCancellation() async throws {
        var delivered = 0
        var coalescer: PointerCoalescer? = PointerCoalescer(cadence: .lowPower)
        coalescer?.onSample = { _ in delivered += 1 }
        guard let timestamp = MonotonicTimestamp(seconds: 1),
              let point = PointerPoint(x: 0, y: 0)
        else { throw PointerValidationFailure("Deinitialization-cancellation input was not finite") }
        coalescer?.submit(PointerSample(timestamp: timestamp, location: point))
        coalescer = nil
        try await Task.sleep(for: .milliseconds(120))
        guard delivered == 0 else {
            throw PointerValidationFailure("A one-shot wake delivered after coalescer deinitialization")
        }
    }

    private static func verifyDeadlineCoalescingAndCancellation() async throws {
        let scheduler = DeadlineScheduler()
        var callbacks: [String] = []
        let current = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime)!
        scheduler.schedule(.pointerDwell, at: MonotonicTimestamp(seconds: current.seconds + 0.20)!) {
            callbacks.append("replaced")
        }
        scheduler.schedule(.pointerDwell, at: MonotonicTimestamp(seconds: current.seconds + 0.05)!) {
            callbacks.append("earliest")
        }
        scheduler.schedule(.pointerDeparture, at: MonotonicTimestamp(seconds: current.seconds + 0.08)!) {
            callbacks.append("cancelled")
        }
        scheduler.cancel(.pointerDeparture)
        try await Task.sleep(for: .milliseconds(260))
        guard callbacks == ["earliest"] else {
            throw PointerValidationFailure("Deadline replacement or cancellation left a stale callback")
        }
    }

    private static func verifyConcurrentDeadlineCancellationAndPriority() async throws {
        let scheduler = DeadlineScheduler()
        var callbacks: [String] = []
        let current = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime)!
        let sharedDeadline = MonotonicTimestamp(seconds: current.seconds + 0.05)!
        scheduler.schedule(.autonomousBehavior, at: sharedDeadline) {
            callbacks.append("autonomous")
        }
        scheduler.schedule(.userIdle, at: sharedDeadline) {
            callbacks.append("idle")
        }
        scheduler.schedule(.contextRefresh, at: sharedDeadline) {
            callbacks.append("context")
            scheduler.cancel(.autonomousBehavior)
        }
        try await Task.sleep(for: .milliseconds(140))
        guard callbacks == ["context", "idle"] else {
            throw PointerValidationFailure(
                "Concurrent due callbacks ignored semantic priority or callback-time cancellation: \(callbacks)"
            )
        }

        callbacks.removeAll(keepingCapacity: true)
        let replacementScheduler = DeadlineScheduler()
        let replacementNow = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime)!
        let firstDeadline = MonotonicTimestamp(seconds: replacementNow.seconds + 0.04)!
        replacementScheduler.schedule(.userIdle, at: firstDeadline) {
            callbacks.append("stale")
        }
        replacementScheduler.schedule(.contextRefresh, at: firstDeadline) {
            callbacks.append("replace")
            let later = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime + 0.05)!
            replacementScheduler.schedule(.userIdle, at: later) {
                callbacks.append("current")
            }
        }
        try await Task.sleep(for: .milliseconds(70))
        guard callbacks == ["replace"] else {
            throw PointerValidationFailure("A replaced due entry invoked its stale revision: \(callbacks)")
        }
        try await Task.sleep(for: .milliseconds(70))
        guard callbacks == ["replace", "current"] else {
            throw PointerValidationFailure("A replacement deadline was not rearmed after due delivery: \(callbacks)")
        }
    }

    private static func verifyAwarenessCoordinator() async throws {
        let source = FakePointerSource()
        let scheduler = FakeDeadlineScheduler()
        let clock = FakeClock(timestamp: MonotonicTimestamp(seconds: 0)!)
        let perceptionConfiguration = PointerPerceptionConfiguration(
            nearEnterDistance: 180, nearExitDistance: 220,
            dwellEnterDistance: 96, dwellExitDistance: 120,
            dwellDuration: 0.8, maximumSampleGap: 0.75,
            teleportDistance: 480, projectionHorizon: 0.35
        )!
        let attentionConfiguration = PointerAttentionConfiguration(
            gazeRangePixels: 160, curiousDistance: 180,
            curiousApproachSpeed: 36, departureSpeed: 36, departureHoldDuration: 0.45
        )!
        let coordinator = PetAwarenessCoordinator(
            source: source, scheduler: scheduler, now: { clock.timestamp },
            perceptionConfiguration: perceptionConfiguration, attentionConfiguration: attentionConfiguration
        )
        var updates: [PointerAwarenessUpdate] = []
        coordinator.onStimulus = { updates.append($0) }
        let active = PointerAwarenessPolicy(
            isAwake: true, isVisible: true, isSuspended: false, isPaused: false,
            isInteracting: false, isConstrained: false, isLowPower: false
        )
        coordinator.update(policy: active, petBounds: CGRect(x: -50, y: -50, width: 100, height: 100))
        guard source.startCount == 1, coordinator.counters == source.counters else {
            throw PointerValidationFailure("Awareness coordinator did not start its injected source")
        }

        source.emit(sample(seconds: 0, x: 20))
        guard coordinator.counters.receivedEventCount == 1,
              coordinator.counters.deliveredSampleCount == 1 else {
            throw PointerValidationFailure("Awareness coordinator did not expose counts-only source diagnostics")
        }
        guard scheduler.deadline(for: .pointerDwell) == MonotonicTimestamp(seconds: 0.8) else {
            throw PointerValidationFailure("Stationary dwell did not receive one explicit deadline")
        }
        clock.timestamp = MonotonicTimestamp(seconds: 0.8)!
        scheduler.fire(.pointerDwell)
        guard updates.last?.attention.mode == .dwelling else {
            throw PointerValidationFailure("Dwell did not mature through the injected deadline")
        }

        coordinator.update(policy: active, petBounds: CGRect(x: 50, y: -50, width: 100, height: 100))
        guard updates.last?.perception == .empty, updates.last?.attention == .neutral else {
            throw PointerValidationFailure("A pet bounds change retained stale pointer history")
        }
        source.emit(sample(seconds: 1, x: 120))
        source.emit(sample(seconds: 1.2, x: 180))
        guard updates.last?.attention.mode == .departureHold,
              let departure = scheduler.deadline(for: .pointerDeparture) else {
            throw PointerValidationFailure("Departure did not receive one explicit hold deadline")
        }
        let updateCount = updates.count
        source.emit(sample(seconds: 1.1, x: 130))
        guard updates.count == updateCount,
              scheduler.deadline(for: .pointerDeparture) == departure else {
            throw PointerValidationFailure("An out-of-order pointer sample changed attention or its deadline")
        }
        clock.timestamp = departure
        scheduler.fire(.pointerDeparture)
        guard updates.last?.attention == .neutral else {
            throw PointerValidationFailure("Departure hold did not settle to neutral")
        }

        var paused = active
        paused.isPaused = true
        coordinator.update(policy: paused, petBounds: CGRect(x: 50, y: -50, width: 100, height: 100))
        guard source.stopCount == 1, scheduler.isEmpty,
              updates.last?.perception == .empty, updates.last?.attention == .neutral else {
            throw PointerValidationFailure("Suspension left a pointer source, deadline, or retained sample active")
        }
    }

    private static func verifyPointerRendererPipeline() async throws {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("AcornHopper"),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("character.json").path)
        else { throw PointerValidationFailure("Copied AcornHopper resources are missing") }

        let renderer = PetRenderView(frame: .zero, resourceDirectory: resources)
        guard renderer.assetError == nil, renderer.characterPackage != nil else {
            throw PointerValidationFailure("Production renderer rejected the copied character package")
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: renderer.displaySize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = renderer
        panel.orderFrontRegardless()
        CATransaction.flush()

        let source = FakePointerSource()
        let scheduler = FakeDeadlineScheduler()
        let clock = FakeClock(timestamp: MonotonicTimestamp(seconds: 0)!)
        let coordinator = PetAwarenessCoordinator(source: source, scheduler: scheduler, now: { clock.timestamp })
        var world = PetWorldSnapshot()
        var callbackCount = 0
        coordinator.onStimulus = { update in
            callbackCount += 1
            world = WorldReducer.reduce(
                world,
                PetStimulus(timestamp: clock.timestamp, event: .pointer(
                    perception: update.perception, attention: update.attention
                ))
            )
            for command in PointerIntentDirector.commands(in: world) {
                _ = renderer.perform(command)
            }
        }
        let active = PointerAwarenessPolicy(
            isAwake: true, isVisible: true, isSuspended: false, isPaused: false,
            isInteracting: false, isConstrained: false, isLowPower: false
        )
        coordinator.update(policy: active, petBounds: CGRect(x: -48, y: -48, width: 96, height: 96))

        let framesBefore = renderer.submittedFrameCount
        source.emit(sample(seconds: 0, x: 20))
        guard renderer.proceduralCommitCount > 0,
              renderer.submittedFrameCount == framesBefore,
              !renderer.hasActiveDisplayLink, !renderer.isAnimating else {
            throw PointerValidationFailure("Gaze did not remain on the retained, clock-free renderer path")
        }

        clock.timestamp = MonotonicTimestamp(seconds: 0.8)!
        scheduler.fire(.pointerDwell)
        guard world.attention.mode == .dwelling else {
            throw PointerValidationFailure("Stationary dwell did not cross coordinator/world/renderer boundaries")
        }

        coordinator.update(policy: active, petBounds: CGRect(x: 52, y: -48, width: 96, height: 96))
        clock.timestamp = MonotonicTimestamp(seconds: 1)!
        source.emit(sample(seconds: 1, x: 120))
        clock.timestamp = MonotonicTimestamp(seconds: 1.2)!
        source.emit(sample(seconds: 1.2, x: 180))
        guard let departureDeadline = scheduler.deadline(for: .pointerDeparture) else {
            throw PointerValidationFailure("Departure hold was lost in the renderer pipeline")
        }
        clock.timestamp = departureDeadline
        scheduler.fire(.pointerDeparture)
        guard world.attention == .neutral else {
            throw PointerValidationFailure("Departure did not cleanly return the world to neutral attention")
        }

        var suspended = active
        suspended.isSuspended = true
        world = WorldReducer.reduce(
            world,
            PetStimulus(timestamp: clock.timestamp, event: .suspension(reason: .userPaused, active: true))
        )
        _ = renderer.perform(.suspended(true))
        let callbacksAtSuspend = callbackCount
        let commitsAtSuspend = renderer.proceduralCommitCount
        coordinator.update(policy: suspended, petBounds: CGRect(x: 52, y: -48, width: 96, height: 96))
        source.emit(sample(seconds: departureDeadline.seconds + 0.1, x: 100))
        try await Task.sleep(for: .milliseconds(40))
        guard callbackCount == callbacksAtSuspend + 1,
              renderer.proceduralCommitCount == commitsAtSuspend,
              !renderer.hasActiveDisplayLink, !renderer.isAnimating,
              renderer.activeRigAnimationCount == 0 else {
            throw PointerValidationFailure("Suspension left pointer callbacks, commits, or renderer clocks active")
        }

        coordinator.stop()
        panel.close()
        CATransaction.flush()
        guard !renderer.hasActiveDisplayLink, !renderer.isAnimating,
              renderer.activeRigAnimationCount == 0 else {
            throw PointerValidationFailure("Closing the pointer renderer pipeline left live animation work")
        }
    }

    private static func sample(seconds: Double, x: Double, y: Double = 0) -> PointerSample {
        PointerSample(timestamp: MonotonicTimestamp(seconds: seconds)!, location: PointerPoint(x: x, y: y)!)
    }

    private static func measureAdaptiveSampler() async throws -> Int {
        var reads = 0
        for _ in 0..<10 {
            _ = NSEvent.mouseLocation
            reads += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        guard reads == 10 else { throw PointerValidationFailure("Adaptive sampler lost its bounded reads") }
        return reads
    }
}

@MainActor
private final class FakePointerSource: PointerObserving {
    var onSample: ((PointerSample) -> Void)?
    private(set) var counters = PointerSourceCounters()
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(cadence: PointerCadence) { startCount += 1 }
    func setCadence(_ cadence: PointerCadence) {}
    func stop() { stopCount += 1 }

    func emit(_ sample: PointerSample) {
        counters.receivedEventCount &+= 1
        counters.deliveredSampleCount &+= 1
        onSample?(sample)
    }
}

@MainActor
private final class FakeDeadlineScheduler: DeadlineScheduling {
    private var entries: [DeadlineSlot: (MonotonicTimestamp, @MainActor @Sendable () -> Void)] = [:]

    var isEmpty: Bool { entries.isEmpty }

    func schedule(_ slot: DeadlineSlot, at: MonotonicTimestamp, action: @escaping @MainActor @Sendable () -> Void) {
        entries[slot] = (at, action)
    }

    func cancel(_ slot: DeadlineSlot) { entries.removeValue(forKey: slot) }
    func cancelAll() { entries.removeAll() }
    func deadline(for slot: DeadlineSlot) -> MonotonicTimestamp? { entries[slot]?.0 }

    func fire(_ slot: DeadlineSlot) {
        guard let (_, action) = entries.removeValue(forKey: slot) else { return }
        action()
    }
}

@MainActor
private final class FakeClock {
    var timestamp: MonotonicTimestamp
    init(timestamp: MonotonicTimestamp) { self.timestamp = timestamp }
}

private struct PointerSourceReport: Encodable {
    let sourceCadenceHertz: Int
    let syntheticMonitorEvents: UInt64
    let syntheticCoalescedSamples: UInt64
    let adaptiveSamplerHertz: Int
    let adaptiveSamplerReads: Int
    let physicalMonitorEvents: UInt64
    let physicalCoalescedSamples: UInt64
    let physicalLocalEvents: UInt64
    let physicalGlobalEvents: UInt64
    let physicalMonitorEvidence: String
}

@MainActor
private final class LivePointerPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private unowned let source: AppKitPointerSource

    init(source: AppKitPointerSource) {
        self.source = source
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "Spriglet pointer acceptance"
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        label = NSTextField(wrappingLabelWithString: "")
        label.frame = NSRect(x: 24, y: 24, width: 372, height: 120)
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        panel.contentView?.addSubview(label)
        panel.center()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func update(counters: PointerSourceCounters, remainingSeconds: Double) {
        label.stringValue = "Drag this blank panel, then drag another app window.\n\n"
            + "Local events:  \(counters.localEventCount)\n"
            + "Global events: \(counters.globalEventCount)\n"
            + "Delivered:     \(counters.deliveredSampleCount)\n\n"
            + String(format: "Closes automatically in %.1f seconds", remainingSeconds)
    }

    func close() {
        _ = source.counters
        panel.close()
    }
}

private struct PointerValidationFailure: LocalizedError {
    let errorDescription: String?

    init(_ errorDescription: String) {
        self.errorDescription = errorDescription
    }
}
