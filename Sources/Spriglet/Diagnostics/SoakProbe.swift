import AppKit
import Foundation
import OSLog

struct SoakConfiguration: Encodable {
    let cycleCount = 100
    let checkpointEveryCycles = 10
    let warmUpSeconds = 2.0
    let baselineSeconds = 3.0
    let hiddenSeconds = 0.25
    let showSettlingSeconds = 0.25
    let reactionSettlingSeconds: Double
    let checkpointSeconds = 0.75
    let finalRestIntervals = 3
    let finalRestIntervalSeconds = 15.0

    init(reactionDuration: TimeInterval) {
        reactionSettlingSeconds = max(2.0, reactionDuration + 0.75)
    }
}

struct SoakBuildIdentity: Encodable {
    let processID: Int32
    let executablePath: String?
    let bundleIdentifier: String?
    let appVersion: String?
    let buildVersion: String?
    let xcodeBuild: String?
    let sdkBuild: String?
    let configuration: String

    init() {
        let bundle = Bundle.main
        processID = ProcessInfo.processInfo.processIdentifier
        executablePath = bundle.executableURL?.standardizedFileURL.path
        bundleIdentifier = bundle.bundleIdentifier
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        xcodeBuild = bundle.object(forInfoDictionaryKey: "DTXcodeBuild") as? String
        sdkBuild = bundle.object(forInfoDictionaryKey: "DTSDKBuild") as? String
        #if DEBUG
        configuration = "Debug"
        #else
        configuration = "Release"
        #endif
    }
}

struct SoakCounters: Encodable {
    let submittedFrames: UInt64
    let displayLinkCallbacks: UInt64
    let movementFrames: UInt64
    let automaticActions: UInt64

    @MainActor init(runtime: PetRuntime) {
        submittedFrames = runtime.renderer.submittedFrameCount
        displayLinkCallbacks = runtime.renderer.displayLinkCallbackCount
        movementFrames = runtime.desktop.movementTickCount
        automaticActions = runtime.automaticActionCount
    }

    private init(submittedFrames: UInt64, displayLinkCallbacks: UInt64, movementFrames: UInt64, automaticActions: UInt64) {
        self.submittedFrames = submittedFrames
        self.displayLinkCallbacks = displayLinkCallbacks
        self.movementFrames = movementFrames
        self.automaticActions = automaticActions
    }

    func subtracting(_ earlier: Self) -> Self {
        Self(submittedFrames: submittedFrames &- earlier.submittedFrames,
             displayLinkCallbacks: displayLinkCallbacks &- earlier.displayLinkCallbacks,
             movementFrames: movementFrames &- earlier.movementFrames,
             automaticActions: automaticActions &- earlier.automaticActions)
    }

    var isZero: Bool {
        submittedFrames == 0 && displayLinkCallbacks == 0 && movementFrames == 0 && automaticActions == 0
    }
}

struct SoakCycle: Encodable {
    let index: Int
    let hiddenCounters: SoakCounters
    let reactionCounters: SoakCounters
    let wholeCycleCounters: SoakCounters
    let hiddenWindowWasHidden: Bool
    let hiddenAnimationStopped: Bool
    let reactionStarted: Bool
    let reactionSettled: Bool
    let hasScheduledBehaviorAtEnd: Bool

    var hiddenPassed: Bool {
        hiddenWindowWasHidden && hiddenAnimationStopped && hiddenCounters.isZero
    }

    var reactionPassed: Bool {
        reactionStarted && reactionSettled && reactionCounters.submittedFrames > 0
    }

    var manualOnlyPassed: Bool {
        wholeCycleCounters.automaticActions == 0 && wholeCycleCounters.movementFrames == 0 && !hasScheduledBehaviorAtEnd
    }
}

struct SoakFootprintSample: Encodable {
    let phase: String
    let completedCycles: Int
    let elapsedSeconds: Double
    let footprintMiB: Double?
}

struct SoakResourceObservations: Encodable {
    let baselineSettledFootprintMiB: Double?
    let finalSettledFootprintMiB: Double?
    let maximumObservedSampleMiB: Double?
    let finalMinusBaselineMiB: Double?
    let sampleCount: Int
    let interpretation: String

    init(baseline: Double?, final: Double?, samples: [SoakFootprintSample]) {
        baselineSettledFootprintMiB = baseline
        finalSettledFootprintMiB = final
        maximumObservedSampleMiB = samples.compactMap(\.footprintMiB).max()
        if let baseline, let final {
            finalMinusBaselineMiB = final - baseline
        } else {
            finalMinusBaselineMiB = nil
        }
        sampleCount = samples.count
        interpretation = "Measurements only: no memory, CPU, GPU, or battery budget is asserted. The maximum is the largest sampled footprint, not the process high-water mark. Compare the final rest with the warmed baseline and investigate retained differences with Allocations."
    }
}

