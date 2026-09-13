import AppKit
import SpriteKit
import SprigletCore

/// A procedural character with finite authored clips. SKView is contained rather
/// than subclassed, as required by its SDK header.
@MainActor
final class PetRenderView: NSView, @MainActor SKViewDelegate {
    /// Also sends `false` when an explicit reset changes a static nap to neutral.
    /// The callback always observes the updated `isSleeping` value.
    var onAnimationStateChanged: ((Bool) -> Void)?

    private(set) var isAnimating = false
    private(set) var isSleeping = false
    private(set) var currentAction: PetAction?

    /// Completed scene-update callbacks, not GPU draws or presented frames.
    var sceneUpdateCount: UInt64 { petScene.sceneUpdateCount }
    /// Render-delegate invocations, including decisions to skip a frame.
    private(set) var viewRenderCallbackCount: UInt64 = 0

    private let spriteView = SKView(frame: .zero)
    private let petScene = PrototypePetScene(size: CGSize(width: 220, height: 240))
    private var queuedAction: PetAction?
    private var isSuspended = false
    private var needsPresentation = true
    /// A delegate decision, not proof that a GPU frame was presented. The scene
    /// update counter remains the independent evidence that SpriteKit ran it.
    private var hasAllowedInitialFrame = false
    private var windowObservation: NotificationCenter.ObservationToken?

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureRenderer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRenderer()
    }

    isolated deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }

    private func configureRenderer() {
        spriteView.frame = bounds
        spriteView.autoresizingMask = [.width, .height]
        spriteView.allowsTransparency = true
        spriteView.preferredFramesPerSecond = 60
        spriteView.delegate = self
        addSubview(spriteView)
        petScene.onClipFinished = { [weak self] sleeping in self?.finishClip(sleeping: sleeping) }
        spriteView.presentScene(petScene)
        spriteView.isPaused = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        guard let window else {
            spriteView.isPaused = true
            return
        }
        windowObservation = NotificationCenter.default.addObserver(
            of: window, for: PetWindowOcclusionChanged.self
        ) { [weak self] _ in self?.requestPresentation() }
        requestPresentation()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestPresentation()
    }

    func setPreferredFramesPerSecond(_ framesPerSecond: Int) {
        spriteView.preferredFramesPerSecond = max(1, framesPerSecond)
    }

    func play() { play(.react) }

    /// Keeps one pending action; the latest request wins at a clip boundary.
    /// A repeated current action coalesces it and clears an older queued request.
    /// An awake action requested during a nap includes an authored wake transition.
    func play(_ action: PetAction) {
        guard !isSuspended else { return }
        if isAnimating {
            queuedAction = action == currentAction ? nil : action
        } else {
            beginClip(action)
        }
    }

    /// Stops frame processing and cancels active/queued clips. Resuming presents
    /// neutral; until then, the last frame can remain visible if its host does.
    /// A never-rendered visible host gets one neutral frame even while suspended.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        cancelClips()
        if suspended { updateRenderReadiness() } else { requestPresentation() }
    }

    func resetPose() {
        cancelClips()
        requestPresentation()
    }

    /// Tests transformed painted body, feet and leaves in local coordinates.
    /// The ground shadow and transparent margins are excluded.
    func containsPet(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let spritePoint = spriteView.convert(point, from: self)
        return petScene.containsPet(at: petScene.convertPoint(fromView: spritePoint))
    }

    private func beginClip(_ action: PetAction) {
        guard !(action == .fallAsleep && isSleeping), !(action == .wakeUp && !isSleeping) else { return }
        currentAction = action
        petScene.request(action)
        setAnimating(true)
        requestPresentation()
    }

    private func finishClip(sleeping: Bool) {
        isSleeping = sleeping
        currentAction = nil
        if let next = queuedAction {
            queuedAction = nil
            beginClip(next)
            if currentAction != nil { return }
        }
        setAnimating(false)
    }

    private func cancelClips() {
        let changedRestingPose = isSleeping
        queuedAction = nil
        currentAction = nil
        isSleeping = false
        petScene.requestReset()
        if isAnimating {
            setAnimating(false)
        } else if changedRestingPose {
            onAnimationStateChanged?(false)
        }
    }

    private func setAnimating(_ animating: Bool) {
        guard isAnimating != animating else { return }
        isAnimating = animating
        onAnimationStateChanged?(animating)
    }

    private func requestPresentation() {
        needsPresentation = true
        updateRenderReadiness()
    }

    private var hostIsVisible: Bool {
        window?.isVisible == true && window?.occlusionState.contains(.visible) == true
    }

    private func updateRenderReadiness() {
        // Ordering a cold paused window in must still reveal its static pose.
        // Hidden hosts get no warm-up loop, and an existing pause stays immediate.
        spriteView.isPaused = !hostIsVisible || (isSuspended && hasAllowedInitialFrame)
    }

    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        viewRenderCallbackCount &+= 1
        guard hostIsVisible, !isSuspended || !hasAllowedInitialFrame else {
            view.isPaused = true
            return false
        }
        guard needsPresentation || isAnimating || petScene.hasPendingRequest else {
            // Pause after the final pose was submitted. Neither neutral idle nor
            // a static closed-eye nap keeps the render callback running.
            view.isPaused = true
            return false
        }
        needsPresentation = false
        hasAllowedInitialFrame = true
        return true
    }
}

/// AppKit's stable notification, delivered through Foundation's macOS 26 API.
private struct PetWindowOcclusionChanged: NotificationCenter.MainActorMessage {
    typealias Subject = NSWindow

    static var name: Notification.Name { NSWindow.didChangeOcclusionStateNotification }

    static func makeMessage(_ notification: Notification) -> Self? { Self() }
}
