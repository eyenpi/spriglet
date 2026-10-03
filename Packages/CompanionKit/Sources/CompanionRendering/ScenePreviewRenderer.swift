import AppKit
import CompanionCore

public enum BitmapRenderingError: Error, Equatable { case invalidSize, allocationFailure, contextFailure, encodingFailure }

/// A finite local preview uses the exact production renderer, not a second pet.
@MainActor public struct ScenePreviewRenderer {
    private let character = MallowRenderer()
    public init() {}
    public func draw(_ snapshot: CompanionSnapshot, pointer: Point? = nil, pressed: Bool = false) {
        let scene = snapshot.scene
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: scene.bounds.width, height: scene.bounds.height).fill()
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.93, green: 0.9, blue: 1, alpha: 1),
                                  ending: NSColor(calibratedRed: 1, green: 0.93, blue: 0.89, alpha: 1))!
        gradient.draw(in: NSRect(x: 20, y: 0, width: scene.bounds.width - 40, height: scene.bounds.height - 20), angle: 80)
        character.draw(snapshot)
        NSColor(calibratedRed: 0.145, green: 0.149, blue: 0.278, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: scene.home.x, y: scene.home.y, width: scene.home.width, height: scene.home.height), xRadius: 16, yRadius: 16).fill()
        NSColor(calibratedRed: 0.318, green: 0.298, blue: 0.416, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: scene.home.midX - 3, y: scene.home.minY + 17, width: 6, height: 6)).fill()
        if let pointer { drawPointer(pointer, pressed: pressed) }
    }
    private func drawPointer(_ point: Point, pressed: Bool) {
        let ink = NSColor(calibratedRed: 0.38, green: 0.34, blue: 0.44, alpha: 1)
        if pressed {
            ink.withAlphaComponent(0.35).setStroke()
            let halo = NSBezierPath(ovalIn: NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)); halo.lineWidth = 2; halo.stroke()
        }
        let path = NSBezierPath(); path.move(to: NSPoint(x: point.x, y: point.y))
        path.line(to: NSPoint(x: point.x + 2, y: point.y + 19)); path.line(to: NSPoint(x: point.x + 7, y: point.y + 13))
        path.line(to: NSPoint(x: point.x + 15, y: point.y + 12)); path.close()
        NSColor.white.setFill(); path.fill(); ink.setStroke(); path.lineWidth = 1.2; path.stroke()
    }
    public func image(_ snapshot: CompanionSnapshot, pointer: Point? = nil, pressed: Bool = false) throws -> NSBitmapImageRep {
        let bounds = snapshot.scene.bounds
        guard bounds.width >= 1 && bounds.height >= 1 && bounds.width <= 4096 && bounds.height <= 4096 else { throw BitmapRenderingError.invalidSize }
        let width = Int(bounds.width), height = Int(bounds.height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw BitmapRenderingError.allocationFailure }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw BitmapRenderingError.contextFailure }
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height)); context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        draw(snapshot, pointer: pointer, pressed: pressed)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
