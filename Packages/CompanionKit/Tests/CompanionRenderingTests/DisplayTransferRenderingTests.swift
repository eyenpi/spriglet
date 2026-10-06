import AppKit
import Testing
@testable import CompanionCore
@testable import CompanionRendering

@Suite("Display transfer rendering") @MainActor struct DisplayTransferRenderingTests {
    @Test("One character clips to the union of display surfaces across a transparent gap")
    func unionClip() throws {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                  home: Rect(x: 260, y: 0, width: 180, height: 30), floor: 380, scale: 1.2)
        let surfaces = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 0, y: 0, width: 300, height: 420), housing: Rect(x: 250, y: 0, width: 50, height: 35)),
            DragSurface(bounds: Rect(x: 420, y: 0, width: 300, height: 420), housing: Rect(x: 500, y: 0, width: 100, height: 35)),
        ], heldBounds: Rect(x: 55, y: 40, width: 610, height: 340))
        var pose = CharacterPose(); pose.arm = 0.8
        let frame = CompanionSnapshot(scene: scene, presence: .playing, phase: .held, pose: pose,
                                      feet: Point(x: 360, y: 220), windowAnchor: Point(x: 360, y: 220),
                                      rotation: 0, openness: 1, homeGrip: 0,
                                      homeAttachment: Point(x: 530, y: 36), dragGeometry: surfaces,
                                      time: 0, gesture: nil, canCatch: false)
        let image = try render(frame)
        #expect(alpha(image, x: 295, y: 175) > 0.05)
        #expect(alpha(image, x: 340, y: 175) == 0)
        #expect(alpha(image, x: 410, y: 175) == 0)
        #expect(alpha(image, x: 425, y: 175) > 0.05)
        #expect(!frame.contains(Point(x: 340, y: 175)))
        #expect(frame.contains(Point(x: 425, y: 175)))
    }

    private func render(_ frame: CompanionSnapshot) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 420,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 720, height: 420))
        context.cgContext.translateBy(x: 0, y: 420); context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        MallowRenderer().draw(frame)
        return bitmap
    }
    private func alpha(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        image.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}
