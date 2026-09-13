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
    private(set) var currentSnapshot: SampleTimelineSnapshot?
    private(set) var submittedFrameCount: UInt64 = 0
    private(set) var displayLinkCallbackCount: UInt64 = 0
    private(set) var bufferUnderrunCount: UInt64 = 0
    private(set) var manifest: SproutSampleManifest?
    private(set) var assetError: String?
    private(set) var imageOffset = CGPoint.zero
    /// Reads the child layer geometry used for presentation, independently of
    /// the requested offset, so native validation can detect a missed update.
    var actualImageLayerOffset: CGPoint {
        CGPoint(x: imageLayer.frame.minX - bounds.minX, y: imageLayer.frame.minY - bounds.minY)
    }
    var hasActiveDisplayLink: Bool { playbackLink != nil }
    var bufferedFrameCount: Int { decodedFrames.count }
    var displaySize: NSSize {
        manifest.map { NSSize(width: $0.displaySizePoints.width, height: $0.displaySizePoints.height) }
            ?? NSSize(width: 224, height: 224)
    }
    var sampleDuration: TimeInterval {
        duration(of: [.idle, .walkRight, .pet, .settle])
    }
    var walkDuration: TimeInterval { max(clipDuration(.walkLeft), clipDuration(.walkRight)) }
    func actionDuration(_ action: PetAction) -> TimeInterval { duration(of: request(for: action).clips) }
    func clipDuration(_ clip: SampleClipID) -> TimeInterval { duration(of: [clip]) }

    private let imageLayer = CALayer()
    private var resourceDirectory: URL?
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
        do {
            let root = resourceDirectory ?? Bundle.main.url(forResource: "SproutSample", withExtension: nil)
            guard let root else { throw SampleManifestError.invalid("Bundled Sprout character sample is missing.") }
            self.resourceDirectory = root
            let metadata = try SproutSampleManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
            let rest = try SampleImageDecoder.decodeImmediately(url: root.appendingPathComponent(metadata.restFrame), canvas: metadata.canvasPixels)
            let sleep = try SampleImageDecoder.decodeImmediately(url: root.appendingPathComponent(metadata.sleepFrame), canvas: metadata.canvasPixels)
            manifest = metadata
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
        // Authored root distances are expressed in the fixed display size.
        // A resize ends that request while preserving its precise final origin.
        if newSize != frame.size, isAnimating { cancelPlayback(showRest: true) }
        super.setFrameSize(newSize)
        updateImageLayerFrame()
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
    func play(_ action: PetAction) {
        guard !isSuspended else { return }
        guard !(action == .fallAsleep && isSleeping), !(action == .wakeUp && !isSleeping) else { return }
        let next = request(for: action)
        if isAnimating { queuedRequest = action == currentAction ? nil : next }
        else { begin(next) }
    }

    func playWalk(_ clip: SampleClipID) {
        guard clip == .walkLeft || clip == .walkRight, !isSuspended else { return }
        cancelPlayback(showRest: true)
        begin(Request(clips: [clip], action: nil))
    }

    func playSample(walk: SampleClipID) {
        guard walk == .walkLeft || walk == .walkRight, !isSuspended else { return }
        cancelPlayback(showRest: true)
        begin(Request(clips: [.idle, walk, .pet, .settle], action: nil))
    }

    func rootOffsets(for clips: [SampleClipID]) -> [SamplePoint]? {
        guard let manifest, let sequence = try? SampleTimeline(manifest: manifest, clips: clips) else { return nil }
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

    private func begin(_ request: Request) {
        guard !isSuspended, let manifest, assetError == nil else { return }
        if request.clips.isEmpty {
            let wasAnimating = isAnimating
            let changedSleep = isSleeping != request.sleepsAtEnd
            isSleeping = request.sleepsAtEnd
            currentAction = nil
            currentSnapshot = nil
            if let image = isSleeping ? sleepImage : restImage { present(image) }
            setAnimating(false)
            if !wasAnimating, changedSleep { onAnimationStateChanged?(false) }
            return
        }
        do {
            let sequence = try SampleTimeline(manifest: manifest, clips: request.clips)
            guard onPlaybackWillStart?(sequence) ?? true else { return }
            generation &+= 1
            timeline = sequence
            activeRequest = request
            currentAction = request.action
            currentSnapshot = nil
            isSleeping = false
            elapsed = 0
            lastTimestamp = nil
            decodedFrames.removeAll(keepingCapacity: true)
            setAnimating(true)
            fillBuffer(startingAt: 0)
        } catch { fail(error) }
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
        let next = queuedRequest
        stopClockAndLoading()
        timeline = nil
        activeRequest = nil
        queuedRequest = nil
        currentAction = nil
        isSleeping = sleeps
        onPlaybackStopped?()
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

    private func cancelPlayback(showRest: Bool) {
        let hadPlayback = timeline != nil
        let changedSleep = isSleeping
        stopClockAndLoading()
        timeline = nil
        currentSnapshot = nil
        activeRequest = nil
        queuedRequest = nil
        currentAction = nil
        isSleeping = false
        if hadPlayback { onPlaybackStopped?() }
        if showRest, let restImage, currentImage?.image !== restImage.image { present(restImage) }
        if isAnimating { setAnimating(false) }
        else if changedSleep { onAnimationStateChanged?(false) }
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

    private struct Request {
        let clips: [SampleClipID]
        let action: PetAction?
        var sleepsAtEnd = false
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
