import AppKit
import Foundation

/// A sleep-only movement wake boundary. It never asks AppKit for a pointer
/// location and it never receives clicks, keys, scrolling, or gestures.
@MainActor
protocol WakeMovementObserving: AnyObject {
    var onWakeMovement: (() -> Void)? { get set }

    func start()
    func stop()
}

/// Installs local and global movement/drag monitors only while a visible pet is
/// asleep and otherwise permitted to wake. The first movement emits one generic
/// signal and synchronously removes both monitors before calling its observer.
@MainActor
final class WakeMovementSource: WakeMovementObserving {
    var onWakeMovement: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var shouldRun = false
    private var isDelivering = false

    isolated deinit { stop() }

    func start() {
        shouldRun = true
        installMonitorsIfNeeded()
    }

    func stop() {
        shouldRun = false
        removeMonitors()
    }

    private func installMonitorsIfNeeded() {
        // A stale aggregate-idle read may request another one-shot monitor from
        // inside the current local monitor callback. Wait until that callback
        // has unwound so the same NSEvent cannot trigger the replacement.
        guard shouldRun, !isRunning, !isDelivering else { return }

        generation &+= 1
        let generation = generation
        isRunning = true
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.movementMask) { [weak self] _ in
            self?.trigger(generation: generation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.movementMask) { [weak self] event in
            self?.trigger(generation: generation)
            return event
        }
    }

    private func removeMonitors() {
        guard isRunning else { return }

        isRunning = false
        generation &+= 1
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func trigger(generation: UInt64) {
        guard isRunning, generation == self.generation else { return }
        shouldRun = false
        removeMonitors()
        isDelivering = true
        onWakeMovement?()
        isDelivering = false
        installMonitorsIfNeeded()
    }

    private static let movementMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]
}
