import AppKit
import QuartzCore
import SprigletCore

/// A small, transparent companion window in the screen's unobscured top strip.
/// The art is made of separate eye and pupil layers so later gaze behaviors do
/// not need to replace the desktop character or redraw a bitmap every frame.
@MainActor
final class TopBarEyesController {
    let panel: NSPanel
    let eyes: TopBarEyesView
    var onReturn: (() -> Void)?
    var onDragOut: ((CGPoint) -> Void)?
    var onDragProgress: ((CGPoint) -> Void)?
    var onDragFinished: ((CGPoint) -> Void)?
    private(set) var isVisible = false
    private var anchor = CGRect.zero
    private var gazeTimer: Timer?
    private var motionAllowed = true
    private var clickThrough = false
    private var isDraggingOut = false
    private var blinkDeadline: CFTimeInterval = 0
    private var glideRange: ClosedRange<CGFloat> = -8...8

    init() {
        eyes = TopBarEyesView(frame: CGRect(origin: .zero, size: TopBarEyePlacement.size))
        panel = TopBarEyePanel(contentRect: eyes.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = "Spriglet eyes"
        panel.identifier = NSUserInterfaceItemIdentifier("spriglet.topBarEyes")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.contentView = eyes
        panel.collectionBehavior = [.canJoinAllApplications, .fullScreenPrimary,
                                    .fullScreenDisallowsTiling, .transient, .ignoresCycle]
        eyes.onReturn = { [weak self] in self?.onReturn?() }
        eyes.onDragOut = { [weak self] point in self?.onDragOut?(point) }
        eyes.onDragProgress = { [weak self] point in self?.onDragProgress?(point) }
        eyes.onDragFinished = { [weak self] point in self?.onDragFinished?(point) }
    }

    func setAllSpaces(_ enabled: Bool) {
        if enabled { panel.collectionBehavior.insert(.canJoinAllSpaces) }
        else { panel.collectionBehavior.remove(.canJoinAllSpaces) }
    }

    func setClickThrough(_ enabled: Bool) {
        clickThrough = enabled
        panel.ignoresMouseEvents = enabled
    }

    func setMotionAllowed(_ allowed: Bool) {
        motionAllowed = allowed
        eyes.setMotionAllowed(allowed)
        if allowed && isVisible && !isDraggingOut { startGaze() }
        else { stopGaze() }
    }

    /// Keep the eye panel tracking the original mouse gesture while the full
    /// character follows underneath it. Hiding only the artwork preserves the
    /// mouse-up event even when the pointer leaves the narrow menu bar.
    func setDraggingOut(_ dragging: Bool) {
        isDraggingOut = dragging
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eyes.layer?.opacity = dragging ? 0 : 1
        CATransaction.commit()
        if dragging { stopGaze() }
        else if motionAllowed && isVisible { startGaze() }
    }

    @discardableResult
    func show(on screen: NSScreen, animated: Bool) -> Bool {
        guard let target = TopBarEyePlacement.target(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea
        ) else { return false }
        anchor = target
        glideRange = screen.auxiliaryTopRightArea == nil && screen.auxiliaryTopLeftArea == nil
            ? -8...8 : -4...0
        panel.setFrame(target, display: true)
        panel.ignoresMouseEvents = clickThrough
        if !isVisible {
            panel.alphaValue = animated ? 0 : 1
            panel.orderFrontRegardless()
            isVisible = true
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        }
        eyes.look(toward: NSEvent.mouseLocation, from: panel.frame.midpoint, animated: false)
        blinkDeadline = CACurrentMediaTime() + 4.5
        if motionAllowed { startGaze() }
        return true
    }

    func hide(animated: Bool = false) {
        guard isVisible else { return }
        stopGaze()
        isVisible = false
        setDraggingOut(false)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible else { return }
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                }
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func startGaze() {
        guard gazeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGaze() }
        }
        RunLoop.main.add(timer, forMode: .common)
        gazeTimer = timer
    }

    private func stopGaze() {
        gazeTimer?.invalidate()
        gazeTimer = nil
    }

    private func updateGaze() {
        guard isVisible, motionAllowed, !isDraggingOut else { return }
        let pointer = NSEvent.mouseLocation
        eyes.look(toward: pointer, from: panel.frame.midpoint, animated: true)

        // A very small, damped glide gives the pair life without chasing the
        // pointer across menu items or leaving its reserved space by the notch.
        let nearBar = abs(pointer.y - anchor.midY) < 100
        let desiredShift = nearBar
            ? min(glideRange.upperBound, max(glideRange.lowerBound, (pointer.x - anchor.midX) * 0.06))
            : 0
        let nextX = panel.frame.minX + (anchor.minX + desiredShift - panel.frame.minX) * 0.16
        if abs(nextX - panel.frame.minX) > 0.15 {
            panel.setFrameOrigin(CGPoint(x: nextX, y: anchor.minY))
        }
        let now = CACurrentMediaTime()
        if now >= blinkDeadline {
            eyes.blink()
            blinkDeadline = now + Double.random(in: 4.5...8.5)
        }
    }
}

