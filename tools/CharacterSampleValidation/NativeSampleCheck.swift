import AppKit
import CryptoKit
import Darwin
import SprigletCore

/// Deliberately visible own-app windows. Build alone never launches this check.
@main
enum NativeSampleCheck {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let checkout = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : nil
        guard let resourcePath = value(after: "--resources") ?? checkout?.appendingPathComponent("Sources/Spriglet/Resources/SproutSample").path else {
            print("Usage: NativeSampleCheck --resources <SproutSample directory> --asset-report assets.json [--output report.json] [--review-only | --embedded-review] [--review-hold]")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = NativeRunner(resources: URL(fileURLWithPath: resourcePath),
                                  assetReport: value(after: "--asset-report").map { URL(fileURLWithPath: $0) }
                                    ?? checkout?.appendingPathComponent("docs/results/character-sample/assets.json"),
                                  output: value(after: "--output").map { URL(fileURLWithPath: $0) }
                                    ?? checkout?.appendingPathComponent(".build/character-sample-native-default.json"),
                                  reviewOnly: arguments.contains("--review-only"),
                                  reviewHold: arguments.contains("--review-hold"),
                                  embeddedReview: arguments.contains("--embedded-review"))
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}

private struct NativeSnapshot: Codable {
    let submittedFrames: UInt64
    let displayLinkCallbacks: UInt64
    let bufferUnderruns: UInt64
    let movementApplications: UInt64
    let animating: Bool
    let displayLinkActive: Bool
    let bufferedFrames: Int
    let clip: String?
    let timelineFrame: Int?
    let rootOffset: SamplePoint?
    let appliedFrame: Int?
    let appliedRootOffset: SamplePoint
    let panelOrigin: [Double]
    let effectiveOrigin: [Double]
    let desktopImageOffset: [Double]
    let requestedImageOffset: [Double]
    let actualImageLayerOffset: [Double]
    let panelSizePoints: [Double]
    let rendererSizePoints: [Double]
    let rendererBackingPixels: [Double]
    let backingScale: Double
    let visible: Bool
    let appActive: Bool

    @MainActor
    init(_ renderer: PetRenderView, _ desktop: PetWindowController) {
        submittedFrames = renderer.submittedFrameCount
        displayLinkCallbacks = renderer.displayLinkCallbackCount
        bufferUnderruns = renderer.bufferUnderrunCount
        movementApplications = desktop.movementTickCount
        animating = renderer.isAnimating
        displayLinkActive = renderer.hasActiveDisplayLink
        bufferedFrames = renderer.bufferedFrameCount
        clip = renderer.currentSnapshot?.clip.rawValue
        timelineFrame = renderer.currentSnapshot?.timelineFrameIndex
        rootOffset = renderer.currentSnapshot?.rootOffsetPoints
        appliedFrame = desktop.appliedFrameIndex
        appliedRootOffset = desktop.appliedRootOffset
        panelOrigin = [desktop.panel.frame.minX, desktop.panel.frame.minY]
        effectiveOrigin = [desktop.panel.frame.minX + renderer.actualImageLayerOffset.x,
                           desktop.panel.frame.minY + renderer.actualImageLayerOffset.y]
        desktopImageOffset = [desktop.imageOffset.x, desktop.imageOffset.y]
        requestedImageOffset = [renderer.imageOffset.x, renderer.imageOffset.y]
        actualImageLayerOffset = [renderer.actualImageLayerOffset.x, renderer.actualImageLayerOffset.y]
        panelSizePoints = [desktop.panel.frame.width, desktop.panel.frame.height]
        rendererSizePoints = [renderer.bounds.width, renderer.bounds.height]
        let backing = renderer.convertToBacking(renderer.bounds)
        rendererBackingPixels = [backing.width, backing.height]
        backingScale = desktop.panel.backingScaleFactor
        visible = desktop.panel.isVisible && desktop.panel.occlusionState.contains(.visible)
        appActive = NSApp.isActive
    }

