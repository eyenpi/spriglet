import AppKit
import CompanionCore

@MainActor private enum MallowPalette {
    static let bodyGradient = NSGradient(starting: color(0xEEE5FF), ending: color(0xCBB8EF))!
}

@MainActor private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

@MainActor private func stroke(_ path: NSBezierPath, _ width: CGFloat = 2.3, _ ink: NSColor = color(0x252647)) {
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    ink.setStroke(); path.stroke()
}

@MainActor private func oval(_ rect: NSRect, fill: NSColor, outline: Bool = false) {
    let path = NSBezierPath(ovalIn: rect); fill.setFill(); path.fill()
    if outline { stroke(path, 1.9) }
}

@MainActor private func drawMallow(_ pose: CharacterPose, time: Double, center: NSPoint, scale: CGFloat = 1, drawShadow: Bool = true, rotation: Double = 0, drawArms: Bool = true, clipFace: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byRadians: rotation)
    transform.scale(by: scale); transform.concat()
    if drawShadow {
        oval(NSRect(x: -49, y: -2, width: 98, height: 10), fill: color(0x9182BD, alpha: 0.13))
    }
    // 60% of each stride is planted. During that phase, feet move backwards
    // relative to the body at the same speed as the desktop window moves forward.
    for side in [-1.0, 1.0] {
        let phase = (pose.gaitPhase + (side < 0 ? 0.5 : 0)).truncatingRemainder(dividingBy: 1)
        let swing = max(0, (phase - 0.6) / 0.4)
        let stepX = phase < 0.6 ? 11 - phase / 0.6 * 22 : -11 + (1 - cos(swing * .pi)) * 11
        let x = side * (28 - abs(pose.facing) * 9) + stepX * pose.walk * pose.direction
        let y = -sin(swing * .pi) * 10 * pose.walk
        oval(NSRect(x: x - 10, y: y - 5, width: 20, height: 13), fill: color(0xDFD3F7), outline: true)
    }
    NSGraphicsContext.saveGraphicsState()
    let bodyTransform = NSAffineTransform()
    bodyTransform.translateX(by: pose.lean * 26, yBy: 0)
    bodyTransform.rotate(byRadians: pose.lean)
    bodyTransform.scaleX(by: pose.width * (1 - abs(pose.facing) * 0.07), yBy: pose.height); bodyTransform.concat()
    let body = NSBezierPath()
    body.move(to: NSPoint(x: -49, y: 0))
    body.curve(to: NSPoint(x: -61, y: -31), controlPoint1: NSPoint(x: -66, y: -1), controlPoint2: NSPoint(x: -66, y: -16))
    body.curve(to: NSPoint(x: -22, y: -77), controlPoint1: NSPoint(x: -57, y: -56), controlPoint2: NSPoint(x: -42, y: -76))
    body.curve(to: NSPoint(x: 29, y: -74), controlPoint1: NSPoint(x: -4, y: -89), controlPoint2: NSPoint(x: 16, y: -85))
    body.curve(to: NSPoint(x: 60, y: -30), controlPoint1: NSPoint(x: 46, y: -65), controlPoint2: NSPoint(x: 58, y: -48))
    body.curve(to: NSPoint(x: 49, y: 0), controlPoint1: NSPoint(x: 67, y: -12), controlPoint2: NSPoint(x: 64, y: -1))
    body.curve(to: NSPoint(x: -49, y: 0), controlPoint1: NSPoint(x: 23, y: 5), controlPoint2: NSPoint(x: -23, y: 5))
    body.close()
    MallowPalette.bodyGradient.draw(in: body, angle: 90)
    stroke(body)
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
            stroke(lid, 2.5, color(0x252647, alpha: eyeAlpha))
        } else {
            oval(NSRect(x: x - 3.4, y: -47 - 4.1 * pose.eyes, width: 6.8, height: 8.2 * pose.eyes), fill: color(0x252647, alpha: eyeAlpha))
        }
        oval(NSRect(x: side * 25 + faceX - 5, y: -37, width: 10, height: 4), fill: color(0xE8AABD, alpha: 0.35))
    }
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: faceX - 4, y: -37))
    smile.curve(to: NSPoint(x: faceX + 4, y: -37), controlPoint1: NSPoint(x: faceX - 2, y: -32), controlPoint2: NSPoint(x: faceX + 2, y: -32))
    stroke(smile, 2)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    if pose.sparkle > 0.01 {
        for index in 0..<3 {
            let angle = Double(index) * 0.65 - 1.45
            let radius = 88 + sin(time * 4 + Double(index)) * 3
            let a = NSPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            let p = NSBezierPath(); p.move(to: a)
            p.line(to: NSPoint(x: a.x + cos(angle) * 7, y: a.y + sin(angle) * 7))
            stroke(p, 3, color(0xE7BA58, alpha: pose.sparkle))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// Stateless vector rendering. Owns no timers, behavior or native windows.
@MainActor public struct MallowRenderer {
    public init() {}
    public func draw(_ frame: CompanionSnapshot) {
        let scene = frame.scene, scale = scene.scale
        NSGraphicsContext.saveGraphicsState()
        // The home housing occludes the same pixels through every phase.
        // A grab must not suddenly expose the portion still behind the notch.
        let visible = NSBezierPath(rect: NSRect(x: scene.bounds.x, y: scene.bounds.y,
                                              width: scene.bounds.width, height: scene.bounds.height))
        visible.appendRect(NSRect(x: scene.home.x, y: scene.home.y,
                                  width: scene.home.width, height: scene.home.height))
        visible.windingRule = .evenOdd; visible.addClip()
        drawMallow(frame.pose, time: frame.time,
                   center: NSPoint(x: frame.feet.x, y: frame.feet.y - 7 * scale), scale: scale,
                   drawShadow: frame.phase == .grounded, rotation: frame.rotation,
                   drawArms: false, clipFace: true)
        drawHands(frame)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawHands(_ frame: CompanionSnapshot) {
        let s = frame.scene.scale, pose = frame.pose, grip = frame.homeGrip
        let reveal = (frame.openness - 0.6) / 0.4
        let emergence = reveal * reveal * (3 - 2 * reveal)
        func blend(_ free: Point, _ home: Point) -> Point { free + (home - free) * grip }
        func bodyPoint(_ x: Double, _ y: Double) -> Point {
            let scaled = Point(x: x * pose.width * (1 - abs(pose.facing) * 0.07), y: y * pose.height)
            let leaned = Point(x: scaled.x * cos(pose.lean) - scaled.y * sin(pose.lean) + pose.lean * 26,
                               y: scaled.x * sin(pose.lean) + scaled.y * cos(pose.lean))
            return frame.feet + Point(x: leaned.x * cos(frame.rotation) - leaned.y * sin(frame.rotation),
                                      y: leaned.x * sin(frame.rotation) + leaned.y * cos(frame.rotation) - 7) * s
        }
        func native(_ point: Point) -> NSPoint { NSPoint(x: point.x, y: point.y) }
        for side in [-1.0, 1.0] {
            let gait = sin(pose.gaitPhase * 2 * .pi + (side < 0 ? .pi : 0)) * pose.walk * 6
            let raise = pose.arm * (side > 0 ? 29 : 12) + gait
            let homeShoulder = bodyPoint(side * 47, -29)
            let wave = side > 0 ? max(0, pose.arm - 0.4) * 28 * emergence : 0
            let homeHand = Point(x: frame.scene.home.midX + side * 43 * s,
                                 y: frame.scene.home.maxY + (-8 + emergence * 10 + wave) * s)
            let shoulder = blend(bodyPoint(side * 47, -29 - raise), homeShoulder)
            let hand = blend(bodyPoint(side * 34, -15 - raise * 0.6), homeHand)
            let control1 = blend(bodyPoint(side * (56 + pose.arm * 6), -14 - raise),
                                 homeShoulder + Point(x: side * 8 * s, y: -9 * s))
            let control2 = blend(bodyPoint(side * 46, -9 - raise * 0.5),
                                 homeHand + Point(x: side * 6 * s, y: 12 * s))
            let arm = NSBezierPath(); arm.move(to: native(shoulder))
            arm.curve(to: native(hand), controlPoint1: native(control1), controlPoint2: native(control2))
            stroke(arm, 2 * s)
            oval(NSRect(x: hand.x - 5 * s, y: hand.y - 3 * s, width: 10 * s, height: 8 * s), fill: color(0xDFD3F7), outline: true)
        }
    }
}

/// The app icon shares the character's vector source; no second asset pipeline.
@MainActor public struct MallowIconRenderer {
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
        drawMallow(CharacterPose(), time: 0, center: NSPoint(x: 512, y: 780), scale: 6.7, drawShadow: true)
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
