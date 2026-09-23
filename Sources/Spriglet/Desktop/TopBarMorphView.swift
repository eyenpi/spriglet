import AppKit
import QuartzCore

/// A transient, pointer-driven bridge between the authored Acorn artwork and
/// the exact eye artwork used in the menu bar. The two overlapping lobes share
/// one continuous mask; as they narrow and separate, the cap and leaf fold away.
@MainActor
final class TopBarMorphView: NSView {
    private let shell = CAGradientLayer()
    private let shellMask = CAShapeLayer()
    private let cap = CAGradientLayer()
    private let capMask = CAShapeLayer()
    private let leaf = CAShapeLayer()
    private let eyes = TopBarEyesView(frame: CGRect(origin: .zero, size: CGSize(width: 48, height: 26)))
    private(set) var progress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        shell.colors = [NSColor(red: 0.68, green: 0.70, blue: 0.45, alpha: 1).cgColor,
                        NSColor(red: 0.35, green: 0.45, blue: 0.30, alpha: 1).cgColor]
        shell.startPoint = CGPoint(x: 0.3, y: 1)
        shell.endPoint = CGPoint(x: 0.75, y: 0)
        shell.mask = shellMask
        layer?.addSublayer(shell)

        cap.colors = [NSColor(red: 0.79, green: 0.59, blue: 0.39, alpha: 1).cgColor,
                      NSColor(red: 0.51, green: 0.32, blue: 0.20, alpha: 1).cgColor]
        cap.startPoint = CGPoint(x: 0.3, y: 1)
        cap.endPoint = CGPoint(x: 0.6, y: 0)
        cap.mask = capMask
        layer?.addSublayer(cap)

        leaf.fillColor = NSColor(red: 0.43, green: 0.56, blue: 0.32, alpha: 1).cgColor
        layer?.addSublayer(leaf)

        eyes.setAccessibilityElement(false)
        addSubview(eyes)
        updateGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:).") }

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    func setProgress(_ value: CGFloat) {
        guard value.isFinite else { return }
        let next = min(1, max(0, value))
        guard abs(next - progress) > 0.0001 else { return }
        progress = next
        updateGeometry()
    }

    static func progress(distanceFromTop distance: CGFloat) -> CGFloat {
        guard distance.isFinite else { return 0 }
        return min(1, max(0, (190 - distance) / 190))
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let w = bounds.width
        let h = bounds.height
        let p = progress
        let split = Self.smooth(0.16, 0.98, p)
        let leftCenter = CGPoint(x: Self.mix(w * 0.42, w / 2 - 10.5, split),
                                 y: Self.mix(h * 0.39, h / 2, split))
        let rightCenter = CGPoint(x: Self.mix(w * 0.58, w / 2 + 10.5, split),
                                  y: Self.mix(h * 0.39, h / 2, split))
        let radiusX = Self.mix(w * 0.23, 8.5, split)
        let radiusY = Self.mix(h * 0.32, 10, split)
        let path = CGMutablePath()
        for center in [leftCenter, rightCenter] {
            path.addEllipse(in: CGRect(x: center.x - radiusX, y: center.y - radiusY,
                                       width: radiusX * 2, height: radiusY * 2))
        }
        // Keep a single soft silhouette until the eye forms visibly separate.
        let bridge = 1 - Self.smooth(0.53, 0.72, p)
        if bridge > 0.001 {
            let bridgeX = w * 0.23 * bridge
            let bridgeY = h * 0.33 * bridge
            path.addEllipse(in: CGRect(x: w / 2 - bridgeX, y: h * 0.39 - bridgeY,
                                       width: bridgeX * 2, height: bridgeY * 2))
        }

        let capWidth = Self.mix(w * 0.64, 24, split)
        let capHeight = Self.mix(h * 0.17, 3, split)
        let capBase = Self.mix(h * 0.57, h * 0.55, split)
        let capPath = CGMutablePath()
        capPath.move(to: CGPoint(x: w / 2 - capWidth / 2, y: capBase))
        capPath.addQuadCurve(to: CGPoint(x: w / 2 + capWidth / 2, y: capBase),
                             control: CGPoint(x: w / 2, y: capBase + capHeight * 2))
        capPath.addQuadCurve(to: CGPoint(x: w / 2 - capWidth / 2, y: capBase),
                             control: CGPoint(x: w / 2, y: capBase - capHeight * 0.4))
        capPath.closeSubpath()

        let leafScale = 1 - Self.smooth(0.20, 0.67, p)
        let leafPath = CGMutablePath()
        let leafBase = CGPoint(x: w * 0.55, y: h * 0.71)
        leafPath.move(to: leafBase)
        leafPath.addQuadCurve(to: CGPoint(x: leafBase.x + w * 0.22 * leafScale,
                                          y: leafBase.y + h * 0.17 * leafScale),
                                   control: CGPoint(x: leafBase.x + w * 0.05 * leafScale,
                                                    y: leafBase.y + h * 0.24 * leafScale))
        leafPath.addQuadCurve(to: leafBase,
                                   control: CGPoint(x: leafBase.x + w * 0.20 * leafScale,
                                                    y: leafBase.y + h * 0.02 * leafScale))
        leafPath.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shell.frame = bounds
        shellMask.frame = bounds
        shellMask.path = path
        let warmth = Self.smooth(0.47, 0.93, p)
        shell.colors = [
            Self.color(from: (0.68, 0.70, 0.45), to: (1.0, 0.96, 0.82), progress: warmth),
            Self.color(from: (0.35, 0.45, 0.30), to: (0.79, 0.67, 0.49), progress: warmth)
        ]
        shell.opacity = Float(Self.smooth(0.06, 0.30, p) * (1 - Self.smooth(0.82, 1, p)))
        cap.frame = bounds
        capMask.frame = bounds
        capMask.path = capPath
        cap.opacity = Float(Self.smooth(0.06, 0.30, p) * (1 - Self.smooth(0.31, 0.76, p)))
        leaf.frame = bounds
        leaf.path = leafPath
        leaf.opacity = cap.opacity
        let eyeY = Self.mix(h * 0.39, h / 2, split)
        eyes.frame = CGRect(x: w / 2 - 24, y: eyeY - 13, width: 48, height: 26)
        let eyeScale = Self.mix(0.45, 1, Self.smooth(0.44, 1, p))
        eyes.layer?.transform = CATransform3DMakeScale(eyeScale, eyeScale, 1)
        eyes.layer?.opacity = Float(Self.smooth(0.18, 0.78, p))
        CATransaction.commit()
    }

    private static func mix(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }

    private static func smooth(_ start: CGFloat, _ end: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, (value - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    private static func color(from start: (CGFloat, CGFloat, CGFloat), to end: (CGFloat, CGFloat, CGFloat),
                              progress: CGFloat) -> CGColor {
        NSColor(red: mix(start.0, end.0, progress),
                green: mix(start.1, end.1, progress),
                blue: mix(start.2, end.2, progress), alpha: 1).cgColor
    }
}
