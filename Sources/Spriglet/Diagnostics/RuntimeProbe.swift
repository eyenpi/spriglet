import AppKit
import Foundation
import OSLog
import SprigletCore

struct ProbeMeasurement: Codable {
    let state: String
    let startedAt: Date
    let seconds: Double
    let sceneUpdateDelta: UInt64
    let renderCallbackDelta: UInt64
    let movementTickDelta: UInt64
    let automaticActionDelta: UInt64
    let appActiveAtStart: Bool
    let appActiveAtEnd: Bool
    let cpuPercentOfOneCore: Double
    let footprintMiB: Double?
}

enum ProbeOutcome: String, Codable {
    case passed, failed, blocked
}

struct ProbeCheck: Codable {
    let name: String
    let outcome: ProbeOutcome
    let detail: String

    init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.outcome = passed ? .passed : .failed
        self.detail = detail
    }

    init(blocked detail: String) {
        name = "motion-policy"
        outcome = .blocked
        self.detail = detail
    }
}

struct ProbeReport: Codable {
    let recordedAt: Date
    let os: String
    let measurements: [ProbeMeasurement]
    let checks: [ProbeCheck]
    let limitations: [String]
    let outcome: ProbeOutcome

    init(recordedAt: Date, os: String, measurements: [ProbeMeasurement], checks: [ProbeCheck], limitations: [String]) {
        self.recordedAt = recordedAt
        self.os = os
        self.measurements = measurements
        self.checks = checks
        self.limitations = limitations
        outcome = checks.contains { $0.outcome == .failed } ? .failed :
            (checks.contains { $0.outcome == .blocked } ? .blocked : .passed)
    }

    var passed: Bool { outcome == .passed }
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self), let output = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Could not encode probe report\"}"
        }
        return output
    }
}

@MainActor
enum RuntimeProbe {
    private static let signposter = OSSignposter(subsystem: "dev.spriglet.prototype", category: "probe")

