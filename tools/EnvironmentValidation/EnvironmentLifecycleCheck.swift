import AppKit
import Foundation

@main
@MainActor
struct EnvironmentLifecycleCheck {
    static func main() async {
        do {
            try await verifyLifecycle()
            print("Environment lifecycle validation passed")
        } catch {
            fputs("Environment lifecycle validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verifyLifecycle() async throws {
        let workspace = NSWorkspace.shared
        let workspaceCenter = NotificationCenter()
        let processCenter = NotificationCenter()
        let source = AppKitEnvironmentSource(
            workspace: workspace,
            defaultNotificationCenter: processCenter,
            workspaceNotificationCenter: workspaceCenter
        )
        let recorder = EventRecorder()
        source.onEvent = { recorder.record($0) }

        try require(source.currentSnapshot().thermalPressure != .unknown,
                    "The installed SDK exposes a known thermal state")

        source.start()
        source.start()
        workspaceCenter.post(NSWorkspace.DidWakeMessage(), subject: workspace)
        try require(recorder.events == [.suspension(reason: .systemAsleep, active: false)],
                    "Starting twice must retain one synchronous typed observer")

        let activeSpaceDelivery = try await recorder.waitForNextEvent {
            workspaceCenter.post(NSWorkspace.ActiveSpaceDidChangeMessage(), subject: workspace)
        }
        try require(activeSpaceDelivery == .activeSpaceChanged,
                    "An async typed workspace message must reach the source")

        let powerDelivery = try await recorder.waitForNextEvent {
            processCenter.post(ProcessInfo.PowerStateDidChangeMessage(), subject: .processInfo)
        }
        guard case .policyChanged(let snapshot) = powerDelivery else {
            throw ValidationFailure("A power message must refresh the immutable policy snapshot")
        }
        try require(snapshot == source.currentSnapshot(),
                    "The power event must contain the source's current snapshot")

        source.stop()
        workspaceCenter.post(NSWorkspace.DidWakeMessage(), subject: workspace)
        processCenter.post(ProcessInfo.PowerStateDidChangeMessage(), subject: .processInfo)
        await Task.yield()
        try require(recorder.events.count == 3,
                    "No synchronous or queued asynchronous message may escape after stop")

        source.start()
        workspaceCenter.post(NSWorkspace.ActiveSpaceDidChangeMessage(), subject: workspace)
        source.stop()
        source.start()
        let restartDelivery = try await recorder.waitForNextEvent {
            workspaceCenter.post(NSWorkspace.ScreensDidWakeMessage(), subject: workspace)
        }
        try require(restartDelivery == .suspension(reason: .displayAsleep, active: false),
                    "A restarted source must observe the current lifecycle generation")

        await Task.yield()
        try require(recorder.events.count == 4,
                    "A callback queued before stop must not escape into a restarted generation")
        source.stop()
        await Task.yield()
        try require(recorder.events.count == 4,
                    "Stopping a restarted source must again silence all callbacks")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ValidationFailure(message) }
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [EnvironmentEvent] = []
    private var nextEventWaiter: CheckedContinuation<EnvironmentEvent, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func record(_ event: EnvironmentEvent) {
        events.append(event)
        timeoutTask?.cancel()
        timeoutTask = nil
        nextEventWaiter?.resume(returning: event)
        nextEventWaiter = nil
    }

    func waitForNextEvent(while triggering: () -> Void) async throws -> EnvironmentEvent {
        try await withCheckedThrowingContinuation { continuation in
            precondition(nextEventWaiter == nil, "Only one event expectation may be pending")
            nextEventWaiter = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.timeOutNextEvent()
            }
            triggering()
        }
    }

    private func timeOutNextEvent() {
        guard let nextEventWaiter else { return }
        self.nextEventWaiter = nil
        timeoutTask = nil
        nextEventWaiter.resume(throwing: ValidationFailure("Timed out waiting for a typed notification"))
    }
}

private struct ValidationFailure: LocalizedError {
    let errorDescription: String?

    init(_ errorDescription: String) {
        self.errorDescription = errorDescription
    }
}
