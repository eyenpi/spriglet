import AppKit
import Foundation
import SprigletCore

/// The maximum semantic pointer delivery rate. The source has no idle timer:
/// it wakes only after a matching mouse movement or drag event arrives.
enum PointerCadence: Equatable, Sendable {
    case normal
    case lowPower

    var maximumHertz: Int {
        switch self {
        case .normal: 15
        case .lowPower: 10
        }
    }

    fileprivate var interval: Duration {
        // Round upward so the normal cadence never exceeds its 15 Hz budget.
        switch self {
        case .normal: .milliseconds(67)
        case .lowPower: .milliseconds(100)
        }
    }
}

/// Diagnostics that intentionally omit pointer coordinates and event contents.
struct PointerSourceCounters: Equatable, Sendable {
    var receivedEventCount: UInt64 = 0
    var deliveredSampleCount: UInt64 = 0
    var localEventCount: UInt64 = 0
    var globalEventCount: UInt64 = 0
}

/// A lifecycle boundary for ephemeral pointer observations.
@MainActor
protocol PointerObserving: AnyObject {
    var onSample: ((PointerSample) -> Void)? { get set }
    var counters: PointerSourceCounters { get }

    func start(cadence: PointerCadence)
    func setCadence(_ cadence: PointerCadence)
    func stop()
}

/// Uses AppKit's local and global mouse movement monitors. It never registers
/// for keys, clicks, scrolling, or clipboard events, and it retains no point
/// after stop.
@MainActor
final class AppKitPointerSource: PointerObserving {
    var onSample: ((PointerSample) -> Void)?
    private(set) var counters = PointerSourceCounters()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var coalescer: PointerCoalescer?
    private var lifecycleGeneration: UInt64 = 0
    private var isRunning = false

    isolated deinit {
        stop()
    }

    func start(cadence: PointerCadence = .normal) {
        guard !isRunning else {
            setCadence(cadence)
            return
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isRunning = true
        let coalescer = PointerCoalescer(cadence: cadence)
        coalescer.onSample = { [weak self] sample in
            guard let self, self.isRunning, self.lifecycleGeneration == generation else { return }
            if self.counters.deliveredSampleCount < .max {
                self.counters.deliveredSampleCount += 1
            }
            self.onSample?(sample)
        }
        self.coalescer = coalescer

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.pointerEventMask) { [weak self] _ in
            self?.captureCurrentPointer(generation: generation, origin: .global)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.pointerEventMask) { [weak self] event in
            self?.captureCurrentPointer(generation: generation, origin: .local)
            return event
        }
    }

    func setCadence(_ cadence: PointerCadence) {
        coalescer?.setCadence(cadence)
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false
        lifecycleGeneration &+= 1
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        coalescer?.stop()
        coalescer = nil
    }

    private func captureCurrentPointer(generation: UInt64, origin: MonitorOrigin) {
        let mouseLocation = NSEvent.mouseLocation
        guard isRunning, lifecycleGeneration == generation,
              let location = PointerPoint(x: Double(mouseLocation.x), y: Double(mouseLocation.y)),
              let timestamp = MonotonicTimestamp(seconds: ProcessInfo.processInfo.systemUptime)
        else { return }

        if counters.receivedEventCount < .max {
            counters.receivedEventCount += 1
        }
        switch origin {
        case .local:
            if counters.localEventCount < .max { counters.localEventCount += 1 }
        case .global:
            if counters.globalEventCount < .max { counters.globalEventCount += 1 }
        }
        coalescer?.submit(PointerSample(timestamp: timestamp, location: location))
    }

    private enum MonitorOrigin {
        case local
        case global
    }

    private static let pointerEventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged
    ]
}

/// Latest-value coalescing for an event source. It has one pending wake at most,
/// schedules it only after an input event, and clears the point on stop.
@MainActor
final class PointerCoalescer {
    var onSample: ((PointerSample) -> Void)?
    private(set) var counters = PointerSourceCounters()

    private var latestSample: PointerSample?
    private var wakeTask: Task<Void, Never>?
    private var cadence: PointerCadence
    private var generation: UInt64 = 0
    private var isRunning = true

    isolated deinit {
        stop()
    }

    init(cadence: PointerCadence) {
        self.cadence = cadence
    }

    func submit(_ sample: PointerSample) {
        guard isRunning else { return }
        counters.receivedEventCount &+= 1
        latestSample = sample
        scheduleWakeIfNeeded()
    }

    func setCadence(_ cadence: PointerCadence) {
        guard self.cadence != cadence else { return }
        self.cadence = cadence
        generation &+= 1
        wakeTask?.cancel()
        wakeTask = nil
        scheduleWakeIfNeeded()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        wakeTask?.cancel()
        wakeTask = nil
        latestSample = nil
        onSample = nil
    }

    private func scheduleWakeIfNeeded() {
        guard isRunning, latestSample != nil, wakeTask == nil else { return }
        let generation = generation
        let interval = cadence.interval
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.deliver(generation: generation)
        }
    }

    private func deliver(generation: UInt64) {
        guard isRunning, self.generation == generation, let latestSample else { return }
        wakeTask = nil
        self.latestSample = nil
        counters.deliveredSampleCount &+= 1
        onSample?(latestSample)
    }
}