    static func run(runtime: PetRuntime) async throws -> ProbeReport {
        let originalPreferences = PetPreferences(
            isHidden: runtime.isHidden, isPaused: runtime.isPaused,
            clickThrough: runtime.clickThrough, allSpaces: runtime.allSpaces,
            autonomousBehavior: runtime.autonomousBehavior
        )
        defer {
            runtime.restoreAfterProbe(originalPreferences)
        }
        var measurements: [ProbeMeasurement] = []
        var checks: [ProbeCheck] = []

        @MainActor func makeReport(blockedDuring phase: String? = nil) -> ProbeReport {
            var reportChecks = checks
            if let phase {
                reportChecks.append(.init(blocked: "Visibility, Reduce Motion, or system power/session policy prevented or interrupted \(phase). No system preference was changed."))
            }
            return ProbeReport(recordedAt: .now, os: ProcessInfo.processInfo.operatingSystemVersionString,
                               measurements: measurements, checks: reportChecks,
                               limitations: ["Short smoke measurements, not energy/battery benchmarks or an eight-hour soak.",
                                             "Scene updates are not actual GPU submissions; use Instruments for renderer and WindowServer costs.",
                                             "Motion eligibility and app activity are sampled at phase boundaries; temporary changes between samples may be missed.",
                                             "Physical mouse routing, focus during another app's typing, full-screen, Spaces, Stage Manager and multiple displays require separate validation.",
                                             "Procedural character does not predict the footprint of production sprite atlases."])
        }

        runtime.setHidden(false)
        runtime.setPaused(false)
        runtime.setClickThrough(true)
        runtime.renderer.resetPose()
        try await Task.sleep(for: .seconds(2))
        guard runtime.permitsMotion else {
            return makeReport(blockedDuring: "initial warm-up")
        }

        checks.append(.init(name: "initial-scene-updated", passed: runtime.renderer.sceneUpdateCount > 0,
                            detail: "The initial pose must complete a scene update before zero idle callbacks can pass. This is not a GPU-output assertion."))
        let idle = try await measure("static-visible", runtime: runtime, seconds: 3)
        measurements.append(idle)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "static-visible") }
        checks.append(.init(name: "static-scene-stops", passed: idle.sceneUpdateDelta == 0 && idle.renderCallbackDelta == 0 && idle.movementTickDelta == 0,
                            detail: "Scene/render callbacks and movement clock during static pose; not GPU submissions."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-reaction") }
        runtime.play()
        let active = try await measure("finite-reaction", runtime: runtime, seconds: 3)
        measurements.append(active)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-reaction") }
        checks.append(.init(name: "reaction-runs-and-finishes", passed: active.sceneUpdateDelta > 0 && !runtime.renderer.isAnimating,
                            detail: "Requires visible app and system motion policy permitting animation."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "settled-visible") }
        let settled = try await measure("settled-visible", runtime: runtime, seconds: 3)
        measurements.append(settled)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "settled-visible") }
        checks.append(.init(name: "finished-scene-stops", passed: settled.sceneUpdateDelta == 0 && settled.renderCallbackDelta == 0,
                            detail: "A finite reaction must return to an idle scene without an update loop."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-window-movement") }
        let walkStart = runtime.desktop.panel.frame.origin
        runtime.walk()
        let walking = try await measure("finite-window-movement", runtime: runtime, seconds: 3.5)
        measurements.append(walking)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-window-movement") }
        checks.append(.init(name: "movement-runs-and-finishes", passed: walking.movementTickDelta > 0 && runtime.desktop.panel.frame.origin != walkStart && !runtime.desktop.isMoving,
                            detail: "A finite desktop movement changes position and releases its display link."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "pause preparation") }
        let updatesBeforePausePreparation = runtime.renderer.sceneUpdateCount
        runtime.play()
        runtime.walk()
        try await Task.sleep(for: .milliseconds(250))
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "pause preparation") }
        let wasAnimatingBeforePause = runtime.renderer.isAnimating
            && runtime.renderer.sceneUpdateCount > updatesBeforePausePreparation
        let wasMovingBeforePause = runtime.desktop.isMoving
        runtime.setPaused(true)
        let pausedOrigin = runtime.desktop.panel.frame.origin
        let paused = try await measure("paused", runtime: runtime, seconds: 3)
        measurements.append(paused)
        runtime.play()
        checks.append(.init(name: "pause-stops-work", passed: wasAnimatingBeforePause && wasMovingBeforePause && paused.sceneUpdateDelta == 0 && paused.renderCallbackDelta == 0 && paused.movementTickDelta == 0 && !runtime.desktop.isMoving && runtime.desktop.panel.frame.origin == pausedOrigin && !runtime.renderer.isAnimating,
                            detail: "Pause must interrupt a rendering reaction and window movement, stop their callbacks, and reject new animation."))

        runtime.setHidden(true)
        runtime.setPaused(false)
        let hidden = try await measure("hidden", runtime: runtime, seconds: 3)
        measurements.append(hidden)
        checks.append(.init(name: "hidden-stops-work", passed: hidden.sceneUpdateDelta == 0 && hidden.renderCallbackDelta == 0 && hidden.movementTickDelta == 0 && !runtime.desktop.panel.isVisible && !runtime.renderer.isAnimating,
                            detail: "Clearing pause while hidden must not restart the renderer."))

        runtime.setHidden(false)
        runtime.setClickThrough(true)
        checks.append(.init(name: "whole-window-click-through-configured", passed: runtime.desktop.panel.ignoresMouseEvents,
                            detail: "Checks NSWindow configuration only; an external mouse click is still required."))
        checks.append(.init(name: "pet-cannot-become-key", passed: !runtime.desktop.panel.canBecomeKey && !runtime.desktop.panel.isKeyWindow,
                            detail: "Checks window focus eligibility; manual typing in another app is still required."))

        try await Task.sleep(for: .milliseconds(250))
        for action in [PetAction.blink, .lookAround, .stretch] {
            guard runtime.permitsMotion else { return makeReport(blockedDuring: action.rawValue) }
            runtime.preview(action)
            let clip = try await measure(action.rawValue, runtime: runtime, seconds: 3)
            measurements.append(clip)
            guard runtime.permitsMotion else { return makeReport(blockedDuring: action.rawValue) }
            checks.append(.init(name: "\(action.rawValue)-runs-and-settles",
                                passed: clip.sceneUpdateDelta > 0 && !runtime.renderer.isAnimating && !runtime.renderer.isSleeping,
                                detail: "An authored awake clip runs once and returns to a settled awake pose."))
        }

        runtime.preview(.fallAsleep)
        let napEntry = try await measure("fall-asleep", runtime: runtime, seconds: 3)
        measurements.append(napEntry)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "fall-asleep") }
        checks.append(.init(name: "nap-settles-asleep", passed: napEntry.sceneUpdateDelta > 0 && runtime.renderer.isSleeping && runtime.isSleeping && !runtime.renderer.isAnimating,
                            detail: "The nap pose stays asleep after its finite transition, with synchronized runtime state."))
        let nap = try await measure("static-nap", runtime: runtime, seconds: 1)
        measurements.append(nap)
        checks.append(.init(name: "nap-stops-rendering", passed: nap.sceneUpdateDelta == 0 && nap.renderCallbackDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "A nap is a static pose; ordinary autonomous deadlines remain disabled during this probe."))

        runtime.play()
        let wake = try await measure("wake-and-react", runtime: runtime, seconds: 3)
        measurements.append(wake)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "wake-and-react") }
        checks.append(.init(name: "interaction-wakes-pet", passed: wake.sceneUpdateDelta > 0 && !runtime.renderer.isSleeping && !runtime.isSleeping && !runtime.renderer.isAnimating,
                            detail: "User interaction authors a wake transition before its reaction."))

        runtime.preview(.lookAround)
        try await Task.sleep(for: .milliseconds(100))
        runtime.play()
        runtime.play()
        let preservedAction = runtime.renderer.currentAction == .lookAround
        let queued = try await measure("queued-reaction", runtime: runtime, seconds: 4)
        measurements.append(queued)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "queued-reaction") }
        checks.append(.init(name: "interaction-waits-for-clip-boundary", passed: preservedAction && queued.sceneUpdateDelta > 0 && !runtime.renderer.isAnimating,
                            detail: "Repeated reactions coalesce after the current look clip instead of snapping its pose."))

        runtime.setAutonomousBehavior(true)
        runtime.scheduleOneBehaviorForProbe(.init(action: .lookAround, delaySeconds: 0.4))
        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.2))
        let hadDeadline = runtime.hasScheduledBehavior
        let scheduled = try await measure("scheduled-blink", runtime: runtime, seconds: 2)
        measurements.append(scheduled)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "scheduled-blink") }
        checks.append(.init(name: "replacement-deadline-fires-once", passed: hadDeadline && scheduled.automaticActionDelta == 1 && scheduled.sceneUpdateDelta > 0 && !runtime.renderer.isAnimating && !runtime.hasScheduledBehavior,
                            detail: "Replacing a pending deadline yields exactly one finite automatic action; no polling loop is installed."))

        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.3))
        let hadPauseDeadline = runtime.hasScheduledBehavior
        runtime.setPaused(true)
        let cancelled = try await measure("cancelled-by-pause", runtime: runtime, seconds: 0.7)
        measurements.append(cancelled)
        checks.append(.init(name: "pause-cancels-pending-behavior", passed: hadPauseDeadline && cancelled.automaticActionDelta == 0 && cancelled.sceneUpdateDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "Pause cancels the deadline before it can start an action."))
        runtime.setPaused(false)
        try await Task.sleep(for: .milliseconds(250))

        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.3))
        let hadHiddenDeadline = runtime.hasScheduledBehavior
        runtime.setHidden(true)
        let hiddenDeadline = try await measure("cancelled-by-hide", runtime: runtime, seconds: 0.7)
        measurements.append(hiddenDeadline)
        checks.append(.init(name: "hide-cancels-pending-behavior", passed: hadHiddenDeadline && hiddenDeadline.automaticActionDelta == 0 && hiddenDeadline.sceneUpdateDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "Hiding the pet cancels its resting deadline."))
        runtime.setHidden(false)
        try await Task.sleep(for: .milliseconds(250))

        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.3))
        let hadDisabledDeadline = runtime.hasScheduledBehavior
        runtime.setAutonomousBehavior(false)
        let disabled = try await measure("cancelled-by-preference", runtime: runtime, seconds: 0.7)
        measurements.append(disabled)
        checks.append(.init(name: "preference-cancels-pending-behavior", passed: hadDisabledDeadline && disabled.automaticActionDelta == 0 && disabled.sceneUpdateDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "Turning quiet behavior off cancels its pending deadline."))

        let finalRest = try await measure("final-settled", runtime: runtime, seconds: 10)
        measurements.append(finalRest)
        checks.append(.init(name: "completed-checks-stay-settled", passed: finalRest.sceneUpdateDelta == 0 && finalRest.renderCallbackDelta == 0 && finalRest.automaticActionDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "A longer final resting interval records footprint after the transitions and confirms no continuing work."))

        return makeReport()
    }

    private static func measure(_ state: String, runtime: PetRuntime, seconds: Double) async throws -> ProbeMeasurement {
        let startedAt = Date.now
        let appActiveAtStart = NSApp.isActive
        let interval = signposter.beginInterval("Probe Phase", id: signposter.makeSignpostID(), "\(state, privacy: .public)")
        defer { signposter.endInterval("Probe Phase", interval) }
        let updates = runtime.renderer.sceneUpdateCount
        let callbacks = runtime.renderer.viewRenderCallbackCount
        let ticks = runtime.desktop.movementTickCount
        let automaticActions = runtime.automaticActionCount
        let before = ProcessSample.capture()
        try await Task.sleep(for: .seconds(seconds))
        let after = ProcessSample.capture()
        let elapsed = after.uptime - before.uptime
        return .init(state: state, startedAt: startedAt, seconds: elapsed,
                     sceneUpdateDelta: runtime.renderer.sceneUpdateCount - updates,
                     renderCallbackDelta: runtime.renderer.viewRenderCallbackCount - callbacks,
                     movementTickDelta: runtime.desktop.movementTickCount - ticks,
                     automaticActionDelta: runtime.automaticActionCount - automaticActions,
                     appActiveAtStart: appActiveAtStart,
                     appActiveAtEnd: NSApp.isActive,
                     cpuPercentOfOneCore: elapsed > 0 ? (after.cpuSeconds - before.cpuSeconds) / elapsed * 100 : 0,
                     footprintMiB: after.footprintBytes.map { Double($0) / 1_048_576 })
    }
}
