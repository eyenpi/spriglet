import AppKit
import QuartzCore
import SprigletCore

/// One display link selects the authored image and root offset together. A child
/// layer retains the final image without an idle timer or continuous drawing.
@MainActor
final class PetRenderView: NSView {
    var onAnimationStateChanged: ((Bool) -> Void)?
    var onPlaybackWillStart: ((SampleTimeline) -> Bool)?
    /// Applies the offset before the corresponding image is committed. This is
    /// one app callback, not a claim of atomic WindowServer/GPU presentation.
    var onFrame: ((SampleTimelineSnapshot) -> Bool)?
    var onPlaybackStopped: (() -> Void)?
    var onAssetError: ((String) -> Void)?

    private(set) var isAnimating = false
    private(set) var isSleeping = false
    private(set) var currentAction: PetAction?
    private(set) var currentRoutine: PetRoutine?
    private(set) var completedRoutineCount: UInt64 = 0
    private(set) var lastCompletedRoutine: PetRoutine?
    private(set) var currentSnapshot: SampleTimelineSnapshot?
    private(set) var submittedFrameCount: UInt64 = 0
    private(set) var displayLinkCallbackCount: UInt64 = 0
    private(set) var bufferUnderrunCount: UInt64 = 0
    private(set) var manifest: SproutSampleManifest?
    private(set) var petDisplaySize: PetDisplaySize = .standard
    private(set) var assetError: String?
    private(set) var imageOffset = CGPoint.zero
    /// Reads the child layer geometry used for presentation, independently of
    /// the requested offset, so native validation can detect a missed update.
    var actualImageLayerOffset: CGPoint {
        CGPoint(x: imageLayer.frame.minX - bounds.minX, y: imageLayer.frame.minY - bounds.minY)
    }
    var hasActiveDisplayLink: Bool { playbackLink != nil }
    var bufferedFrameCount: Int { decodedFrames.count }
    var fireflyVisible: Bool { !fireflyLayer.isHidden && fireflyLayer.opacity > 0 }
    var currentFireflyPosition: CGPoint? { fireflyVisible ? fireflyLayer.position : nil }
    var currentFireflyFrame: CGRect? { fireflyVisible ? fireflyLayer.frame : nil }
    var displaySize: NSSize { petDisplaySize.size }
    var sampleDuration: TimeInterval {
        duration(of: [.idle, .walkRight, .pet, .settle])
    }
    var walkDuration: TimeInterval { max(clipDuration(.walkLeft), clipDuration(.walkRight)) }
    func actionDuration(_ action: PetAction) -> TimeInterval { duration(of: request(for: action).clips) }
    func clipDuration(_ clip: SampleClipID) -> TimeInterval { duration(of: [clip]) }

    private let imageLayer = CALayer()
    private let fireflyLayer = CALayer()
    private let fireflyWings = CAShapeLayer()
    private var resourceDirectory: URL?
    private var playbackManifest: SproutSampleManifest?
    private var restImage: SampleDecodedFrame?
    private var sleepImage: SampleDecodedFrame?
    private var currentImage: SampleDecodedFrame?
    private var decodedFrames: [Int: SampleDecodedFrame] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var timeline: SampleTimeline?
    private var queuedRequest: Request?
    private var activeRequest: Request?
    private var elapsed: TimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private var isSuspended = false
    private var isChangingDisplaySize = false
    private var preferredFramesPerSecond = 30
    private var playbackLink: CADisplayLink?
    private var linkTarget: SampleDisplayLinkTarget?
    private let bufferCapacity = 12

    override var isOpaque: Bool { false }

