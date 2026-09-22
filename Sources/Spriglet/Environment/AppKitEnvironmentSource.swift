import AppKit
import Foundation
import SprigletCore

/// A small platform boundary for the environmental facts that affect the pet's
/// resource policy. The values deliberately exclude AppKit objects so they can
/// cross into a reducer without retaining platform state.
struct EnvironmentSnapshot: Equatable, Sendable {
    let lowPower: Bool
    let reduceMotion: Bool
    let thermalPressure: EnvironmentThermalPressure
}

/// The process thermal state expressed as a value that is safe to pass beyond
/// the AppKit and Foundation observation boundary.
enum EnvironmentThermalPressure: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    /// Unknown future platform states take the conservative resource policy.
    var requiresRest: Bool {
        switch self {
        case .serious, .critical, .unknown:
            true
        case .nominal, .fair:
            false
        }
    }
}

/// A lifecycle state that prevents active rendering or movement work.
enum EnvironmentSuspensionReason: Equatable, Sendable {
    case displayAsleep
    case systemAsleep
    case sessionInactive
}

/// A semantic change produced by an environment source.
enum EnvironmentEvent: Equatable, Sendable {
    case activeSpaceChanged
    case suspension(reason: EnvironmentSuspensionReason, active: Bool)
    case policyChanged(EnvironmentSnapshot)
    case context(GenericContextStimulus)
}

/// The lifecycle contract for platform environment sources.
///
/// A source is started and stopped with the runtime. A lifecycle source stays
/// started while the pet is suspended so that sleep, wake, and session events
/// can restore the runtime. Later high-frequency sources can use a separate
/// active-work lifecycle without losing those wake events.
@MainActor
protocol EnvironmentObserving: AnyObject {
    var onEvent: ((EnvironmentEvent) -> Void)? { get set }

    func start()
    func stop()
    func currentSnapshot() -> EnvironmentSnapshot
}

/// Observes the current macOS resource and workspace lifecycle policy with
/// typed NotificationCenter messages.
@MainActor
final class AppKitEnvironmentSource: EnvironmentObserving {
    var onEvent: ((EnvironmentEvent) -> Void)?

    private let workspace: NSWorkspace
    private let workspaceNotificationCenter: NotificationCenter
    private let processInfo: ProcessInfo
    private let defaultNotificationCenter: NotificationCenter
    private var observationTokens: [NotificationCenter.ObservationToken] = []
    private var lifecycleGeneration: UInt64 = 0
    private var isRunning = false

    init(
        workspace: NSWorkspace = .shared,
        processInfo: ProcessInfo = .processInfo,
        defaultNotificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter? = nil
    ) {
        self.workspace = workspace
        self.workspaceNotificationCenter = workspaceNotificationCenter ?? workspace.notificationCenter
        self.processInfo = processInfo
        self.defaultNotificationCenter = defaultNotificationCenter
    }

    func start() {
        guard !isRunning else { return }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isRunning = true

        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.ActiveSpaceDidChangeMessage.self
        ) { [weak self] _ in
            await self?.emit(.activeSpaceChanged, generation: generation)
            await self?.emit(.context(.spaceChanged), generation: generation)
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.ScreensDidSleepMessage.self
        ) { [weak self] _ in
            await self?.emit(
                .suspension(reason: .displayAsleep, active: true),
                generation: generation
            )
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.ScreensDidWakeMessage.self
        ) { [weak self] _ in
            await self?.emit(
                .suspension(reason: .displayAsleep, active: false),
                generation: generation
            )
            await self?.emit(.context(.displayWoke), generation: generation)
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.WillSleepMessage.self
        ) { [weak self] _ in
            self?.emit(
                .suspension(reason: .systemAsleep, active: true),
                generation: generation
            )
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.DidWakeMessage.self
        ) { [weak self] _ in
            self?.emit(
                .suspension(reason: .systemAsleep, active: false),
                generation: generation
            )
            self?.emit(.context(.displayWoke), generation: generation)
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.SessionDidResignActiveMessage.self
        ) { [weak self] _ in
            self?.emit(
                .suspension(reason: .sessionInactive, active: true),
                generation: generation
            )
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.SessionDidBecomeActiveMessage.self
        ) { [weak self] _ in
            self?.emit(
                .suspension(reason: .sessionInactive, active: false),
                generation: generation
            )
            self?.emit(.context(.sessionActivated), generation: generation)
        })
        observationTokens.append(workspaceNotificationCenter.addObserver(
            of: workspace,
            for: NSWorkspace.AccessibilityDisplayOptionsDidChangeMessage.self
        ) { [weak self] _ in
            self?.emitPolicyChanged(generation: generation)
        })
        observationTokens.append(defaultNotificationCenter.addObserver(
            of: processInfo,
            for: ProcessInfo.PowerStateDidChangeMessage.self
        ) { [weak self] _ in
            await self?.emitPolicyChanged(generation: generation)
        })
        observationTokens.append(defaultNotificationCenter.addObserver(
            of: processInfo,
            for: ProcessInfo.ThermalStateDidChangeMessage.self
        ) { [weak self] _ in
            await self?.emitPolicyChanged(generation: generation)
        })
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false
        lifecycleGeneration &+= 1
        observationTokens.removeAll()
    }

    func currentSnapshot() -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            lowPower: processInfo.isLowPowerModeEnabled,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            thermalPressure: EnvironmentThermalPressure(processInfo.thermalState)
        )
    }

    private func emitPolicyChanged(generation: UInt64) {
        emit(.policyChanged(currentSnapshot()), generation: generation)
    }

    private func emit(_ event: EnvironmentEvent, generation: UInt64) {
        guard isRunning, generation == lifecycleGeneration else { return }
        onEvent?(event)
    }
}

private extension EnvironmentThermalPressure {
    init(_ thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .unknown
        }
    }
}
