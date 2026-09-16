import AppKit
import QuartzCore
import SprigletCore

/// One display link selects the authored image and root offset together. A child
/// layer retains the final image without an idle timer or continuous drawing.
@MainActor
final class PetRenderView: NSView {
    var onAnimationStateChanged: ((Bool) -> Void)?
    var onPlaybackWillStart: ((CharacterTimeline) -> Bool)?
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
    private(set) var characterPackage: CharacterPackage?
    private(set) var currentPoseID = "ready"
    private(set) var playbackContext = CharacterPlaybackContext(habitatID: "desktop")
    private(set) var petDisplaySize: PetDisplaySize = .standard
    private(set) var assetError: String?
    private(set) var imageOffset = CGPoint.zero
    /// Reads the child layer geometry used for presentation, independently of
    /// the requested offset, so native validation can detect a missed update.
    var actualImageLayerOffset: CGPoint {
        CGPoint(x: imageLayer.frame.minX - bounds.minX, y: imageLayer.frame.minY - bounds.minY)
    }
    var hasActiveDisplayLink: Bool { playbackLink != nil }
    var isRestRigVisible: Bool { restRig?.isVisible == true && imageLayer.isHidden }
    var bufferedFrameCount: Int { decodedFrames.count }
    var proceduralCommitCount: UInt64 { restRig?.targetCommitCount ?? 0 }
    var finitePhraseCount: UInt64 { restRig?.finitePhraseCount ?? 0 }
    var decodedLayerBytes: Int { restRig?.decodedBytes ?? 0 }
    var activeRigAnimationCount: Int { restRig?.activeAnimationCount ?? 0 }
    var fireflyVisible: Bool { !fireflyLayer.isHidden && fireflyLayer.opacity > 0 }
    var currentFireflyPosition: CGPoint? { fireflyVisible ? fireflyLayer.position : nil }
    var currentFireflyFrame: CGRect? { fireflyVisible ? fireflyLayer.frame : nil }
    var displaySize: NSSize {
        characterPackage.map { petDisplaySize.size(for: $0.displaySizePoints) } ?? petDisplaySize.size
    }
    var sampleDuration: TimeInterval {
        duration(of: [.idle, .walkRight, .pet, .settle])
    }
    var walkDuration: TimeInterval { max(clipDuration(.walkLeft), clipDuration(.walkRight)) }
    func actionDuration(_ action: PetAction) -> TimeInterval {
        if let semanticID = phraseSemanticID(for: action), let duration = phraseDuration(semanticID) {
            return duration
        }
        guard let package = playbackPackage,
              let plan = try? package.plan(
                for: action, from: package.animationGraph.defaultPoseID, context: playbackContext
              ),
              !plan.clipIDs.isEmpty,
              let timeline = try? CharacterTimeline(package: package, plan: plan) else { return 0 }
        return timeline.duration
    }
    func clipDuration(_ clip: SampleClipID) -> TimeInterval { duration(of: [clip]) }

    private let imageLayer = CALayer()
    private let fireflyLayer = CALayer()
    private let fireflyWings = CAShapeLayer()
    private var resourceDirectory: URL?
    private var playbackManifest: SproutSampleManifest?
    private var playbackPackage: CharacterPackage?
    private var restRig: RestRigScene?
    private var restImage: SampleDecodedFrame?
    private var sleepImage: SampleDecodedFrame?
    private var currentImage: SampleDecodedFrame?
    private var decodedFrames: [Int: SampleDecodedFrame] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var timeline: CharacterTimeline?
    private var queuedRequest: Request?
    private var activeRequest: Request?
    private var activePhraseID: String?
    private var elapsed: TimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private var isSuspended = false
    private var isInteractionHeld = false
    private var isChangingDisplaySize = false
    private var preferredFramesPerSecond = 30
    private var playbackLink: CADisplayLink?
    private var linkTarget: SampleDisplayLinkTarget?
    private var bufferCapacity: Int {
        min(12, max(1, playbackPackage?.resourceBudget.maxBufferedFrames ?? 1))
    }

    override var isOpaque: Bool { false }

