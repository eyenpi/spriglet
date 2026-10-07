import AppKit
import CompanionCore

@MainActor private enum MallowPalette {
    static let ink = color(0x252647)
    static let feet = color(0xDFD3F7)
    static let blush = color(0xE8AABD, alpha: 0.35)
    static let shadow = color(0x9182BD, alpha: 0.13)
    static let bodyGradient = NSGradient(starting: color(0xEEE5FF), ending: color(0xCBB8EF))!
}

@MainActor private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

@MainActor private func stroke(_ path: NSBezierPath, _ width: CGFloat = 2.3, _ ink: NSColor = MallowPalette.ink) {
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    ink.setStroke(); path.stroke()
}

@MainActor private func oval(_ rect: NSRect, fill: NSColor, outline: Bool = false, outlineWidth: CGFloat = 1.9) {
    let path = NSBezierPath(ovalIn: rect); fill.setFill(); path.fill()
    if outline { stroke(path, outlineWidth) }
}

@MainActor private func native(_ point: Point) -> NSPoint { NSPoint(x: point.x, y: point.y) }
@MainActor private func native(_ rect: Rect) -> NSRect { NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
@MainActor private func concatenate(_ transform: CharacterTransform) {
    let affine = NSAffineTransform()
    affine.translateX(by: transform.origin.x, yBy: transform.origin.y)
    affine.rotate(byRadians: transform.rotation)
    affine.scaleX(by: transform.scaleX, yBy: transform.scaleY); affine.concat()
}

/// The renderer caches a native path from the shared, immutable artwork.
@MainActor private struct MallowArtwork {
    let body: NSBezierPath
    init() {
        let body = NSBezierPath()
        body.move(to: native(MallowGeometry.bodyCurves[0].start))
        for curve in MallowGeometry.bodyCurves {
            body.curve(to: native(curve.end), controlPoint1: native(curve.control1), controlPoint2: native(curve.control2))
        }
        body.close()
        body.lineWidth = 2.3; body.lineCapStyle = .round; body.lineJoinStyle = .round
        self.body = body
    }
}

@MainActor private func drawMallow(_ pose: CharacterPose, artwork: MallowArtwork, center: NSPoint, scale: CGFloat = 1, drawShadow: Bool = true, rotation: Double = 0, drawArms: Bool = true, clipFace: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    concatenate(CharacterTransform(origin: Point(x: center.x, y: center.y), rotation: rotation, scaleX: scale, scaleY: scale))
    if drawShadow {
        oval(native(MallowGeometry.groundShadowBounds), fill: MallowPalette.shadow)
    }
    // 60% of each stride is planted. During that phase, feet move backwards
    // relative to the body at the same speed as the desktop window moves forward.
    for foot in MallowGeometry.feet(for: pose) {
        oval(native(foot), fill: MallowPalette.feet, outline: true)
    }
    NSGraphicsContext.saveGraphicsState()
    concatenate(MallowGeometry.bodyTransform(for: pose))
    let body = artwork.body
    MallowPalette.bodyGradient.draw(in: body, angle: 90)
    MallowPalette.ink.setStroke(); body.stroke()
    // Separate arms can gesture while the body continues to breathe.
    for side in (drawArms ? [-1.0, 1.0] : []) {
        let armSwing = sin(pose.gaitPhase * 2 * .pi + (side < 0 ? .pi : 0)) * pose.walk * 6
        let raise = (side > 0 ? pose.arm * 29 : pose.arm * 12) + armSwing
        let arm = NSBezierPath()
        arm.move(to: NSPoint(x: side * 47, y: -29 - raise))
        arm.curve(to: NSPoint(x: side * 34, y: -15 - raise * 0.6),
                  controlPoint1: NSPoint(x: side * (56 + pose.arm * 6), y: -14 - raise),
                  controlPoint2: NSPoint(x: side * 46, y: -9 - raise * 0.5))
        stroke(arm, 2)
    }
    let faceX = pose.look + pose.facing * 18
    let eyeSpacing = 14 - abs(pose.facing) * 5
    NSGraphicsContext.saveGraphicsState()
    if clipFace { body.addClip() }
    let faceTransform = NSAffineTransform(); faceTransform.translateX(by: 0, yBy: pose.lookY); faceTransform.concat()
    for side in [-1.0, 1.0] {
        let x = side * eyeSpacing + faceX
        let eyeAlpha = side * pose.facing < 0 ? 1 - min(1, abs(pose.facing) / 0.82) : 1
        if pose.eyes < 0.12 {
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: x - 4, y: -47))
            lid.curve(to: NSPoint(x: x + 4, y: -47), controlPoint1: NSPoint(x: x - 2, y: -44), controlPoint2: NSPoint(x: x + 2, y: -44))
            stroke(lid, 2.5, MallowPalette.ink.withAlphaComponent(eyeAlpha))
        } else {
            oval(NSRect(x: x - 3.4, y: -47 - 4.1 * pose.eyes, width: 6.8, height: 8.2 * pose.eyes), fill: MallowPalette.ink.withAlphaComponent(eyeAlpha))
        }
        oval(NSRect(x: side * 25 + faceX - 5, y: -37, width: 10, height: 4), fill: MallowPalette.blush)
    }
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: faceX - 4, y: -37))
    smile.curve(to: NSPoint(x: faceX + 4, y: -37), controlPoint1: NSPoint(x: faceX - 2, y: -32), controlPoint2: NSPoint(x: faceX + 2, y: -32))
    stroke(smile, 2)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