struct SoakReport: Encodable {
    let kind = "desktop-soak"
    let startedAt: Date
    let recordedAt: Date
    let elapsedSeconds: Double
    let os: String
    let buildIdentity: SoakBuildIdentity
    let configuration: SoakConfiguration
    let completedCycles: Int
    let cycles: [SoakCycle]
    let measurements: [ProbeMeasurement]
    let footprintSamples: [SoakFootprintSample]
    let resourceObservations: SoakResourceObservations
    let functionalChecks: [ProbeCheck]
    let limitations: [String]
    let outcome: ProbeOutcome

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self), let output = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Could not encode soak report\"}"
        }
        return output
    }
}

/// A finite, explicitly requested workload. It installs no production sampler.
@MainActor
enum SoakProbe {
    private static let signposter = OSSignposter(subsystem: "dev.spriglet.prototype", category: "soak")

    static func run(runtime: PetRuntime) async throws -> SoakReport {
        let configuration = SoakConfiguration(reactionDuration: runtime.renderer.actionDuration(.react))
        let startedAt = Date.now
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let buildIdentity = SoakBuildIdentity()
        var cycles: [SoakCycle] = []
        var measurements: [ProbeMeasurement] = []
        var footprintSamples: [SoakFootprintSample] = []
        var checks: [ProbeCheck] = []
        var baselineFootprint: Double?
        var finalFootprint: Double?
        cycles.reserveCapacity(configuration.cycleCount)

        @MainActor func makeReport(blockedDuring phase: String? = nil) -> SoakReport {
            var reportChecks = checks
            if !cycles.isEmpty {
                reportChecks.append(.init(name: "observed-hidden-phases-stop", passed: cycles.allSatisfy(\.hiddenPassed),
                                          detail: "All \(cycles.count) completed cycles hid the window and stopped frame, display-link, movement, and autonomous callbacks while hidden."))
                reportChecks.append(.init(name: "observed-reactions-run-and-settle", passed: cycles.allSatisfy(\.reactionPassed),
                                          detail: "Every completed cycle started a reaction, completed layer content assignments, and settled awake."))
                reportChecks.append(.init(name: "cycles-have-no-unsolicited-work", passed: cycles.allSatisfy(\.manualOnlyPassed),
                                          detail: "Completed cycles had no autonomous actions, movement ticks, or remaining behavior deadline."))
            }
            if let phase {
                reportChecks.append(.init(blocked: "The diagnostic session or visibility/motion policy prevented or interrupted \(phase). System preferences were not changed."))
            }
            let outcome: ProbeOutcome = reportChecks.contains { $0.outcome == .failed } ? .failed :
                (reportChecks.contains { $0.outcome == .blocked } ? .blocked : .passed)
            return SoakReport(
                startedAt: startedAt, recordedAt: .now,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedUptime,
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                buildIdentity: buildIdentity, configuration: configuration,
                completedCycles: cycles.count, cycles: cycles,
                measurements: measurements, footprintSamples: footprintSamples,
                resourceObservations: .init(baseline: baselineFootprint, final: finalFootprint, samples: footprintSamples),
                functionalChecks: reportChecks,
                limitations: [
                    "This is a bounded repeated-interaction workload, not a natural-behavior or multi-hour soak.",
                    "Functional outcomes cover observed counters and app/window state. Resource values are observations without pass/fail budgets.",
                    "Layer assignments and display-link callbacks are not GPU submissions. CPU values cover this process only, not WindowServer or GPU work.",
                    "Footprint is sampled at finite checkpoints; peaks and policy/activity changes between samples may be missed.",
                    "Each cycle checks motion eligibility after showing and after its reaction. Temporary system changes that clear between boundaries may be missed.",
                    "The run temporarily uses shown, unpaused, click-through, manual-only choices; normal scheduling and preference writes are suppressed by the diagnostic lifecycle.",
                    "Settings and placement are restored by diagnostic cleanup; this report does not independently prove persistence or cancellation behavior.",
                    "Physical click routing, cross-app focus, desktop transparency, Spaces, full-screen, display transitions, actual sleep/wake, GPU energy, and battery life need separate validation.",
                    "Measurements cover the bundled Sprout sample, not the future complete character library."
                ], outcome: outcome
            )
        }

        @MainActor func recordFootprint(_ phase: String, completedCycles: Int) {
            let sample = ProcessSample.capture()
            footprintSamples.append(.init(phase: phase, completedCycles: completedCycles,
                                          elapsedSeconds: sample.uptime - startedUptime,
                                          footprintMiB: sample.footprintBytes.map { Double($0) / 1_048_576 }))
        }

        @MainActor func recordMeasurement(_ measurement: ProbeMeasurement) {
            measurements.append(measurement)
            footprintSamples.append(.init(phase: measurement.state, completedCycles: cycles.count,
                                          elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedUptime,
                                          footprintMiB: measurement.footprintMiB))
        }

        // Refuse direct use outside the shared lifecycle: mutations must never
        // reach preference storage, including the saved placement payload.
        guard runtime.sampling, !runtime.hasScheduledBehavior else {
            return makeReport(blockedDuring: "diagnostic preparation")
        }
        let originalPreferences = runtime.snapshotPreferencesForProbe()
        defer { runtime.restoreAfterProbe(originalPreferences) }

        runtime.setAutonomousBehavior(false)
        runtime.setHidden(false)
        runtime.setPaused(false)
        runtime.setClickThrough(true)
        runtime.desktop.stopMovement()
        runtime.renderer.resetPose()
        runtime.updateDiagnosticProgress("Warming the renderer before the 100-cycle check.")
        try await Task.sleep(for: .seconds(configuration.warmUpSeconds), tolerance: .milliseconds(50))
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "warm-up") }
        checks.append(.init(name: "initial-frame-submitted", passed: runtime.renderer.submittedFrameCount > 0,
                            detail: "The initial pose completed a layer content assignment before any quiet interval could pass."))

        runtime.play()
        let warmUpStarted = runtime.renderer.isAnimating
        let warmUp = try await measure("warm-up-reaction", runtime: runtime, seconds: configuration.reactionSettlingSeconds)
        recordMeasurement(warmUp)
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "warm-up reaction") }
        let warmUpPassed = warmUpStarted && warmUp.submittedFrameDelta > 0 && !runtime.renderer.isAnimating
        checks.append(.init(name: "warm-up-reaction-settles", passed: warmUpPassed,
                            detail: "A finite reaction warms rendering resources before the settled baseline."))
        guard warmUpPassed else { return makeReport() }

        let baseline = try await measure("baseline-settled", runtime: runtime, seconds: configuration.baselineSeconds)
        recordMeasurement(baseline)
        baselineFootprint = baseline.footprintMiB
        guard runtime.permitsMotion else { return makeReport(blockedDuring: "baseline") }
        let baselinePassed = isQuiet(baseline, runtime: runtime)
        checks.append(.init(name: "baseline-stays-settled", passed: baselinePassed,
                            detail: "The warmed baseline has no frame, display-link, movement, or autonomous callbacks, or pending deadline."))
        guard baselinePassed else { return makeReport() }

        for index in 1 ... configuration.cycleCount {
            try Task.checkCancellation()
            guard runtime.permitsMotion else { return makeReport(blockedDuring: "cycle \(index) preparation") }
            let cycleStart = SoakCounters(runtime: runtime)
            let isCheckpoint = index.isMultiple(of: configuration.checkpointEveryCycles)

            runtime.setHidden(true)
            let hiddenStart = SoakCounters(runtime: runtime)
            try await Task.sleep(for: .seconds(configuration.hiddenSeconds), tolerance: .milliseconds(50))
            let hiddenCounters = SoakCounters(runtime: runtime).subtracting(hiddenStart)
            let hiddenWindowWasHidden = !runtime.desktop.panel.isVisible
            let hiddenAnimationStopped = !runtime.renderer.isAnimating
            if isCheckpoint { recordFootprint("cycle-\(index)-hidden", completedCycles: cycles.count) }

            runtime.setHidden(false)
            try await Task.sleep(for: .seconds(configuration.showSettlingSeconds), tolerance: .milliseconds(50))
            guard runtime.permitsMotion else { return makeReport(blockedDuring: "cycle \(index) show") }
            if isCheckpoint { recordFootprint("cycle-\(index)-shown", completedCycles: cycles.count) }

            let reactionStart = SoakCounters(runtime: runtime)
            runtime.play()
            let reactionStarted = runtime.renderer.isAnimating && runtime.desktop.panel.isVisible
            try await Task.sleep(for: .seconds(configuration.reactionSettlingSeconds), tolerance: .milliseconds(50))
            guard runtime.permitsMotion else { return makeReport(blockedDuring: "cycle \(index) reaction") }
            let cycleEnd = SoakCounters(runtime: runtime)
            let cycle = SoakCycle(index: index,
                                  hiddenCounters: hiddenCounters,
                                  reactionCounters: cycleEnd.subtracting(reactionStart),
                                  wholeCycleCounters: cycleEnd.subtracting(cycleStart),
                                  hiddenWindowWasHidden: hiddenWindowWasHidden,
                                  hiddenAnimationStopped: hiddenAnimationStopped,
                                  reactionStarted: reactionStarted,
                                  reactionSettled: !runtime.renderer.isAnimating && !runtime.renderer.isSleeping,
                                  hasScheduledBehaviorAtEnd: runtime.hasScheduledBehavior)
            cycles.append(cycle)
            guard cycle.hiddenPassed, cycle.reactionPassed, cycle.manualOnlyPassed else { return makeReport() }

            if isCheckpoint {
                recordFootprint("cycle-\(index)-reaction-settled", completedCycles: cycles.count)
                let checkpoint = try await measure("settled-after-\(index)-cycles", runtime: runtime, seconds: configuration.checkpointSeconds)
                recordMeasurement(checkpoint)
                guard runtime.permitsMotion else { return makeReport(blockedDuring: "checkpoint \(index)") }
                let passed = isQuiet(checkpoint, runtime: runtime)
                checks.append(.init(name: "settled-after-\(index)-cycles", passed: passed,
                                    detail: "This finite checkpoint has no frame, display-link, movement, or autonomous work after the reaction settles."))
                runtime.updateDiagnosticProgress("Completed \(index) of \(configuration.cycleCount) show/hide/reaction cycles.")
                guard passed else { return makeReport() }
            }
        }
        checks.append(.init(name: "all-requested-cycles-completed", passed: cycles.count == configuration.cycleCount,
                            detail: "All 100 requested show/hide/reaction cycles completed."))

        runtime.updateDiagnosticProgress("All 100 cycles completed. Observing a final 45-second rest.")
        for index in 1 ... configuration.finalRestIntervals {
            guard runtime.permitsMotion else { return makeReport(blockedDuring: "final rest \(index)") }
            let finalRest = try await measure("final-rest-\(index)", runtime: runtime, seconds: configuration.finalRestIntervalSeconds)
            recordMeasurement(finalRest)
            guard runtime.permitsMotion else { return makeReport(blockedDuring: "final rest \(index)") }
            let passed = isQuiet(finalRest, runtime: runtime)
            checks.append(.init(name: "final-rest-\(index)-stays-settled", passed: passed,
                                detail: "A fifteen-second final interval remains stopped; footprint and CPU are observations only."))
            if index == configuration.finalRestIntervals { finalFootprint = finalRest.footprintMiB }
            guard passed else { return makeReport() }
        }
        return makeReport()
    }

    private static func isQuiet(_ measurement: ProbeMeasurement, runtime: PetRuntime) -> Bool {
        measurement.submittedFrameDelta == 0 && measurement.displayLinkCallbackDelta == 0
            && measurement.movementFrameDelta == 0 && measurement.automaticActionDelta == 0
            && !runtime.renderer.isAnimating && !runtime.desktop.isMoving && !runtime.hasScheduledBehavior
    }

    private static func measure(_ state: String, runtime: PetRuntime, seconds: Double) async throws -> ProbeMeasurement {
        let startedAt = Date.now
        let appActiveAtStart = NSApp.isActive
        let interval = signposter.beginInterval("Soak Measurement", id: signposter.makeSignpostID(), "\(state, privacy: .public)")
        defer { signposter.endInterval("Soak Measurement", interval) }
        let beforeCounters = SoakCounters(runtime: runtime)
        let phrases = runtime.renderer.finitePhraseCount
        let proceduralCommits = runtime.renderer.proceduralCommitCount
        let pointer = runtime.pointerCounters
        let before = ProcessSample.capture()
        try await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(50))
        let after = ProcessSample.capture()
        let counters = SoakCounters(runtime: runtime).subtracting(beforeCounters)
        let elapsed = after.uptime - before.uptime
        return .init(state: state, startedAt: startedAt, seconds: elapsed,
                     submittedFrameDelta: counters.submittedFrames, displayLinkCallbackDelta: counters.displayLinkCallbacks,
                     movementFrameDelta: counters.movementFrames, automaticActionDelta: counters.automaticActions,
                     finitePhraseDelta: runtime.renderer.finitePhraseCount - phrases,
                     proceduralCommitDelta: runtime.renderer.proceduralCommitCount - proceduralCommits,
                     decodedLayerBytes: runtime.renderer.decodedLayerBytes,
                     pointerEventDelta: runtime.pointerCounters.receivedEventCount &- pointer.receivedEventCount,
                     pointerSampleDelta: runtime.pointerCounters.deliveredSampleCount &- pointer.deliveredSampleCount,
                     appActiveAtStart: appActiveAtStart, appActiveAtEnd: NSApp.isActive,
                     cpuPercentOfOneCore: elapsed > 0 ? (after.cpuSeconds - before.cpuSeconds) / elapsed * 100 : 0,
                     footprintMiB: after.footprintBytes.map { Double($0) / 1_048_576 })
    }
}
