import AppKit
import Foundation
import OSLog
import SprigletCore

struct ProbeMeasurement: Codable {
    let state: String
    let startedAt: Date
    let seconds: Double
    let submittedFrameDelta: UInt64
    let displayLinkCallbackDelta: UInt64
    let movementFrameDelta: UInt64
    let automaticActionDelta: UInt64
    let finitePhraseDelta: UInt64
    let proceduralCommitDelta: UInt64
    let decodedLayerBytes: Int
    let pointerEventDelta: UInt64
    let pointerSampleDelta: UInt64
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
        let originalPreferences = runtime.snapshotPreferencesForProbe()
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
                                             "Layer content assignments and display-link callbacks do not prove compositor presentation or GPU submissions; use Instruments for those costs.",
                                             "Motion eligibility and app activity are sampled at phase boundaries; temporary changes between samples may be missed.",
                                             "Physical mouse routing, focus during another app's typing, full-screen, Spaces, Stage Manager and multiple displays require separate validation.",
                                             "Measurements cover the bundled character, bounded image decoder, and finite retained-layer phrases."])
        }

        runtime.setHidden(false)
        runtime.setPaused(false)
        runtime.setClickThrough(true)
        runtime.renderer.resetPose()
        try await Task.sleep(for: .seconds(2))
        guard runtime.permitsMotion else {
            return makeReport(blockedDuring: "initial warm-up")
        }

        checks.append(.init(name: "initial-pose-present", passed: runtime.renderer.submittedFrameCount > 0
                            || (runtime.renderer.isRestRigVisible && runtime.renderer.decodedLayerBytes > 0),
                            detail: "The initial pose must have a baked image or visible loaded rig before zero idle callbacks can pass. This is not a GPU-output assertion."))
        let idle = try await measure("static-visible", runtime: runtime, seconds: 3)
        measurements.append(idle)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "static-visible") }
        checks.append(.init(name: "static-frame-clock-stops", passed: idle.submittedFrameDelta == 0 && idle.displayLinkCallbackDelta == 0 && idle.movementFrameDelta == 0,
                            detail: "Layer assignments/display-link callbacks and movement clock during static pose; not GPU submissions."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-reaction") }
        let reactionWait = max(3, runtime.renderer.actionDuration(.react) + 0.75)
        runtime.play()
        let active = try await measure("finite-reaction", runtime: runtime, seconds: reactionWait)
        measurements.append(active)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-reaction") }
        checks.append(.init(name: "reaction-runs-and-finishes", passed: active.submittedFrameDelta > 0 && !runtime.renderer.isAnimating,
                            detail: "Requires visible app and system motion policy permitting animation."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "settled-visible") }
        let settled = try await measure("settled-visible", runtime: runtime, seconds: 3)
        measurements.append(settled)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "settled-visible") }
        checks.append(.init(name: "finished-frame-clock-stops", passed: settled.submittedFrameDelta == 0 && settled.displayLinkCallbackDelta == 0,
                            detail: "A finite reaction must return to a static pose without a display link."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-window-movement") }
        let walkStart = runtime.desktop.panel.frame.origin
        runtime.walk()
        let walking = try await measure("finite-window-movement", runtime: runtime,
                                        seconds: max(4, runtime.renderer.walkDuration + 0.75))
        measurements.append(walking)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "finite-window-movement") }
        checks.append(.init(name: "movement-runs-and-finishes", passed: walking.movementFrameDelta > 0 && runtime.desktop.panel.frame.origin != walkStart && !runtime.desktop.isMoving,
                            detail: "A finite authored walk changes position and releases its shared pose/movement clock."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "complete-character-sample") }
        let sampleStart = runtime.desktop.panel.frame.origin
        runtime.characterSample()
        let sample = try await measure("complete-character-sample", runtime: runtime,
                                      seconds: runtime.renderer.sampleDuration + 1)
        measurements.append(sample)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "complete-character-sample") }
        checks.append(.init(name: "complete-sample-runs-and-settles",
                            passed: sample.submittedFrameDelta > 0 && sample.movementFrameDelta > 0
                                && runtime.desktop.panel.frame.origin != sampleStart
                                && runtime.renderer.currentSnapshot?.clip == .settle
                                && runtime.renderer.currentSnapshot?.isComplete == true
                                && !runtime.renderer.isAnimating && !runtime.desktop.isMoving
                                && !runtime.renderer.hasActiveDisplayLink,
                            detail: "The app's Play Character Sample command completes idle, walk, pet, and settle with window travel and no remaining frame clock."))

        guard runtime.permitsMotion else { return makeReport(blockedDuring: "pause preparation") }
        let updatesBeforePausePreparation = runtime.renderer.submittedFrameCount
        let pauseWalkStart = runtime.desktop.panel.frame.origin
        runtime.walk()
        let movementDeadline = ProcessInfo.processInfo.systemUptime + 2
        while runtime.renderer.isAnimating,
              runtime.desktop.panel.frame.origin == pauseWalkStart,
              ProcessInfo.processInfo.systemUptime < movementDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "pause preparation") }
        let wasAnimatingBeforePause = runtime.renderer.isAnimating
            && runtime.renderer.submittedFrameCount > updatesBeforePausePreparation
        let wasMovingBeforePause = runtime.desktop.isMoving
        runtime.setPaused(true)
        let pausedOrigin = runtime.desktop.panel.frame.origin
        let paused = try await measure("paused", runtime: runtime, seconds: 3)
        measurements.append(paused)
        runtime.play()
        checks.append(.init(name: "pause-stops-work", passed: wasAnimatingBeforePause && wasMovingBeforePause && paused.submittedFrameDelta == 0 && paused.displayLinkCallbackDelta == 0 && paused.movementFrameDelta == 0 && !runtime.desktop.isMoving && runtime.desktop.panel.frame.origin == pausedOrigin && !runtime.renderer.isAnimating,
                            detail: "Pause must interrupt an authored walk, stop both pose and movement callbacks, and reject new animation."))

        runtime.setHidden(true)
        runtime.setPaused(false)
        let hidden = try await measure("hidden", runtime: runtime, seconds: 3)
        measurements.append(hidden)
        checks.append(.init(name: "hidden-stops-work", passed: hidden.submittedFrameDelta == 0 && hidden.displayLinkCallbackDelta == 0 && hidden.movementFrameDelta == 0 && !runtime.desktop.panel.isVisible && !runtime.renderer.isAnimating,
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
            let clipWait = max(3, runtime.renderer.actionDuration(action) + 0.75)
            let phrasesBefore = runtime.renderer.finitePhraseCount
            runtime.preview(action)
            let clip = try await measure(action.rawValue, runtime: runtime, seconds: clipWait)
            measurements.append(clip)
            guard runtime.permitsMotion else { return makeReport(blockedDuring: action.rawValue) }
            checks.append(.init(name: "\(action.rawValue)-runs-and-settles",
                                passed: (clip.submittedFrameDelta > 0 || runtime.renderer.finitePhraseCount > phrasesBefore)
                                    && !runtime.renderer.isAnimating && !runtime.renderer.isSleeping
                                    && !runtime.renderer.hasActiveDisplayLink && runtime.renderer.activeRigAnimationCount == 0,
                                detail: "A supported finite clip or retained-layer phrase completes awake with no remaining animation or frame clock."))
        }

        let framesBeforeNap = runtime.renderer.submittedFrameCount
        runtime.preview(.fallAsleep)
        let napEntry = try await measure("fall-asleep", runtime: runtime,
                                         seconds: max(1, runtime.renderer.actionDuration(.fallAsleep) + 0.75))
        measurements.append(napEntry)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "fall-asleep") }
        checks.append(.init(name: "nap-settles-asleep", passed: runtime.renderer.submittedFrameCount > framesBeforeNap
                            && runtime.renderer.isSleeping && runtime.isSleeping && !runtime.renderer.isAnimating,
                            detail: "The authored nap entry finishes at the held sleep pose and synchronizes runtime state."))
        let nap = try await measure("static-nap", runtime: runtime, seconds: 1)
        measurements.append(nap)
        checks.append(.init(name: "nap-stops-rendering", passed: nap.submittedFrameDelta == 0 && nap.displayLinkCallbackDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "A nap is a static pose; ordinary autonomous deadlines remain disabled during this probe."))

        let wakeWait = max(3, runtime.renderer.actionDuration(.react) + 0.75)
        runtime.play()
        let wake = try await measure("wake-and-react", runtime: runtime, seconds: wakeWait)
        measurements.append(wake)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "wake-and-react") }
        checks.append(.init(name: "interaction-wakes-pet", passed: wake.submittedFrameDelta > 0 && !runtime.renderer.isSleeping && !runtime.isSleeping && !runtime.renderer.isAnimating,
                            detail: "Interaction plays the authored wake-up bridge, pet and settle, and finishes awake."))

        let queuedWait = max(4, runtime.renderer.actionDuration(.lookAround)
                             + runtime.renderer.actionDuration(.react) + 0.75)
        runtime.preview(.lookAround)
        try await Task.sleep(for: .milliseconds(100))
        runtime.play()
        runtime.play()
        let preservedAction = runtime.renderer.currentAction == .lookAround
        let queued = try await measure("queued-reaction", runtime: runtime, seconds: queuedWait)
        measurements.append(queued)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "queued-reaction") }
        checks.append(.init(name: "interaction-waits-for-clip-boundary", passed: preservedAction && queued.submittedFrameDelta > 0 && !runtime.renderer.isAnimating,
                            detail: "Repeated reactions coalesce after the current look clip instead of snapping its pose."))

        runtime.setAutonomousBehavior(true)
        runtime.scheduleOneBehaviorForProbe(.init(action: .lookAround, delaySeconds: 0.4))
        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.2))
        let hadDeadline = runtime.hasScheduledBehavior
        let scheduled = try await measure("scheduled-blink", runtime: runtime,
                                         seconds: max(2, runtime.renderer.actionDuration(.blink) + 0.95))
        measurements.append(scheduled)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "scheduled-blink") }
        checks.append(.init(name: "replacement-deadline-fires-once", passed: hadDeadline && scheduled.automaticActionDelta == 1 && scheduled.submittedFrameDelta > 0 && !runtime.renderer.isAnimating && !runtime.hasScheduledBehavior,
                            detail: "Replacing a pending deadline yields exactly one finite automatic action; no polling loop is installed."))

        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.3))
        let hadPauseDeadline = runtime.hasScheduledBehavior
        runtime.setPaused(true)
        let cancelled = try await measure("cancelled-by-pause", runtime: runtime, seconds: 0.7)
        measurements.append(cancelled)
        checks.append(.init(name: "pause-cancels-pending-behavior", passed: hadPauseDeadline && cancelled.automaticActionDelta == 0 && cancelled.submittedFrameDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "Pause cancels the deadline before it can start an action."))
        runtime.setPaused(false)
        try await Task.sleep(for: .milliseconds(250))

        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.3))
        let hadHiddenDeadline = runtime.hasScheduledBehavior
        runtime.setHidden(true)
        let hiddenDeadline = try await measure("cancelled-by-hide", runtime: runtime, seconds: 0.7)
        measurements.append(hiddenDeadline)
        checks.append(.init(name: "hide-cancels-pending-behavior", passed: hadHiddenDeadline && hiddenDeadline.automaticActionDelta == 0 && hiddenDeadline.submittedFrameDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "Hiding the pet cancels its resting deadline."))
        runtime.setHidden(false)
        try await Task.sleep(for: .milliseconds(250))

        runtime.scheduleOneBehaviorForProbe(.init(action: .blink, delaySeconds: 0.3))
        let hadDisabledDeadline = runtime.hasScheduledBehavior
        runtime.setAutonomousBehavior(false)
        let disabled = try await measure("cancelled-by-preference", runtime: runtime, seconds: 0.7)
        measurements.append(disabled)
        checks.append(.init(name: "preference-cancels-pending-behavior", passed: hadDisabledDeadline && disabled.automaticActionDelta == 0 && disabled.submittedFrameDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "Turning quiet behavior off cancels its pending deadline."))

        let finalRest = try await measure("final-settled", runtime: runtime, seconds: 10)
        measurements.append(finalRest)
        checks.append(.init(name: "completed-checks-stay-settled", passed: finalRest.submittedFrameDelta == 0 && finalRest.displayLinkCallbackDelta == 0 && finalRest.automaticActionDelta == 0 && !runtime.hasScheduledBehavior,
                            detail: "A longer final resting interval records footprint after the transitions and confirms no continuing work."))

        return makeReport()
    }

    private static func measure(_ state: String, runtime: PetRuntime, seconds: Double) async throws -> ProbeMeasurement {
        let startedAt = Date.now
        let appActiveAtStart = NSApp.isActive
        let interval = signposter.beginInterval("Probe Phase", id: signposter.makeSignpostID(), "\(state, privacy: .public)")
        defer { signposter.endInterval("Probe Phase", interval) }
        let updates = runtime.renderer.submittedFrameCount
        let callbacks = runtime.renderer.displayLinkCallbackCount
        let ticks = runtime.desktop.movementTickCount
        let automaticActions = runtime.automaticActionCount
        let phrases = runtime.renderer.finitePhraseCount
        let proceduralCommits = runtime.renderer.proceduralCommitCount
        let pointer = runtime.pointerCounters
        let before = ProcessSample.capture()
        try await Task.sleep(for: .seconds(seconds))
        let after = ProcessSample.capture()
        let elapsed = after.uptime - before.uptime
        return .init(state: state, startedAt: startedAt, seconds: elapsed,
                     submittedFrameDelta: runtime.renderer.submittedFrameCount - updates,
                     displayLinkCallbackDelta: runtime.renderer.displayLinkCallbackCount - callbacks,
                     movementFrameDelta: runtime.desktop.movementTickCount - ticks,
                     automaticActionDelta: runtime.automaticActionCount - automaticActions,
                     finitePhraseDelta: runtime.renderer.finitePhraseCount - phrases,
                     proceduralCommitDelta: runtime.renderer.proceduralCommitCount - proceduralCommits,
                     decodedLayerBytes: runtime.renderer.decodedLayerBytes,
                     pointerEventDelta: runtime.pointerCounters.receivedEventCount &- pointer.receivedEventCount,
                     pointerSampleDelta: runtime.pointerCounters.deliveredSampleCount &- pointer.deliveredSampleCount,
                     appActiveAtStart: appActiveAtStart,
                     appActiveAtEnd: NSApp.isActive,
                     cpuPercentOfOneCore: elapsed > 0 ? (after.cpuSeconds - before.cpuSeconds) / elapsed * 100 : 0,
                     footprintMiB: after.footprintBytes.map { Double($0) / 1_048_576 })
    }
}
