import AppKit

/// Paper and ink echo Meet Mallow's postcard; the silhouette is native vector art.
@MainActor final class IntakeBubbleView: NSView {
    static let paper = adaptive("Paper", light: (0.94, 0.90, 0.99), dark: (0.23, 0.19, 0.29))
    static let ink = adaptive("Ink", light: (0.27, 0.20, 0.36), dark: (0.94, 0.88, 0.99))
    static let outline = adaptive("Outline", light: (0.63, 0.52, 0.76), dark: (0.65, 0.53, 0.77))
    static let accent = adaptive("Accent", light: (0.40, 0.28, 0.55), dark: (0.53, 0.39, 0.67))
    static let reviewInk = adaptive("ReviewInk", light: (0.47, 0.29, 0.05), dark: (1.0, 0.79, 0.43))
    static let reviewFill = adaptive("ReviewFill", light: (1.0, 0.94, 0.75), dark: (0.38, 0.29, 0.15))
    private static func adaptive(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: NSColor.Name("MallowIntake" + name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }
    var tailX: CGFloat = 160 { didSet { if tailX != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 1, y: 12, width: bounds.width - 2, height: max(0, bounds.height - 13))
        // A single contour avoids a seam where the tail meets the paper.
        let x = min(max(tailX, 30), bounds.width - 30), radius: CGFloat = 18
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX + radius, y: body.minY))
        path.line(to: NSPoint(x: x - 12, y: body.minY))
        path.curve(to: NSPoint(x: x, y: 1), controlPoint1: NSPoint(x: x - 5, y: 12), controlPoint2: NSPoint(x: x - 4, y: 3))
        path.curve(to: NSPoint(x: x + 12, y: 12), controlPoint1: NSPoint(x: x + 4, y: 3), controlPoint2: NSPoint(x: x + 5, y: 12))
        path.line(to: NSPoint(x: body.maxX - radius, y: body.minY))
        path.curve(to: NSPoint(x: body.maxX, y: body.minY + radius), controlPoint1: NSPoint(x: body.maxX, y: body.minY), controlPoint2: NSPoint(x: body.maxX, y: body.minY))
        path.line(to: NSPoint(x: body.maxX, y: body.maxY - radius))
        path.curve(to: NSPoint(x: body.maxX - radius, y: body.maxY), controlPoint1: NSPoint(x: body.maxX, y: body.maxY), controlPoint2: NSPoint(x: body.maxX, y: body.maxY))
        path.line(to: NSPoint(x: body.minX + radius, y: body.maxY))
        path.curve(to: NSPoint(x: body.minX, y: body.maxY - radius), controlPoint1: NSPoint(x: body.minX, y: body.maxY), controlPoint2: NSPoint(x: body.minX, y: body.maxY))
        path.line(to: NSPoint(x: body.minX, y: body.minY + radius))
        path.curve(to: NSPoint(x: body.minX + radius, y: body.minY), controlPoint1: NSPoint(x: body.minX, y: body.minY), controlPoint2: NSPoint(x: body.minX, y: body.minY))
        path.close()
        Self.paper.setFill(); path.fill(); Self.outline.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Retains native button semantics, keyboard navigation and VoiceOver actions.
@MainActor final class IntakeBubbleButton: KeyboardButton {
    var primary = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        NSSize(width: imagePosition == .imageOnly ? 28 : max(46, (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width + 24), height: 30)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let color = primary ? IntakeBubbleView.accent : IntakeBubbleView.ink
        if primary || isHighlighted {
            color.withAlphaComponent(isEnabled ? (primary ? 1 : 0.12) : 0.35).setFill(); shape.fill()
        }
        let ink = (primary ? NSColor.white : IntakeBubbleView.ink).withAlphaComponent(isEnabled ? 1 : 0.4)
        if imagePosition == .imageOnly, let image {
            let size: CGFloat = 13
            let symbolRect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            let tinted = NSImage(size: NSSize(width: size, height: size), flipped: false) { target in
                image.draw(in: target)
                ink.setFill(); target.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: symbolRect)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: ink]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
        if window?.firstResponder === self {
            IntakeBubbleView.outline.setStroke(); shape.lineWidth = 2; shape.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