    func stayedQuiet(since earlier: Self) -> Bool {
        submittedFrames == earlier.submittedFrames && displayLinkCallbacks == earlier.displayLinkCallbacks
            && movementApplications == earlier.movementApplications && !animating && !displayLinkActive
    }
}

private struct NativeCheck: Codable {
    let name: String
    let status: String
    let detail: String
    var before: NativeSnapshot?
    var after: NativeSnapshot?
}

private struct ResourceInterval: Codable {
    let name: String
    let startedAt: Date
    let elapsedSeconds: Double
    let processCPUPercentOfOneCore: Double
    let physicalFootprintMiBBefore: Double?
    let physicalFootprintMiBAfter: Double?
    let before: NativeSnapshot
    let after: NativeSnapshot
}

private struct PlaybackObservation: Codable {
    let name: String
    let clipsSeen: [String]
    let acceptedFrameCallbacks: Int
    let maximumWindowQuantizationErrorPoints: Double
    let maximumEffectiveOriginErrorPoints: Double
    let maximumLayerOffsetMismatchPoints: Double
    let maximumRequestBoundaryDiscontinuityPoints: Double
    let mismatchedFrameOffsetPairs: Int
    let rejectedFrames: Int
    let bufferUnderrunDelta: UInt64
    let finalSnapshot: NativeSnapshot
}

private struct EmbeddedSnapshot: Codable {
    let viewOriginInBoardPoints: [Double]
    let rendererSizePoints: [Double]
    let rendererBackingPixels: [Double]
    let actualImageLayerOffset: [Double]
    let visible: Bool
    let submittedFrames: UInt64
    let displayLinkCallbacks: UInt64
    let bufferUnderruns: UInt64
    let bufferedFrames: Int
    let animating: Bool
    let displayLinkActive: Bool
    let timelineFrame: Int?
    let rootOffset: SamplePoint?

    @MainActor
    init(_ renderer: PetRenderView) {
        viewOriginInBoardPoints = [renderer.frame.minX, renderer.frame.minY]
        rendererSizePoints = [renderer.bounds.width, renderer.bounds.height]
        let backing = renderer.convertToBacking(renderer.bounds)
        rendererBackingPixels = [backing.width, backing.height]
        actualImageLayerOffset = [renderer.actualImageLayerOffset.x, renderer.actualImageLayerOffset.y]
        visible = renderer.window?.isVisible == true && renderer.window?.occlusionState.contains(.visible) == true
            && !renderer.isHiddenOrHasHiddenAncestor
        submittedFrames = renderer.submittedFrameCount
        displayLinkCallbacks = renderer.displayLinkCallbackCount
        bufferUnderruns = renderer.bufferUnderrunCount
        bufferedFrames = renderer.bufferedFrameCount
        animating = renderer.isAnimating
        displayLinkActive = renderer.hasActiveDisplayLink
        timelineFrame = renderer.currentSnapshot?.timelineFrameIndex
        rootOffset = renderer.currentSnapshot?.rootOffsetPoints
    }

    func stayedQuiet(since earlier: Self) -> Bool {
        submittedFrames == earlier.submittedFrames && displayLinkCallbacks == earlier.displayLinkCallbacks
            && viewOriginInBoardPoints == earlier.viewOriginInBoardPoints && !animating && !displayLinkActive
    }
}

private struct EmbeddedPlaybackObservation: Codable {
    let name: String
    let clipsSeen: [String]
    let acceptedFrameCallbacks: Int
    let maximumEffectiveOriginErrorPoints: Double
    let rejectedFrames: Int
    let bufferUnderrunDelta: UInt64
    let before: EmbeddedSnapshot
    let settled: EmbeddedSnapshot
    let afterRest: EmbeddedSnapshot
}

@MainActor
private final class NativeRunner: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let resources: URL
    private let assetReport: URL?
    private let output: URL?
    private let reviewOnly: Bool
    private let reviewHold: Bool
    private let embeddedReview: Bool
    private let manifestHashAtStart: String?
    private let executableHashAtStart: String?
    private let renderer: PetRenderView
    private let desktop: PetWindowController
    private let board = ReviewBoard(frame: NSRect(x: 0, y: 0, width: 960, height: 400))
    private var boardWindow: NSWindow?
    private var runTask: Task<Void, Never>?
    private var checks: [NativeCheck] = []
    private var intervals: [ResourceInterval] = []
    private var playbacks: [PlaybackObservation] = []
    private var embeddedPlaybacks: [EmbeddedPlaybackObservation] = []
    private var embeddedInitialSnapshot: EmbeddedSnapshot?
    private var beganAt = Date()
    private var motionStart = NSPoint.zero
    private var clipsSeen: [String] = []
    private var acceptedFrames = 0
    private var maximumWindowQuantizationError = 0.0
    private var maximumEffectiveOriginError = 0.0
    private var maximumLayerOffsetMismatch = 0.0
    private var maximumRequestBoundaryDiscontinuity = 0.0
    private var lastAcceptedEffectiveOrigin: NSPoint?
    private var mismatches = 0
    private var rejectedFrames = 0
    private var rejectNextFrame = false
    private var pauseInsideNextFrame = false
    private var submittedCountAtCallbackPause: UInt64?
    private var paused = false
    private var finishing = false
    private var reviewContinuation: CheckedContinuation<Void, Never>?