/// Stateless vector rendering. Owns no timers, behavior or native windows.
@MainActor public struct MallowRenderer {
    private let artwork = MallowArtwork()
    public init() {}
    public func draw(_ frame: CompanionSnapshot) {
        let scene = frame.scene, scale = scene.scale
        NSGraphicsContext.saveGraphicsState()
        let visible = NSBezierPath(); visible.windingRule = .nonZero
        if let dragGeometry = frame.dragGeometry {
            for rect in dragGeometry.visibleRectangles { appendWoundRect(rect, to: visible, reversed: false) }
        } else {
            appendWoundRect(scene.bounds, to: visible, reversed: false)
            appendWoundRect(scene.homeOcclusion, to: visible, reversed: true)
        }
        visible.addClip()
        drawMallow(frame.pose, artwork: artwork,
                   center: NSPoint(x: frame.feet.x, y: frame.feet.y - 7 * scale), scale: scale,
                   drawShadow: frame.phase == .grounded, rotation: frame.rotation,
                   drawArms: false, clipFace: true)
        drawHands(frame)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func appendWoundRect(_ rect: Rect, to path: NSBezierPath, reversed: Bool) {
        let points = reversed
            ? [Point(x: rect.minX, y: rect.minY), Point(x: rect.minX, y: rect.maxY),
               Point(x: rect.maxX, y: rect.maxY), Point(x: rect.maxX, y: rect.minY)]
            : [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
               Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
        path.move(to: native(points[0]))
        for point in points.dropFirst() { path.line(to: native(point)) }
        path.close()
    }
    private func drawHands(_ frame: CompanionSnapshot) {
        let s = frame.scene.scale
        for hand in frame.geometry.hands {
            let arm = NSBezierPath(); arm.move(to: native(hand.arm.start))
            arm.curve(to: native(hand.arm.end), controlPoint1: native(hand.arm.control1), controlPoint2: native(hand.arm.control2))
            stroke(arm, 2 * s)
            oval(native(hand.palm), fill: MallowPalette.feet, outline: true, outlineWidth: 1.9 * s)
        }
    }
}

/// The app icon shares the character's vector source; no second asset pipeline.
@MainActor public struct MallowIconRenderer {
    private let artwork = MallowArtwork()
    public init() {}
    public func image(pixels: Int) throws -> NSBitmapImageRep {
        guard pixels > 0 && pixels <= 4096 else { throw BitmapRenderingError.invalidSize }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw BitmapRenderingError.allocationFailure }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw BitmapRenderingError.contextFailure }
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(pixels)); context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        color(0xEEE5FF).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        NSGradient(starting: color(0xF5F0FF), ending: color(0xD5C5F0))!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
        drawMallow(CharacterPose(), artwork: artwork, center: NSPoint(x: 512, y: 780), scale: 6.7, drawShadow: true)
        NSGraphicsContext.restoreGraphicsState()
        // Core Graphics draws into 32-bit surfaces. Convert the result to a
        // no-alpha RGB image for the icon PNGs after rendering succeeds.
        guard let rgb = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let source = bitmap.cgImage else { throw BitmapRenderingError.contextFailure }
        rgb.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = rgb.makeImage() else { throw BitmapRenderingError.contextFailure }
        return NSBitmapImageRep(cgImage: image)
    }
}