/// AppKit normally constrains panels below the menu bar. This panel receives
/// only rectangles already validated against NSScreen's visible top areas.
@MainActor
private final class TopBarEyePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private extension CGRect {
    var midpoint: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
final class TopBarEyesView: NSView {
    var onReturn: (() -> Void)?
    var onDragOut: ((CGPoint) -> Void)?
    var onDragProgress: ((CGPoint) -> Void)?
    var onDragFinished: ((CGPoint) -> Void)?
    private let pupils: [CAGradientLayer]
    private let eyeLayers: [CALayer]
    private var dragStart: CGPoint?
    private var dragDidLeave = false
    private var lastGaze = CGPoint.zero
    private var motionAllowed = true

    override init(frame frameRect: NSRect) {
        let left = Self.makeEye()
        let right = Self.makeEye()
        pupils = [left.pupil, right.pupil]
        eyeLayers = [left.container, right.container]
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        left.container.frame = CGRect(x: 5, y: 3, width: 17, height: 20)
        right.container.frame = CGRect(x: 26, y: 3, width: 17, height: 20)
        layer?.addSublayer(left.container)
        layer?.addSublayer(right.container)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("spriglet.topBarEyes.interaction")
        setAccessibilityLabel("Acorn's eyes in the menu bar")
        setAccessibilityHelp("Click to return Acorn to the desktop, or drag downward to place Acorn.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:).") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setMotionAllowed(_ allowed: Bool) { motionAllowed = allowed }

    func look(toward target: CGPoint, from center: CGPoint, animated: Bool) {
        let dx = min(2.2, max(-2.2, (target.x - center.x) / 170))
        let dy = min(1.1, max(-1.1, (target.y - center.y) / 240))
        guard abs(dx - lastGaze.x) > 0.15 || abs(dy - lastGaze.y) > 0.15 else { return }
        lastGaze = CGPoint(x: dx, y: dy)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || !motionAllowed)
        if animated && motionAllowed { CATransaction.setAnimationDuration(0.19) }
        for pupil in pupils {
            pupil.position = CGPoint(x: 8.5 + dx, y: 10 + dy)
        }
        CATransaction.commit()
    }

    func blink() {
        guard motionAllowed else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = [1, 0.12, 1]
        animation.keyTimes = [0, 0.42, 1]
        animation.duration = 0.26
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        for eye in eyeLayers { eye.add(animation, forKey: "blink") }
    }

    override func mouseDown(with event: NSEvent) {
        dragDidLeave = false
        dragStart = window?.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        if !dragDidLeave, start.y - point.y > 34 {
            dragDidLeave = true
            onDragOut?(point)
        }
        if dragDidLeave { onDragProgress?(point) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragDidLeave = false }
        if dragDidLeave {
            onDragFinished?(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
        } else {
            onReturn?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onReturn?()
        return true
    }

    private static func makeEye() -> (container: CALayer, pupil: CAGradientLayer) {
        let container = CALayer()
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let cream = CAGradientLayer()
        cream.frame = CGRect(x: 0, y: 0, width: 17, height: 20)
        cream.cornerRadius = 9
        cream.colors = [NSColor(red: 1, green: 0.96, blue: 0.82, alpha: 1).cgColor,
                        NSColor(red: 0.79, green: 0.67, blue: 0.49, alpha: 1).cgColor]
        cream.startPoint = CGPoint(x: 0.3, y: 1)
        cream.endPoint = CGPoint(x: 0.8, y: 0)
        cream.masksToBounds = true
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.26
        container.shadowRadius = 1.5
        container.shadowOffset = CGSize(width: 0, height: -0.5)
        container.addSublayer(cream)

        let pupil = CAGradientLayer()
        pupil.bounds = CGRect(x: 0, y: 0, width: 14.5, height: 17)
        pupil.position = CGPoint(x: 8.5, y: 10)
        pupil.cornerRadius = 7.5
        pupil.colors = [NSColor(red: 0.27, green: 0.22, blue: 0.18, alpha: 1).cgColor,
                        NSColor(red: 0.07, green: 0.055, blue: 0.05, alpha: 1).cgColor]
        pupil.startPoint = CGPoint(x: 0.2, y: 1)
        pupil.endPoint = CGPoint(x: 0.8, y: 0)
        cream.addSublayer(pupil)

        let highlight = CALayer()
        highlight.frame = CGRect(x: 3, y: 11.5, width: 3.1, height: 3.1)
        highlight.cornerRadius = 1.55
        highlight.backgroundColor = NSColor(red: 1, green: 0.94, blue: 0.75, alpha: 0.95).cgColor
        pupil.addSublayer(highlight)

        let lid = CAShapeLayer()
        let curve = CGMutablePath()
        curve.move(to: CGPoint(x: 1.5, y: 17))
        curve.addQuadCurve(to: CGPoint(x: 15.5, y: 17), control: CGPoint(x: 8.5, y: 21.5))
        lid.path = curve
        lid.fillColor = nil
        lid.strokeColor = NSColor(red: 0.28, green: 0.24, blue: 0.17, alpha: 0.52).cgColor
        lid.lineWidth = 0.8
        lid.lineCap = .round
        container.addSublayer(lid)
        return (container, pupil)
    }
}