    init(resources: URL, assetReport: URL?, output: URL?, reviewOnly: Bool, reviewHold: Bool, embeddedReview: Bool) {
        self.resources = resources
        self.assetReport = assetReport
        self.output = output
        self.reviewOnly = reviewOnly
        self.reviewHold = reviewHold
        self.embeddedReview = embeddedReview
        manifestHashAtStart = Self.hash(resources.appendingPathComponent("manifest.json"))
        executableHashAtStart = Self.hash(URL(fileURLWithPath: CommandLine.arguments[0]))
        let pet = PetRenderView(frame: NSRect(x: 0, y: 0, width: 224, height: 224), resourceDirectory: resources)
        renderer = pet
        desktop = PetWindowController(contentView: pet, size: NSSize(width: 224, height: 224),
                                      hitTest: { [weak pet] point in pet?.containsPet(at: point) ?? false })
        super.init()
        desktop.setAllSpaces(false)
        desktop.setClickThrough(true)
        desktop.panel.isRestorable = false
        desktop.panel.disableSnapshotRestoration()
        renderer.onPlaybackWillStart = { [weak self] sequence in
            guard let self else { return false }
            if embeddedReview {
                motionStart = renderer.frame.origin
                return sequence.rootOffsets.allSatisfy { offset in
                    board.bounds.contains(NSRect(origin: NSPoint(x: motionStart.x + offset.x, y: motionStart.y + offset.y),
                                                 size: renderer.frame.size))
                }
            }
            guard desktop.beginAuthoredMotion(sequence.rootOffsets) else { return false }
            motionStart = desktop.effectiveOrigin
            if let previous = lastAcceptedEffectiveOrigin {
                maximumRequestBoundaryDiscontinuity = max(maximumRequestBoundaryDiscontinuity,
                    hypot(motionStart.x - previous.x, motionStart.y - previous.y))
            }
            return true
        }
        renderer.onFrame = { [weak self] frame in self?.apply(frame) ?? false }
        if !embeddedReview {
            renderer.onPlaybackStopped = { [weak self] in self?.desktop.finishAuthoredMotion() }
            desktop.onMovementInterrupted = { [weak self] in self?.renderer.resetPose() }
            desktop.onImageOffsetChanged = { [weak self] in self?.renderer.setImageOffset($0) }
            desktop.onOcclusionChanged = { [weak self] visible in
                guard let self else { return }
                renderer.setSuspended(paused || !visible)
            }
        }
        board.onLight = { [weak self] in
            guard let self else { return }
            place(onDark: false)
            renderer.playSample(walk: .walkRight)
        }
        board.onDark = { [weak self] in
            guard let self else { return }
            place(onDark: true)
            renderer.playSample(walk: .walkLeft)
        }
        board.onFinish = { [weak self] in self?.completeReview() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        beganAt = Date()
        let window = NSWindow(contentRect: board.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sprout — actual 224-point light/dark review"
        window.contentView = board
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.disableSnapshotRestoration()
        window.delegate = self
        window.center()
        boardWindow = window
        window.orderFrontRegardless()
        if embeddedReview {
            // Window-specific screenshots cannot include the separate floating
            // panel. Host the actual live renderer in this board for size/edge
            // review, without representing it as desktop compositing evidence.
            desktop.hide()
            renderer.removeFromSuperview()
            renderer.autoresizingMask = []
            board.addSubview(renderer)
            renderer.setImageOffset(.zero)
            renderer.setSuspended(false)
        }
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Character Sample Check", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        runTask = Task { [weak self] in await self?.run() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finishing else { return }
        runTask?.cancel()
        completeReview()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finishing { return .terminateNow }
        runTask?.cancel()
        completeReview()
        return .terminateCancel
    }

    private func completeReview() {
        let continuation = reviewContinuation
        reviewContinuation = nil
        continuation?.resume()
    }

    private func apply(_ frame: SampleTimelineSnapshot) -> Bool {
        if embeddedReview {
            let wanted = NSPoint(x: motionStart.x + frame.rootOffsetPoints.x, y: motionStart.y + frame.rootOffsetPoints.y)
            let target = NSRect(origin: wanted, size: renderer.frame.size)
            guard board.bounds.contains(target) else { rejectedFrames += 1; return false }
            renderer.setFrameOrigin(wanted)
            acceptedFrames += 1
            if clipsSeen.last != frame.clip.rawValue { clipsSeen.append(frame.clip.rawValue) }
            maximumEffectiveOriginError = max(maximumEffectiveOriginError,
                hypot(renderer.frame.minX + renderer.actualImageLayerOffset.x - wanted.x,
                      renderer.frame.minY + renderer.actualImageLayerOffset.y - wanted.y))
            return true
        }
        if pauseInsideNextFrame {
            pauseInsideNextFrame = false
            submittedCountAtCallbackPause = renderer.submittedFrameCount
            paused = true
            renderer.setSuspended(true)
            // A host callback can synchronously change lifecycle while still
            // returning true. The cancelled generation must not commit its image.
            return true
        }
        if rejectNextFrame {
            rejectNextFrame = false
            rejectedFrames += 1
            return false
        }
        guard desktop.applyAuthoredFrame(frame) else { rejectedFrames += 1; return false }
        acceptedFrames += 1
        if clipsSeen.last != frame.clip.rawValue { clipsSeen.append(frame.clip.rawValue) }
        if desktop.appliedFrameIndex != frame.timelineFrameIndex || desktop.appliedRootOffset != frame.rootOffsetPoints {
            mismatches += 1
        }
        let wanted = NSPoint(x: motionStart.x + frame.rootOffsetPoints.x, y: motionStart.y + frame.rootOffsetPoints.y)
        maximumWindowQuantizationError = max(maximumWindowQuantizationError,
            hypot(desktop.panel.frame.minX - wanted.x, desktop.panel.frame.minY - wanted.y))
        maximumEffectiveOriginError = max(maximumEffectiveOriginError,
            hypot(desktop.panel.frame.minX + renderer.actualImageLayerOffset.x - wanted.x,
                  desktop.panel.frame.minY + renderer.actualImageLayerOffset.y - wanted.y))
        maximumLayerOffsetMismatch = max(maximumLayerOffsetMismatch,
            max(hypot(renderer.imageOffset.x - renderer.actualImageLayerOffset.x, renderer.imageOffset.y - renderer.actualImageLayerOffset.y),
                hypot(desktop.imageOffset.x - renderer.actualImageLayerOffset.x, desktop.imageOffset.y - renderer.actualImageLayerOffset.y)))
        lastAcceptedEffectiveOrigin = NSPoint(x: desktop.panel.frame.minX + renderer.actualImageLayerOffset.x,
                                               y: desktop.panel.frame.minY + renderer.actualImageLayerOffset.y)
        return true
    }

    private func place(onDark: Bool) {
        renderer.resetPose()
        paused = false
        let local = NSPoint(x: onDark ? 600 : 120, y: 72)
        if embeddedReview {
            renderer.setImageOffset(.zero)
            renderer.setFrameOrigin(local)
        } else {
            if let window = boardWindow { desktop.panel.setFrameOrigin(window.convertPoint(toScreen: local)) }
            desktop.show()
        }
        renderer.setSuspended(false)
        board.phase = onDark ? "Dark background · 224 × 224 points" : "Light background · 224 × 224 points"
    }

    private func resetObservations() {
        clipsSeen = []
        acceptedFrames = 0
        maximumWindowQuantizationError = 0
        maximumEffectiveOriginError = 0
        maximumLayerOffsetMismatch = 0
        maximumRequestBoundaryDiscontinuity = 0
        lastAcceptedEffectiveOrigin = nil
        mismatches = 0
        rejectedFrames = 0
    }

    private func recordPlayback(_ name: String, underruns: UInt64) -> PlaybackObservation {
        let result = PlaybackObservation(name: name, clipsSeen: clipsSeen,
                                         acceptedFrameCallbacks: acceptedFrames,
                                         maximumWindowQuantizationErrorPoints: maximumWindowQuantizationError,
                                         maximumEffectiveOriginErrorPoints: maximumEffectiveOriginError,
                                         maximumLayerOffsetMismatchPoints: maximumLayerOffsetMismatch,
                                         maximumRequestBoundaryDiscontinuityPoints: maximumRequestBoundaryDiscontinuity,
                                         mismatchedFrameOffsetPairs: mismatches, rejectedFrames: rejectedFrames,
                                         bufferUnderrunDelta: renderer.bufferUnderrunCount - underruns,
                                         finalSnapshot: NativeSnapshot(renderer, desktop))
        playbacks.append(result)
        return result
    }

    private func measureRest(_ name: String, seconds: Double) async throws -> ResourceInterval {
        board.phase = name
        let started = Date()
        let before = NativeSnapshot(renderer, desktop)
        let usageBefore = ProcessSample.capture()
        try await Task.sleep(for: .seconds(seconds))
        let usageAfter = ProcessSample.capture()
        let after = NativeSnapshot(renderer, desktop)
        let duration = max(0.000_001, usageAfter.uptime - usageBefore.uptime)
        let result = ResourceInterval(name: name, startedAt: started, elapsedSeconds: duration,
                                      processCPUPercentOfOneCore: 100 * max(0, usageAfter.cpuSeconds - usageBefore.cpuSeconds) / duration,
                                      physicalFootprintMiBBefore: usageBefore.footprintBytes.map { Double($0) / 1_048_576 },
                                      physicalFootprintMiBAfter: usageAfter.footprintBytes.map { Double($0) / 1_048_576 },
                                      before: before, after: after)
        intervals.append(result)
        return result
    }

    private func run() async {
        if embeddedReview {
            await runEmbeddedReview()
            return
        }
        do {
            guard renderer.assetError == nil, renderer.manifest != nil else {
                record("assets loaded", false, renderer.assetError ?? "Missing manifest")
                finish()
            }
            place(onDark: false)
            try await Task.sleep(for: .seconds(1))
            let initial = NativeSnapshot(renderer, desktop)
            record("native224-point host", initial.visible && initial.panelSizePoints == [224, 224]
                   && initial.rendererSizePoints == [224, 224] && initial.submittedFrames > 0,
                   "Own native panel geometry and submitted layer contents; inspect actual appearance separately.", after: initial)
            checkHitProbes()
            let rest = try await measureRest("Warm static pose", seconds: 3)
            record("warm rest stops work", rest.after.stayedQuiet(since: rest.before),
                   "No submitted image, display-link callback, or movement application during the measured interval.", before: rest.before, after: rest.after)

            for direction in [SampleClipID.walkRight, .walkLeft] {
                place(onDark: direction == .walkLeft)
                resetObservations()
                let underruns = renderer.bufferUnderrunCount
                board.phase = direction == .walkRight ? "Light · idle → walk right → pet → settle" : "Dark · idle → walk left → pet → settle"
                renderer.playSample(walk: direction)
                try await Task.sleep(for: .seconds(renderer.sampleDuration + 2))
                let playback = recordPlayback("sample-\(direction.rawValue)", underruns: underruns)
                record("finite \(direction.rawValue) sequence", playback.clipsSeen == ["idle", direction.rawValue, "pet", "settle"]
                       && playback.acceptedFrameCallbacks > 0 && !renderer.isAnimating && !renderer.hasActiveDisplayLink,
                       "Real renderer and desktop host traversed the finite authored playlist.", after: playback.finalSnapshot)
                record("paired \(direction.rawValue) pose and travel", playback.mismatchedFrameOffsetPairs == 0
                       && playback.maximumEffectiveOriginErrorPoints < 0.001
                       && playback.maximumLayerOffsetMismatchPoints < 0.001
                       && playback.maximumRequestBoundaryDiscontinuityPoints < 0.001 && playback.rejectedFrames == 0,
                       "Every accepted callback applied the same snapshot and root offset before image commit. Actual panel origin plus actual image-layer geometry matched the authored target within 0.001 point. Raw window rounding is recorded separately; compositor presentation is not measured.")
                record("buffered \(direction.rawValue) playback", playback.bufferUnderrunDelta == 0,
                       "A buffer underrun holds pose and travel; zero underruns are required for this finite observation.")
                let settled = try await measureRest("\(direction.rawValue) settled", seconds: 2)
                record("\(direction.rawValue) stops after settlement", settled.after.stayedQuiet(since: settled.before),
                       "The settled image does not retain a running display link.", before: settled.before, after: settled.after)
            }
            if reviewOnly {
                if !reviewHold {
                    board.phase = "Review complete · close this window to finish"
                    try await Task.sleep(for: .seconds(30))
                }
            } else {
                place(onDark: false)
                resetObservations()
                renderer.playWalk(.walkRight)
                try await Task.sleep(for: .seconds(1))
                let active = NativeSnapshot(renderer, desktop)
                paused = true
                renderer.setSuspended(true)
                renderer.play(.react)
                let pause = try await measureRest("Paused during actual movement", seconds: 2)
                record("pause cancels active and queued work", active.animating && active.timelineFrame != nil
                       && pause.after.stayedQuiet(since: pause.before) && !desktop.isMoving,
                       "Pause interrupted an actual authored frame, rejects a reaction, and leaves no display link.", before: active, after: pause.after)
                paused = false
                renderer.setSuspended(false)
                let resumed = try await measureRest("Resumed static pose", seconds: 2)
                record("resume does not restart cancelled work", resumed.after.stayedQuiet(since: resumed.before),
                       "Resume restores a still image; no implicit continuation of the cancelled sample.", before: resumed.before, after: resumed.after)

                place(onDark: true)
                renderer.playWalk(.walkLeft)
                try await Task.sleep(for: .seconds(1))
                let beforeHide = NativeSnapshot(renderer, desktop)
                desktop.hide()
                try await Task.sleep(for: .milliseconds(250))
                let hidden = try await measureRest("Hidden during actual movement", seconds: 2)
                record("hide interrupts authored playback", beforeHide.animating && hidden.after.stayedQuiet(since: hidden.before)
                       && !hidden.after.visible && !desktop.isMoving,
                       "Native host interruption/occlusion callbacks cancel the renderer; no app preferences are involved.", before: beforeHide, after: hidden.after)

                place(onDark: false)
                resetObservations()
                let underruns = renderer.bufferUnderrunCount
                let originBeforeQueuedWalk = desktop.effectiveOrigin
                renderer.playWalk(.walkRight)
                try await Task.sleep(for: .milliseconds(500))
                renderer.play(.react)
                renderer.play(.react)
                try await Task.sleep(for: .seconds(renderer.walkDuration + renderer.actionDuration(.react) + 2))
                let queued = recordPlayback("queued-pet-after-walk", underruns: underruns)
                record("queued input coalesces at a clip boundary", queued.clipsSeen == ["walkRight", "pet", "settle"]
                       && !renderer.isAnimating && !renderer.hasActiveDisplayLink,
                       "Two identical requests during the walk produce one pet→settle request after it completes.")
                renderer.playWalk(.walkLeft)
                try await Task.sleep(for: .seconds(renderer.walkDuration + 1))
                let continued = recordPlayback("walk-pet-second-walk", underruns: underruns)
                let firstOffset = renderer.manifest?.clips[SampleClipID.walkRight.rawValue]?.frames.last?.rootOffsetPoints ?? .zero
                let secondOffset = renderer.manifest?.clips[SampleClipID.walkLeft.rawValue]?.frames.last?.rootOffsetPoints ?? .zero
                let expectedAfterBoth = NSPoint(x: originBeforeQueuedWalk.x + firstOffset.x + secondOffset.x,
                                                y: originBeforeQueuedWalk.y + firstOffset.y + secondOffset.y)
                let finalVisual = continued.finalSnapshot.effectiveOrigin
                record("new walk preserves settled subpoint origin", continued.clipsSeen == ["walkRight", "pet", "settle", "walkLeft"]
                       && continued.maximumRequestBoundaryDiscontinuityPoints < 0.001
                       && continued.maximumEffectiveOriginErrorPoints < 0.001 && continued.maximumLayerOffsetMismatchPoints < 0.001
                       && continued.mismatchedFrameOffsetPairs == 0 && continued.rejectedFrames == 0
                       && hypot(finalVisual[0] - expectedAfterBoth.x, finalVisual[1] - expectedAfterBoth.y) < 0.001
                       && !renderer.isAnimating && !renderer.hasActiveDisplayLink,
                       "A separate walk→queued pet/settle→second walk retains its image-layer residual across request boundaries and ends at the sum of the authored travel.")

                place(onDark: true)
                resetObservations()
                renderer.playWalk(.walkLeft)
                try await Task.sleep(for: .milliseconds(700))
                let beforeRejection = NativeSnapshot(renderer, desktop)
                rejectNextFrame = true
                try await Task.sleep(for: .milliseconds(500))
                let rejected = try await measureRest("Rejected host movement", seconds: 2)
                record("unapplied movement cancels its image sequence", beforeRejection.animating && rejectedFrames == 1
                       && rejected.after.stayedQuiet(since: rejected.before) && !desktop.isMoving,
                       "A controlled onFrame rejection exercises the no-room/interrupted-host contract; it does not simulate a physical display change.", before: beforeRejection, after: rejected.after)
                place(onDark: true)
                renderer.playWalk(.walkLeft)
                try await Task.sleep(for: .milliseconds(700))
                let beforeCallbackPause = NativeSnapshot(renderer, desktop)
                pauseInsideNextFrame = true
                try await Task.sleep(for: .milliseconds(500))
                let callbackPause = try await measureRest("Pause inside frame callback", seconds: 2)
                record("callback cancellation prevents stale image commit", beforeCallbackPause.animating
                       && submittedCountAtCallbackPause != nil
                       && renderer.submittedFrameCount == submittedCountAtCallbackPause
                       && callbackPause.after.stayedQuiet(since: callbackPause.before) && !desktop.isMoving,
                       "onFrame returned true after synchronously pausing. Generation validation must reject its pending image commit.", before: beforeCallbackPause, after: callbackPause.after)
                paused = false
                renderer.setSuspended(false)
                let finalRest = try await measureRest("Final settled pose", seconds: 10)
                record("final rest remains stopped", finalRest.after.stayedQuiet(since: finalRest.before),
                       "Ten-second resource observation after all finite actions; no battery or GPU budget asserted.", before: finalRest.before, after: finalRest.after)
            }
        } catch is CancellationError {
            checks.append(.init(name: "check completed", status: "cancelled", detail: "The disposable check was closed or quit before completion."))
        } catch {
            record("check completed", false, error.localizedDescription)
        }
        await holdReviewIfRequested()
        finish()
    }

    private func runEmbeddedReview() async {
        do {
            guard renderer.assetError == nil, renderer.manifest != nil else {
                record("assets loaded", false, renderer.assetError ?? "Missing manifest")
                finish()
            }
            place(onDark: false)
            try await Task.sleep(for: .seconds(1))
            let initial = EmbeddedSnapshot(renderer)
            embeddedInitialSnapshot = initial
            record("embedded native224-point view", renderer.superview === board && renderer.window === boardWindow
                   && initial.visible && initial.rendererSizePoints == [224, 224] && initial.submittedFrames > 0,
                   "The actual PetRenderView is a live 224-point child of the review board. This establishes neither separate-panel compositing nor physical input routing.")
            checkHitProbes()
            try await Task.sleep(for: .seconds(2))
            record("embedded warm pose stops work", EmbeddedSnapshot(renderer).stayedQuiet(since: initial),
                   "The displayed still image retains no display link or changing view position.")

            for direction in [SampleClipID.walkRight, .walkLeft] {
                place(onDark: direction == .walkLeft)
                resetObservations()
                let before = EmbeddedSnapshot(renderer)
                board.phase = direction == .walkRight ? "Light · live idle → walk right → pet → settle" : "Dark · live idle → walk left → pet → settle"
                renderer.playSample(walk: direction)
                try await Task.sleep(for: .seconds(renderer.sampleDuration + 2))
                let settled = EmbeddedSnapshot(renderer)
                let completed = renderer.currentSnapshot?.isComplete == true
                try await Task.sleep(for: .seconds(2))
                let afterRest = EmbeddedSnapshot(renderer)
                let playback = EmbeddedPlaybackObservation(name: "embedded-\(direction.rawValue)", clipsSeen: clipsSeen,
                    acceptedFrameCallbacks: acceptedFrames, maximumEffectiveOriginErrorPoints: maximumEffectiveOriginError,
                    rejectedFrames: rejectedFrames, bufferUnderrunDelta: settled.bufferUnderruns - before.bufferUnderruns,
                    before: before, settled: settled, afterRest: afterRest)
                embeddedPlaybacks.append(playback)
                record("embedded finite \(direction.rawValue) sequence", playback.clipsSeen == ["idle", direction.rawValue, "pet", "settle"]
                       && completed && playback.acceptedFrameCallbacks > 0 && !settled.animating && !settled.displayLinkActive,
                       "The live native renderer completed the authored playlist against the review board background.")
                record("embedded \(direction.rawValue) root placement", playback.maximumEffectiveOriginErrorPoints < 0.001
                       && playback.rejectedFrames == 0,
                       "The same frame callback moved the native view inside the board before committing its image. It did not move a desktop window.")
                record("embedded buffered \(direction.rawValue) playback", playback.bufferUnderrunDelta == 0,
                       "No frame-buffer underruns occurred during this measured finite playback.")
                record("embedded \(direction.rawValue) stops after settlement", afterRest.stayedQuiet(since: settled),
                       "Two seconds after the sequence settled, submissions, display-link callbacks, and native view position stayed unchanged.")
            }
            if !reviewHold {
                board.phase = "Live review complete · closes after 30 seconds"
                try await Task.sleep(for: .seconds(30))
            }
        } catch is CancellationError {
            checks.append(.init(name: "check completed", status: "cancelled", detail: "The live review was closed or quit before completion."))
        } catch {
            record("check completed", false, error.localizedDescription)
        }
        await holdReviewIfRequested()
        finish()
    }

    private func holdReviewIfRequested() async {
        if reviewHold && !Task.isCancelled {
            board.phase = embeddedReview ? "Live embedded review ready · replay either background" : "Review controls ready · replay on either background"
            board.enableReviewControls()
            await withCheckedContinuation { reviewContinuation = $0 }
        }
    }

    private func checkHitProbes() {
        struct Probe: Decodable {
            let name: String
            let normalizedBottomLeft: SamplePoint
            let expectedHit: Bool
        }
        struct AssetReport: Decodable {
            let manifestSHA256: String
            let hitTestProbes: [Probe]
        }
        guard let assetReport,
              let reportData = try? Data(contentsOf: assetReport),
              let report = try? JSONDecoder().decode(AssetReport.self, from: reportData),
              let manifestData = try? Data(contentsOf: resources.appendingPathComponent("manifest.json")) else {
            checks.append(.init(name: "independent alpha hit probes", status: "pending",
                                detail: "Pass --asset-report from validate_assets.py to check current rest PNG alpha independently of the renderer mask."))
            return
        }
        let hash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        guard hash == report.manifestSHA256, report.hitTestProbes.contains(where: \.expectedHit) else {
            record("independent alpha hit probes", false, "Asset report does not match the current manifest or lacks a measured opaque probe.")
            return
        }
        for probe in report.hitTestProbes {
            let location = NSPoint(x: probe.normalizedBottomLeft.x * renderer.bounds.width,
                                   y: probe.normalizedBottomLeft.y * renderer.bounds.height)
            record("alpha hit probe: \(probe.name)", renderer.containsPet(at: location) == probe.expectedHit,
                   "Independent full PNG alpha selected normalized bottom-left point (\(probe.normalizedBottomLeft.x), \(probe.normalizedBottomLeft.y)); expected hit \(probe.expectedHit).")
        }
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String, before: NativeSnapshot? = nil, after: NativeSnapshot? = nil) {
        checks.append(.init(name: name, status: passed ? "pass" : "fail", detail: detail, before: before, after: after))
    }

    private func finish() -> Never {
        finishing = true
        renderer.resetPose()
        desktop.hide()
        boardWindow?.orderOut(nil)
        struct Report: Codable {
            let kind: String
            let startedAt: Date
            let finishedAt: Date
            let manifestSHA256: String?
            let executableSHA256: String?
            let processID: Int32
            let operatingSystem: String
            let mode: String
            let checks: [NativeCheck]
            let playback: [PlaybackObservation]
            let embeddedInitialSnapshot: EmbeddedSnapshot?
            let embeddedPlayback: [EmbeddedPlaybackObservation]
            let resourceIntervals: [ResourceInterval]
            let limitations: [String]
        }
        let hash = Self.hash(resources.appendingPathComponent("manifest.json"))
        record("manifest unchanged during native check", manifestHashAtStart != nil && hash == manifestHashAtStart,
               "The loaded manifest hash was captured before renderer construction and compared again at completion.")
        let report = Report(kind: "sprout-native-character-sample", startedAt: beganAt, finishedAt: Date(),
                            manifestSHA256: manifestHashAtStart, executableSHA256: executableHashAtStart,
                            processID: ProcessInfo.processInfo.processIdentifier,
                            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            mode: (embeddedReview ? "embedded-native-review" : (reviewOnly ? "visible-review" : "visible-lifecycle")) + (reviewHold ? "-held" : ""),
                            checks: checks, playback: playbacks, embeddedInitialSnapshot: embeddedInitialSnapshot,
                            embeddedPlayback: embeddedPlaybacks, resourceIntervals: intervals,
                            limitations: [
                                embeddedReview
                                    ? "Embedded review hosts the real PetRenderView as a child of the fixed background board so a window-specific screenshot can show native size and edges. It does not exercise separate-panel compositing, the desktop controller, saved preferences, or full PetRuntime policy."
                                    : "This executable hosts the real renderer and desktop controller in disposable own-app windows; it does not exercise saved user preferences or the full PetRuntime policy.",
                                "AppKit points/backing pixels establish native size. Human or UI screenshot review of appearance on both backgrounds must be recorded separately.",
                                "Submitted layer contents and display-link callbacks are application counters, not presented GPU frames. One callback pairs image selection with root motion; WindowServer presentation is not proven atomic.",
                                "Process CPU and physical footprint include the fixture, its background board, image decoding, and renderer. They are not the normal app baseline or measurements of WindowServer, GPU work, energy, or battery life.",
                                "No physical cross-app input, full-screen, screen topology change, long soak, or production animation approval is certified."
                            ])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let output {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
            } else { print(String(decoding: data, as: UTF8.self)) }
        } catch { print("Could not write character sample report: \(error)"); exit(2) }
        exit(checks.allSatisfy { $0.status == "pass" } ? 0 : 1)
    }

    private static func hash(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}

@MainActor
private final class ReviewBoard: NSView {
    var phase = "Preparing sample…" { didSet { needsDisplay = true } }
    var onLight: (() -> Void)?
    var onDark: (() -> Void)?
    var onFinish: (() -> Void)?
    private var reviewButtons: [NSButton] = []
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (title, x, action) in [("Light sample", CGFloat(24), #selector(showLight)),
                                   ("Dark sample", CGFloat(192), #selector(showDark)),
                                   ("Finish review", CGFloat(778), #selector(finishReview))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .push
            button.frame = NSRect(x: x, y: 12, width: 150, height: 28)
            button.isEnabled = false
            addSubview(button)
            reviewButtons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:).") }

    func enableReviewControls() { for button in reviewButtons { button.isEnabled = true } }
    @objc private func showLight() { onLight?() }
    @objc private func showDark() { onDark?() }
    @objc private func finishReview() { onFinish?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 480, height: 400).fill()
        NSColor(srgbRed: 0.08, green: 0.11, blue: 0.15, alpha: 1).setFill()
        NSRect(x: 480, y: 0, width: 480, height: 400).fill()
        for (title, x, color) in [("Light · native 224pt canvas", CGFloat(24), NSColor.black),
                                  ("Dark · native 224pt canvas", CGFloat(504), NSColor.white)] {
            (title as NSString).draw(at: NSPoint(x: x, y: 362), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: color])
        }
        (phase as NSString).draw(at: NSPoint(x: 24, y: 326), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        NSColor.gray.withAlphaComponent(0.13).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for x in stride(from: 0, through: 960, by: 48) { grid.move(to: NSPoint(x: x, y: 50)); grid.line(to: NSPoint(x: x, y: 340)) }
        for y in stride(from: 52, through: 340, by: 48) { grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: 960, y: y)) }
        grid.stroke()
    }
}