    init(frame: NSRect, resourceDirectory: URL?) {
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
            guard let root = resourceDirectory else { throw SampleManifestError.invalid("Bundled character artwork is missing.") }
            self.resourceDirectory = root
            let legacyURL = root.appendingPathComponent("manifest.json")
            let metadata = FileManager.default.fileExists(atPath: legacyURL.path)
                ? try SproutSampleManifest.decode(Data(contentsOf: legacyURL)) : nil
            let packageURL = root.appendingPathComponent("character.json")
            let package = if FileManager.default.fileExists(atPath: packageURL.path) {
                try CharacterPackage.decode(Data(contentsOf: packageURL))
            } else if let metadata {
                try CharacterPackage(adapting: metadata)
            } else {
                throw SampleManifestError.invalid("Bundled character metadata is missing.")
            }
            guard let restFile = package.poses[package.animationGraph.defaultPoseID]?.stillFrame else {
                throw SampleManifestError.invalid("The character's default pose has no still frame.")
            }
            let rest = try SampleImageDecoder.decodeImmediately(
                url: root.appendingPathComponent(restFile), canvas: package.canvasPixels
            )
            let sleepingPose = Self.sleepingPoseID(in: package)
            let sleep = try sleepingPose.flatMap { package.poses[$0]?.stillFrame }.map {
                try SampleImageDecoder.decodeImmediately(url: root.appendingPathComponent($0), canvas: package.canvasPixels)
            }
            manifest = metadata
            characterPackage = package
            playbackManifest = try metadata.map { try petDisplaySize.scaledManifest($0) }
            playbackPackage = try package.scaled(to: petDisplaySize)
            restImage = rest
            sleepImage = sleep
            currentPoseID = package.animationGraph.defaultPoseID
            if !package.layers.isEmpty {
                let rig = try RestRigScene(package: package, resourceDirectory: root)
                rig.onPhraseFinished = { [weak self] in self?.finishPhrase() }
                restRig = rig
                layer?.insertSublayer(rig.layer, below: imageLayer)
            }
            super.setFrameSize(displaySize)
            updateImageLayerFrame()
            showStablePose(currentPoseID, fallback: rest)
        } catch {
            assetError = error.localizedDescription
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:resourceDirectory:).") }