    init(frame: NSRect, resourceDirectory: URL? = nil) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .linear
        imageLayer.magnificationFilter = .linear
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)
        configureFirefly()
        do {
            let root = resourceDirectory ?? Bundle.main.url(forResource: "SproutSample", withExtension: nil)
            guard let root else { throw SampleManifestError.invalid("Bundled Sprout character sample is missing.") }
            self.resourceDirectory = root
            let metadata = try SproutSampleManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
            let rest = try SampleImageDecoder.decodeImmediately(url: root.appendingPathComponent(metadata.restFrame), canvas: metadata.canvasPixels)
            let sleep = try SampleImageDecoder.decodeImmediately(url: root.appendingPathComponent(metadata.sleepFrame), canvas: metadata.canvasPixels)
            manifest = metadata
            playbackManifest = try petDisplaySize.scaledManifest(metadata)
            restImage = rest
            sleepImage = sleep
            present(rest)
        } catch {
            assetError = error.localizedDescription
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:resourceDirectory:).") }

    isolated deinit {
        playbackLink?.invalidate()
        prefetchTask?.cancel()
    }

    override func setFrameSize(_ newSize: NSSize) {
        // An external host resize also cancels queued work. No teardown callback
        // may start a request against geometry that is still changing.
        let wasChangingSize = isChangingDisplaySize
        isChangingDisplaySize = true
        defer { isChangingDisplaySize = wasChangingSize }
        if newSize != frame.size { cancelPlayback(showRest: true) }
        super.setFrameSize(newSize)
        updateImageLayerFrame()
    }

    /// Runtime coordinates this with the host resize inside its behavior
    /// transition, then restores any saved placement using the new dimensions.
    func setDisplaySize(_ choice: PetDisplaySize) {
        guard choice != petDisplaySize || frame.size != choice.size else { return }
        let wasChangingSize = isChangingDisplaySize
        isChangingDisplaySize = true
        defer { isChangingDisplaySize = wasChangingSize }
        cancelPlayback(showRest: true)
        petDisplaySize = choice
        do {
            if let manifest { playbackManifest = try choice.scaledManifest(manifest) }
        } catch {
            playbackManifest = nil
            fail(error)
        }
        // Attached content inherits the host's resize through its autoresizing
        // mask. Resizing it here as well would apply the parent's delta twice.
        if superview == nil {
            super.setFrameSize(choice.size)
            updateImageLayerFrame()
        }
    }

    /// Retained across rest poses, cancellation, and subsequent requests. The
    /// host calls this within onFrame before the corresponding image commit.
    func setImageOffset(_ offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        imageOffset = offset
        updateImageLayerFrame()
    }

    private func updateImageLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds.offsetBy(dx: imageOffset.x, dy: imageOffset.y)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPlayback(showRest: false) }
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func setPreferredFramesPerSecond(_ value: Int) {
        preferredFramesPerSecond = max(1, value)
        updateFrameRate()
    }

    func play() { play(.react) }

    /// One pending request, replaced by the latest interaction. The current
    /// finite request reaches its resting boundary before that request begins.
    /// True means this request began or replaced the pending request; it does
    /// not claim that the animation has completed or even decoded its first frame.
    @discardableResult
    func play(_ action: PetAction) -> Bool {
        guard canAcceptPlayback else { return false }
        guard !(action == .fallAsleep && isSleeping), !(action == .wakeUp && !isSleeping) else { return false }
        let next = request(for: action)
        // Teardown callbacks run after the old timeline is cleared. An action
        // requested there replaces it immediately instead of becoming orphaned.
        if isAnimating, timeline != nil {
            if action == currentAction {
                queuedRequest = nil
                return false
            }
            guard queuedRequest?.action != action else { return false }
            queuedRequest = next
            return true
        }
        return begin(next)
    }

    func playWalk(_ clip: SampleClipID) {
        guard clip == .walkLeft || clip == .walkRight, canAcceptPlayback else { return }
        guard cancelPlayback(showRest: true) else { return }
        begin(Request(clips: [clip], action: nil))
    }

    func playSample(walk: SampleClipID) {
        guard walk == .walkLeft || walk == .walkRight, canAcceptPlayback else { return }
        guard cancelPlayback(showRest: true) else { return }
        begin(Request(clips: [.idle, walk, .pet, .settle], action: nil))
    }

    func routineClips(_ routine: PetRoutine, direction: SampleClipID = .walkLeft, stationary: Bool = false) -> [SampleClipID] {
        routine.clips(direction: direction, stationary: stationary)
    }

    func routineRootOffsets(_ routine: PetRoutine, direction: SampleClipID = .walkLeft, stationary: Bool = false) -> [SamplePoint]? {
        rootOffsets(for: routineClips(routine, direction: direction, stationary: stationary))
    }

    func routineDuration(_ routine: PetRoutine, direction: SampleClipID = .walkLeft, stationary: Bool = false) -> TimeInterval {
        duration(of: routineClips(routine, direction: direction, stationary: stationary))
    }

    func playRoutine(_ routine: PetRoutine, direction: SampleClipID = .walkLeft, stationary: Bool = false) {
        let clips = routineClips(routine, direction: direction, stationary: stationary)
        guard !clips.isEmpty, canAcceptPlayback else { return }
        guard cancelPlayback(showRest: true) else { return }
        begin(Request(clips: clips, action: nil, routine: routine, direction: direction, stationary: stationary))
    }

    func rootOffsets(for clips: [SampleClipID]) -> [SamplePoint]? {
        guard let playbackManifest,
              let sequence = try? SampleTimeline(manifest: playbackManifest, clips: clips) else { return nil }
        return sequence.rootOffsets
    }

    /// Pause, hiding, sleep, or occlusion cancels active and queued actions. The
    /// still layer is always available, including on a cold paused launch.
    func setSuspended(_ value: Bool) {
        guard value != isSuspended else { return }
        isSuspended = value
        cancelPlayback(showRest: !value)
    }

    func resetPose() { cancelPlayback(showRest: true) }

    func containsPet(at point: NSPoint) -> Bool {
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0, let currentImage else { return false }
        // Match resizeAspect as well as the subpoint image-layer translation.
        let scale = min(bounds.width / CGFloat(currentImage.image.width), bounds.height / CGFloat(currentImage.image.height))
        let width = CGFloat(currentImage.image.width) * scale
        let height = CGFloat(currentImage.image.height) * scale
        let imageFrame = CGRect(
            x: imageLayer.frame.midX - width / 2, y: imageLayer.frame.midY - height / 2,
            width: width, height: height
        )
        return currentImage.contains(
            x: Double((point.x - imageFrame.minX) / width),
            y: Double((point.y - imageFrame.minY) / height)
        )
    }

    private func request(for action: PetAction) -> Request {
        switch action {
        case .react: Request(clips: [.pet, .settle], action: action)
        case .fallAsleep: Request(clips: [], action: action, sleepsAtEnd: true)
        case .wakeUp: Request(clips: [], action: action)
        // The sample's authored idle is the explicit preview for these planner
        // requests; it does not claim three separately authored animation clips.
        case .blink, .lookAround, .stretch: Request(clips: [.idle], action: action)
        }
    }

    private func duration(of clips: [SampleClipID]) -> TimeInterval {
        guard let manifest else { return 0 }
        return clips.reduce(0) { $0 + Double(manifest.clips[$1.rawValue]?.frames.count ?? 0) / manifest.framesPerSecond }
    }

    private var canAcceptPlayback: Bool {
        !isSuspended && !isChangingDisplaySize && bounds.size == displaySize
    }

    @discardableResult
    private func begin(_ request: Request) -> Bool {
        guard canAcceptPlayback, let playbackManifest, assetError == nil else { return false }
        if request.clips.isEmpty {
            generation &+= 1
            let requestGeneration = generation
            let wasAnimating = isAnimating
            let changedSleep = isSleeping != request.sleepsAtEnd
            isSleeping = request.sleepsAtEnd
            currentAction = nil
            currentRoutine = nil
            clearFirefly()
            currentSnapshot = nil
            if let image = isSleeping ? sleepImage : restImage { present(image) }
            setAnimating(false)
            if !wasAnimating, changedSleep { onAnimationStateChanged?(false) }
            return generation == requestGeneration && !isSuspended
        }
        do {
            let sequence = try SampleTimeline(manifest: playbackManifest, clips: request.clips)
            let preparationGeneration = generation
            guard onPlaybackWillStart?(sequence) ?? true,
                  generation == preparationGeneration, canAcceptPlayback, assetError == nil else { return false }
            generation &+= 1
            let requestGeneration = generation
            timeline = sequence
            activeRequest = request
            currentAction = request.action
            currentRoutine = request.routine
            currentSnapshot = nil
            isSleeping = false
            elapsed = 0
            lastTimestamp = nil
            decodedFrames.removeAll(keepingCapacity: true)
            setAnimating(true)
            guard generation == requestGeneration, canAcceptPlayback, timeline != nil else { return false }
            fillBuffer(startingAt: 0)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fillBuffer(startingAt start: Int) {
        guard prefetchTask == nil, let timeline, let root = resourceDirectory, let manifest else { return }
        let currentGeneration = generation
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                for index in start..<min(timeline.frameCount, start + bufferCapacity - 1) {
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { return }
                    if decodedFrames[index] != nil { continue }
                    let snapshot = timeline.snapshot(atFrame: index)
                    let frame = try await SampleImageDecoder.decode(
                        url: root.appendingPathComponent(snapshot.file), canvas: manifest.canvasPixels
                    )
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { return }
                    let current = currentSnapshot?.timelineFrameIndex ?? 0
                    if index >= current, index < current + bufferCapacity {
                        decodedFrames[index] = frame
                    }
                }
                guard generation == currentGeneration else { return }
                prefetchTask = nil
                if playbackLink == nil, isAnimating, !isSuspended, let initial = decodedFrames[0] {
                    let snapshot = timeline.snapshot(atFrame: 0)
                    guard commit(initial, snapshot: snapshot) else { return }
                    startClock()
                }
            } catch is CancellationError {
                // The next generation owns the buffer and task reference.
            } catch {
                guard generation == currentGeneration else { return }
                prefetchTask = nil
                fail(error)
            }
        }
    }

    private func startClock() {
        guard playbackLink == nil, isAnimating, !isSuspended, timeline != nil, window != nil else { return }
        let target = SampleDisplayLinkTarget(owner: self)
        let link = displayLink(target: target, selector: #selector(SampleDisplayLinkTarget.tick(_:)))
        linkTarget = target
        playbackLink = link
        updateFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func updateFrameRate() {
        let rate = Float(min(Double(preferredFramesPerSecond), manifest?.framesPerSecond ?? 30))
        playbackLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    fileprivate func advance(_ link: CADisplayLink) {
        displayLinkCallbackCount &+= 1
        guard !isSuspended, let timeline else { return }
        let now = link.targetTimestamp
        // A blocked UI turn must not jump across an entire planted walk.
        let delta = lastTimestamp.map { min(2 / timeline.framesPerSecond, max(0, now - $0)) } ?? 0
        lastTimestamp = now
        let candidateTime = elapsed + delta
        let snapshot = timeline.snapshot(at: candidateTime)
        guard let image = decodedFrames[snapshot.timelineFrameIndex] else {
            bufferUnderrunCount &+= 1
            // The authored time, image, and root all stay at the held frame.
            fillBuffer(startingAt: snapshot.timelineFrameIndex)
            return
        }
        if snapshot.timelineFrameIndex != currentSnapshot?.timelineFrameIndex {
            guard commit(image, snapshot: snapshot) else { return }
        } else if snapshot.isComplete { currentSnapshot = snapshot }
        elapsed = candidateTime
        if snapshot.isComplete { finish(); return }
        decodedFrames = decodedFrames.filter {
            $0.key >= snapshot.timelineFrameIndex && $0.key < snapshot.timelineFrameIndex + bufferCapacity
        }
        fillBuffer(startingAt: snapshot.timelineFrameIndex + 1)
    }

    @discardableResult
    private func commit(_ image: SampleDecodedFrame, snapshot: SampleTimelineSnapshot) -> Bool {
        let expectedGeneration = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let accepted = onFrame?(snapshot) ?? true
        // A host update can synchronously deliver occlusion or cancellation.
        // Never restore the stale image after that callback cleared playback.
        guard generation == expectedGeneration, !isSuspended, timeline != nil else {
            CATransaction.commit()
            return false
        }
        guard accepted else {
            CATransaction.commit()
            cancelPlayback(showRest: true)
            return false
        }
        currentSnapshot = snapshot
        present(image)
        commitFirefly(snapshot)
        CATransaction.commit()
        return true
    }

    private func present(_ image: SampleDecodedFrame) {
        currentImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.image
        CATransaction.commit()
        submittedFrameCount &+= 1
    }

    private func finish() {
        let sleeps = activeRequest?.sleepsAtEnd == true
        let completedRoutine = activeRequest?.routine
        let next = queuedRequest
        stopClockAndLoading()
        let stoppedGeneration = generation
        timeline = nil
        activeRequest = nil
        queuedRequest = nil
        currentAction = nil
        currentRoutine = nil
        clearFirefly()
        if let completedRoutine {
            completedRoutineCount &+= 1
            lastCompletedRoutine = completedRoutine
        }
        isSleeping = sleeps
        onPlaybackStopped?()
        guard generation == stoppedGeneration, !isSuspended else { return }
        if sleeps, let sleepImage {
            present(sleepImage)
            currentSnapshot = nil
        }
        if let next {
            // Don't rearm autonomous behavior between the queued requests.
            begin(next)
            if timeline != nil { return }
        }
        setAnimating(false)
    }

    /// False means a callback installed newer playback; the caller must not
    /// overwrite that request after this teardown returns.
    @discardableResult
    private func cancelPlayback(showRest: Bool) -> Bool {
        let hadPlayback = timeline != nil
        let changedSleep = isSleeping
        stopClockAndLoading()
        let stoppedGeneration = generation
        timeline = nil
        currentSnapshot = nil
        activeRequest = nil
        queuedRequest = nil
        currentAction = nil
        currentRoutine = nil
        clearFirefly()
        isSleeping = false
        if hadPlayback { onPlaybackStopped?() }
        guard generation == stoppedGeneration else { return false }
        if showRest, let restImage, currentImage?.image !== restImage.image { present(restImage) }
        if isAnimating { setAnimating(false) }
        else if changedSleep { onAnimationStateChanged?(false) }
        return generation == stoppedGeneration
    }

    private func stopClockAndLoading() {
        generation &+= 1
        playbackLink?.invalidate()
        playbackLink = nil
        linkTarget = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        decodedFrames.removeAll(keepingCapacity: true)
        lastTimestamp = nil
    }

    private func setAnimating(_ value: Bool) {
        guard value != isAnimating else { return }
        isAnimating = value
        onAnimationStateChanged?(value)
    }

    private func fail(_ error: Error) {
        assetError = error.localizedDescription
        cancelPlayback(showRest: true)
        onAssetError?(assetError ?? "Character playback is unavailable.")
    }

    private func configureFirefly() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fireflyLayer.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        fireflyLayer.masksToBounds = true
        fireflyLayer.isHidden = true
        fireflyLayer.opacity = 0
        // Vector geometry only; no CA animation, timer, extra window, or hit view.
        for (radius, alpha) in [(10.0, 0.06), (7.0, 0.12), (4.5, 0.22)] {
            let glow = CAShapeLayer()
            glow.frame = fireflyLayer.bounds
            glow.path = CGPath(ellipseIn: CGRect(x: 14 - radius, y: 14 - radius, width: 2 * radius, height: 2 * radius), transform: nil)
            glow.fillColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.18, alpha: alpha).cgColor
            fireflyLayer.addSublayer(glow)
        }
        fireflyWings.frame = fireflyLayer.bounds
        fireflyWings.fillColor = NSColor(srgbRed: 1, green: 0.95, blue: 0.67, alpha: 0.66).cgColor
        fireflyLayer.addSublayer(fireflyWings)
        let core = CAShapeLayer()
        core.frame = fireflyLayer.bounds
        core.path = CGPath(ellipseIn: CGRect(x: 11.8, y: 11.3, width: 4.4, height: 5.4), transform: nil)
        core.fillColor = NSColor(srgbRed: 1, green: 0.94, blue: 0.59, alpha: 1).cgColor
        core.shadowColor = NSColor(srgbRed: 1, green: 0.74, blue: 0.20, alpha: 1).cgColor
        core.shadowOpacity = 0.7
        core.shadowRadius = 3
        core.shadowOffset = .zero
        fireflyLayer.addSublayer(core)
        imageLayer.addSublayer(fireflyLayer)
        CATransaction.commit()
    }

    /// Called only inside commit's disabled-action transaction after host acceptance.
    private func commitFirefly(_ snapshot: SampleTimelineSnapshot) {
        guard let request = activeRequest, request.routine == .firefly, let playbackManifest,
              let pose = FireflyMotion.pose(for: snapshot, manifest: playbackManifest,
                                           direction: request.direction, stationary: request.stationary) else {
            clearFirefly()
            return
        }
        fireflyLayer.position = CGPoint(x: pose.position.x, y: pose.position.y)
        fireflyLayer.setAffineTransform(CGAffineTransform(scaleX: petDisplaySize.scale, y: petDisplaySize.scale))
        fireflyLayer.opacity = Float(pose.opacity)
        fireflyLayer.isHidden = false
        let wings = CGMutablePath()
        let spread = 5.3 * pose.wingSpread
        wings.addEllipse(in: CGRect(x: 14 - spread, y: 14.8, width: spread, height: 2.7))
        wings.addEllipse(in: CGRect(x: 14, y: 14.8, width: spread, height: 2.7))
        fireflyWings.path = wings
    }

    private func clearFirefly() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fireflyLayer.isHidden = true
        fireflyLayer.opacity = 0
        CATransaction.commit()
    }

    private struct Request {
        let clips: [SampleClipID]
        let action: PetAction?
        var sleepsAtEnd = false
        var routine: PetRoutine?
        var direction: SampleClipID = .walkLeft
        var stationary = false
    }
}

@MainActor
private final class SampleDisplayLinkTarget: NSObject {
    private weak var owner: PetRenderView?
    init(owner: PetRenderView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.advance(link)
    }
}