    isolated deinit {
        playbackLink?.invalidate()
        prefetchTask?.cancel()
        restRig?.stop()
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
        let targetSize = characterPackage.map { choice.size(for: $0.displaySizePoints) } ?? choice.size
        guard choice != petDisplaySize || frame.size != targetSize else { return }
        let wasChangingSize = isChangingDisplaySize
        isChangingDisplaySize = true
        defer { isChangingDisplaySize = wasChangingSize }
        cancelPlayback(showRest: true)
        petDisplaySize = choice
        do {
            if let manifest { playbackManifest = try choice.scaledManifest(manifest) }
            if let characterPackage { playbackPackage = try characterPackage.scaled(to: choice) }
        } catch {
            playbackManifest = nil
            fail(error)
        }
        // Attached content inherits the host's resize through its autoresizing
        // mask. Resizing it here as well would apply the parent's delta twice.
        if superview == nil {
            super.setFrameSize(targetSize)
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
        restRig?.layout(in: bounds.offsetBy(dx: imageOffset.x, dy: imageOffset.y),
                        contentsScale: window?.backingScaleFactor ?? 2)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelPlayback(showRest: false)
            restRig?.hide()
        } else if !isSuspended {
            showStablePose(currentPoseID, fallback: restImage)
        }
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        restRig?.layout(in: bounds.offsetBy(dx: imageOffset.x, dy: imageOffset.y),
                        contentsScale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        restRig?.layout(in: bounds.offsetBy(dx: imageOffset.x, dy: imageOffset.y),
                        contentsScale: window?.backingScaleFactor ?? 2)
    }

    func setPreferredFramesPerSecond(_ value: Int) {
        preferredFramesPerSecond = max(1, value)
        updateFrameRate()
    }

    /// Environment policy is an input to route selection, not renderer state.
    /// Changing it cancels any route selected under the previous constraints.
    func setPlaybackContext(_ context: CharacterPlaybackContext) {
        guard context != playbackContext else { return }
        playbackContext = context
        _ = cancelPlayback(showRest: true)
    }

    func play() { play(.react) }

    /// Holding a click freezes the exact image/root pair without waking a nap
    /// or resetting an airborne pose. Releasing resumes the same finite action.
    func setInteractionHeld(_ held: Bool) {
        guard held != isInteractionHeld else { return }
        isInteractionHeld = held
        if held {
            // Retained-layer gestures never remain live under a held interaction.
            if activePhraseID != nil {
                _ = cancelPlayback(showRest: true)
                return
            }
            restRig?.stop()
            playbackLink?.invalidate()
            playbackLink = nil
            linkTarget = nil
            lastTimestamp = nil
        } else if currentSnapshot != nil {
            startClock()
        }
    }

    /// Graceful production routine entry. Explicit diagnostic replay helpers
    /// below retain their cancellation semantics.
    @discardableResult
    func transitionRoutine(_ routine: PetRoutine, direction: SampleClipID = .walkLeft, stationary: Bool = false) -> Bool {
        let clips = routineClips(routine, direction: direction, stationary: stationary)
        guard !clips.isEmpty, canAcceptPlayback else { return false }
        let request = Request(clips: clips, action: nil, routine: routine, direction: direction, stationary: stationary)
        if hasActivePlayback { queuedRequest = request; return true }
        return begin(request)
    }

    /// State-aware playback for authored assets. The current gesture reaches
    /// its authored landing/settle, then only the latest pending intent runs.
    /// Unlike the explicit reset/replay helpers, this never resets the pose.
    @discardableResult
    func transition(to intent: SampleTransitionIntent) -> Bool {
        guard canAcceptPlayback else { return false }
        let request = Request(clips: [], action: nil, transitionIntent: intent)
        if hasActivePlayback {
            guard queuedRequest?.transitionIntent != intent else { return false }
            queuedRequest = request
            return true
        }
        return begin(request)
    }

    /// One pending request, replaced by the latest interaction. The current
    /// finite request reaches its resting boundary before that request begins.
    /// True means this request began or replaced the pending request; it does
    /// not claim that the animation has completed or even decoded its first frame.
    @discardableResult
    func play(_ action: PetAction) -> Bool {
        guard canAcceptPlayback else { return false }
        if hasActivePlayback, action == currentAction {
            queuedRequest = nil
            return false
        }
        let boundarySleeps = activeRequest?.sleepsAtEnd ?? isSleeping
        guard !(action == .fallAsleep && boundarySleeps), !(action == .wakeUp && !boundarySleeps) else { return false }
        let next = request(for: action)
        // Teardown callbacks run after the old timeline is cleared. An action
        // requested there replaces it immediately instead of becoming orphaned.
        if hasActivePlayback {
            guard queuedRequest?.action != action else { return false }
            queuedRequest = next
            return true
        }
        return begin(next)
    }

    /// Resolves an open semantic intent through the loaded character graph.
    @discardableResult
    func playIntent(_ intentID: String) -> Bool {
        guard canAcceptPlayback, Self.isValidSemanticID(intentID) else { return false }
        let request = Request(clips: [], action: nil, intentID: intentID)
        if hasActivePlayback {
            guard queuedRequest?.intentID != intentID else { return false }
            queuedRequest = request
            return true
        }
        return begin(request)
    }

    /// Starts a finite retained-layer phrase. The same one-slot coalescing rule
    /// used by image timelines applies, so callbacks cannot create two owners.
    @discardableResult
    func playPhrase(_ semanticID: String) -> Bool {
        guard canAcceptPlayback, Self.isValidSemanticID(semanticID) else { return false }
        let request = Request(clips: [], action: nil, phraseSemanticID: semanticID)
        if hasActivePlayback {
            guard queuedRequest?.phraseSemanticID != semanticID else { return false }
            queuedRequest = request
            return true
        }
        return begin(request)
    }

    /// Procedural targets are accepted only while the canonical layered pose
    /// owns presentation. They do not create a timer or animation lifecycle.
    @discardableResult
    func retarget(semanticID: String, value: SamplePoint, animated: Bool = true) -> Bool {
        guard !hasActivePlayback, !isSuspended, !isInteractionHeld,
              Self.isValidSemanticID(semanticID),
              currentPoseID == characterPackage?.animationGraph.defaultPoseID else { return false }
        return restRig?.retarget(semanticID: semanticID, value: value, animated: animated) ?? false
    }

    func playWalk(_ clip: SampleClipID) {
        guard clip == .walkLeft || clip == .walkRight, canAcceptPlayback else { return }
        guard cancelPlayback(showRest: true) else { return }
        begin(Request(clips: [clip], action: nil))
    }

    @discardableResult
    func playSample(walk: SampleClipID) -> Bool {
        guard walk == .walkLeft || walk == .walkRight, canAcceptPlayback else { return false }
        guard cancelPlayback(showRest: true) else { return false }
        return begin(Request(clips: [.idle, walk, .pet, .settle], action: nil))
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
        guard let playbackPackage,
              let sequence = try? CharacterTimeline(package: playbackPackage, clips: clips) else { return nil }
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
        Request(clips: [], action: action, phraseSemanticID: phraseSemanticID(for: action))
    }

    private func duration(of clips: [SampleClipID]) -> TimeInterval {
        guard let package = playbackPackage else { return 0 }
        return clips.reduce(0) { total, id in
            guard let clip = package.clips[id.rawValue] else { return total }
            return total + Double(clip.frames.count) / clip.framesPerSecond
        }
    }

    private var hasActivePlayback: Bool { timeline != nil || activePhraseID != nil }

    private var canAcceptPlayback: Bool {
        !isSuspended && !isChangingDisplaySize && bounds.size == displaySize
    }

    @discardableResult
    private func begin(_ proposed: Request) -> Bool {
        guard canAcceptPlayback, let package = playbackPackage, assetError == nil else { return false }
        var request = proposed
        if let phraseID = request.phraseSemanticID,
           !isSleeping, currentPoseID == package.animationGraph.defaultPoseID,
           beginPhrase(phraseID, request: request) {
            return true
        }
        if request.phraseSemanticID != nil, request.action == nil { return false }
        do {
            let plan = try animationPlan(for: request, package: package)
            request.targetPoseID = plan.endPoseID
            request.sleepsAtEnd = plan.endPoseID == Self.sleepingPoseID(in: package)
            request.clips = plan.clipIDs.compactMap(CharacterClipID.init(rawValue:))
            if let wakePlan = try? package.plan(
                for: PetAction.wakeUp, from: currentPoseID, context: playbackContext
            ),
               let first = wakePlan.clipIDs.first,
               request.clips.first?.rawValue == first {
                request.leadingWakeFrames = package.clips[first]?.frames.count ?? 0
            }
            if plan.clipIDs.isEmpty {
                return finishInstant(request, package: package)
            }
            let sequence = try CharacterTimeline(package: package, plan: plan)
            return beginTimeline(sequence, request: request)
        } catch CharacterPackageError.noRoute {
            return false
        } catch {
            fail(error)
            return false
        }
    }

    private func animationPlan(for request: Request, package: CharacterPackage) throws -> CharacterAnimationPlan {
        if let intentID = request.intentID {
            return try package.plan(for: intentID, from: currentPoseID, context: playbackContext)
        }
        if let transition = request.transitionIntent {
            return try package.plan(for: transition, from: currentPoseID, context: playbackContext)
        }
        if let action = request.action {
            return try package.plan(for: action, from: currentPoseID, context: playbackContext)
        }
        guard !request.clips.isEmpty,
              let first = package.clips[request.clips[0].rawValue],
              let last = package.clips[request.clips[request.clips.count - 1].rawValue] else {
            throw CharacterPackageError.noRoute("The requested character playlist is empty.")
        }
        var clipIDs = request.clips.map(\.rawValue)
        if first.startPoseID != currentPoseID {
            let ready = try package.plan(
                for: PetAction.wakeUp, from: currentPoseID, context: playbackContext
            )
            guard ready.endPoseID == first.startPoseID else {
                throw CharacterPackageError.noRoute("The requested playlist is not reachable from the current pose.")
            }
            clipIDs.insert(contentsOf: ready.clipIDs, at: 0)
        }
        return CharacterAnimationPlan(
            requestedIntentID: "playlist", resolvedIntentID: "playlist",
            startPoseID: currentPoseID, endPoseID: last.endPoseID, clipIDs: clipIDs
        )
    }

    @discardableResult
    private func finishInstant(_ request: Request, package: CharacterPackage) -> Bool {
        generation &+= 1
        let requestGeneration = generation
        let wasAnimating = isAnimating
        let oldSleeping = isSleeping
        currentPoseID = request.targetPoseID ?? package.animationGraph.defaultPoseID
        isSleeping = currentPoseID == Self.sleepingPoseID(in: package)
        currentAction = nil
        currentRoutine = nil
        clearFirefly()
        currentSnapshot = nil
        showStablePose(currentPoseID)
        setAnimating(false)
        if !wasAnimating, oldSleeping != isSleeping { onAnimationStateChanged?(false) }
        return generation == requestGeneration && !isSuspended
    }

    @discardableResult
    private func beginTimeline(_ sequence: CharacterTimeline, request: Request) -> Bool {
        let preparationGeneration = generation
        guard onPlaybackWillStart?(sequence) ?? true,
              generation == preparationGeneration, canAcceptPlayback, assetError == nil else { return false }
        generation &+= 1
        let requestGeneration = generation
        restRig?.hide()
        imageLayer.isHidden = false
        timeline = sequence
        activeRequest = request
        activePhraseID = nil
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
    }

    private func fillBuffer(startingAt start: Int) {
        guard prefetchTask == nil, let timeline, let root = resourceDirectory, let package = playbackPackage else { return }
        let end = min(timeline.frameCount, (currentSnapshot?.timelineFrameIndex ?? 0) + bufferCapacity)
        guard start < end else { return }
        let currentGeneration = generation
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                for index in start..<end {
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { return }
                    if decodedFrames[index] != nil { continue }
                    let snapshot = timeline.snapshot(atFrame: index)
                    let frame = try await SampleImageDecoder.decode(
                        url: root.appendingPathComponent(snapshot.file), canvas: package.canvasPixels
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
        guard playbackLink == nil, isAnimating, !isSuspended, !isInteractionHeld, timeline != nil, window != nil else { return }
        let target = SampleDisplayLinkTarget(owner: self)
        let link = displayLink(target: target, selector: #selector(SampleDisplayLinkTarget.tick(_:)))
        linkTarget = target
        playbackLink = link
        updateFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func updateFrameRate() {
        let authoredRate = timeline?.maximumFramesPerSecond ?? 30
        let rate = Float(min(Double(preferredFramesPerSecond), authoredRate))
        playbackLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    fileprivate func advance(_ link: CADisplayLink) {
        displayLinkCallbackCount &+= 1
        guard !isSuspended, let timeline else { return }
        let now = link.targetTimestamp
        // A blocked UI turn must not jump across an entire planted walk.
        let delta = lastTimestamp.map { min(2 / timeline.maximumFramesPerSecond, max(0, now - $0)) } ?? 0
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
        imageLayer.isHidden = false
        imageLayer.contents = image.image
        CATransaction.commit()
        submittedFrameCount &+= 1
    }

    private func finish() {
        let sleeps = activeRequest?.sleepsAtEnd == true
        let targetPoseID = activeRequest?.targetPoseID
        let completedRoutine = activeRequest?.routine
        let next = queuedRequest
        stopClockAndLoading()
        let stoppedGeneration = generation
        timeline = nil
        activeRequest = nil
        activePhraseID = nil
        queuedRequest = nil
        currentAction = nil
        currentRoutine = nil
        clearFirefly()
        if let completedRoutine {
            completedRoutineCount &+= 1
            lastCompletedRoutine = completedRoutine
        }
        if let targetPoseID { currentPoseID = targetPoseID }
        isSleeping = sleeps
        if next == nil {
            showStablePose(currentPoseID)
            if sleeps { currentSnapshot = nil }
        }
        onPlaybackStopped?()
        guard generation == stoppedGeneration, !isSuspended else { return }
        if let next {
            // Don't rearm autonomous behavior between the queued requests.
            begin(next)
            if hasActivePlayback { return }
            showStablePose(currentPoseID)
            if sleeps { currentSnapshot = nil }
        }
        setAnimating(false)
    }

    /// False means a callback installed newer playback; the caller must not
    /// overwrite that request after this teardown returns.
    @discardableResult
    private func cancelPlayback(showRest: Bool) -> Bool {
        let hadPlayback = hasActivePlayback
        let changedSleep = isSleeping
        stopClockAndLoading()
        let stoppedGeneration = generation
        timeline = nil
        activePhraseID = nil
        currentSnapshot = nil
        activeRequest = nil
        queuedRequest = nil
        currentAction = nil
        currentRoutine = nil
        clearFirefly()
        restRig?.stop()
        if let package = characterPackage {
            currentPoseID = package.animationGraph.defaultPoseID
        }
        isSleeping = false
        if hadPlayback { onPlaybackStopped?() }
        guard generation == stoppedGeneration else { return false }
        if showRest { showStablePose(currentPoseID, fallback: restImage) }
        else {
            restRig?.hide()
            imageLayer.isHidden = true
        }
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

    @discardableResult
    private func beginPhrase(_ semanticID: String, request: Request) -> Bool {
        guard let rig = restRig, rig.enter(poseID: currentPoseID),
              rig.playPhrase(semanticID: semanticID) else { return false }
        generation &+= 1
        let requestGeneration = generation
        imageLayer.isHidden = true
        activePhraseID = semanticID
        activeRequest = request
        currentAction = request.action
        currentRoutine = request.routine
        currentSnapshot = nil
        setAnimating(true)
        return generation == requestGeneration && rig.hasActivePhrase
    }

    private func finishPhrase() {
        guard activePhraseID != nil else { return }
        let next = queuedRequest
        stopClockAndLoading()
        restRig?.stop()
        let stoppedGeneration = generation
        activePhraseID = nil
        activeRequest = nil
        queuedRequest = nil
        currentAction = nil
        currentRoutine = nil
        onPlaybackStopped?()
        guard generation == stoppedGeneration, !isSuspended else { return }
        if let next {
            begin(next)
            if hasActivePlayback { return }
        }
        showStablePose(currentPoseID)
        setAnimating(false)
    }

    private func showStablePose(_ poseID: String, fallback: SampleDecodedFrame? = nil) {
        restRig?.stop()
        if restRig?.enter(poseID: poseID) == true {
            currentImage = restImage
            imageLayer.isHidden = true
            imageLayer.contents = nil
            return
        }
        restRig?.hide()
        let defaultPose = characterPackage?.animationGraph.defaultPoseID
        let image: SampleDecodedFrame? = if poseID == defaultPose {
            restImage
        } else if poseID == characterPackage.flatMap(Self.sleepingPoseID(in:)) {
            sleepImage
        } else {
            fallback
        }
        if let image { present(image) }
        else { imageLayer.isHidden = false }
    }

    private func phraseSemanticID(for action: PetAction) -> String? {
        switch action {
        case .blink: "blink"
        case .stretch: "breath"
        case .lookAround: "gaze"
        case .react, .fallAsleep, .wakeUp: nil
        }
    }

    private func phraseDuration(_ semanticID: String) -> TimeInterval? {
        let durations = characterPackage?.proceduralChannels.values.compactMap { channel -> TimeInterval? in
            guard channel.semanticID == semanticID || channel.semanticID?.hasPrefix(semanticID + ".") == true else {
                return nil
            }
            return (channel.durationSeconds ?? 0.16) + channel.delaySeconds
        } ?? []
        return durations.max()
    }

    private static func sleepingPoseID(in package: CharacterPackage) -> String? {
        for binding in ["transition.sleep", "petAction.fallAsleep"] {
            if let intentID = package.semanticBindings[binding],
               let poseID = package.animationGraph.intents[intentID]?.targetPoseID {
                return poseID
            }
        }
        return nil
    }

    private static func isValidSemanticID(_ value: String) -> Bool {
        (1...80).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
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
                                           direction: request.direction, stationary: request.stationary,
                                           leadingFrameCount: request.leadingWakeFrames) else {
            clearFirefly()
            return
        }
        fireflyLayer.position = CGPoint(x: pose.position.x, y: pose.position.y)
        let effectScale = displaySize.width / 224
        fireflyLayer.setAffineTransform(CGAffineTransform(scaleX: effectScale, y: effectScale))
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
        var clips: [SampleClipID]
        let action: PetAction?
        var sleepsAtEnd = false
        var routine: PetRoutine?
        var direction: SampleClipID = .walkLeft
        var stationary = false
        var transitionIntent: SampleTransitionIntent?
        var intentID: String?
        var phraseSemanticID: String?
        var targetPoseID: String?
        var leadingWakeFrames = 0
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
