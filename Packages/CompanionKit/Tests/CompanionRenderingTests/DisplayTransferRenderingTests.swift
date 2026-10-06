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

        let openGeometry = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                        housing: Rect(x: 2_000, y: 2_000, width: 10, height: 10)),
        ], heldBounds: surfaces.heldBounds)
        let controlFrame = copy(frame, dragGeometry: openGeometry)
        let openImage = try render(controlFrame)
        let paintedGap = (0..<420).flatMap { y in (300..<420).map { Point(x: Double($0), y: Double(y)) } }
            .filter { alpha(openImage, x: Int($0.x), y: Int($0.y)) > 0.05 && controlFrame.contains($0) }
        #expect(!paintedGap.isEmpty, "The no-gap-clip control must paint silhouette pixels in the physical gap")
        #expect(paintedGap.allSatisfy { alpha(image, x: Int($0.x), y: Int($0.y)) == 0 },
                "Display clipping must remove every control-painted gap pixel")
        #expect(paintedGap.allSatisfy { !frame.contains($0) && controlFrame.contains($0) },
                "Shared picking must match the gap pixels removed from rendering")
    }

    @Test("Housing clip removes pixels the unclipped transfer frame would paint")
    func housingClipIsNonVacuous() throws {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                  home: Rect(x: 260, y: 0, width: 180, height: 30), floor: 380)
        let housing = Rect(x: 500, y: 0, width: 20, height: 50)
        let geometry = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 0, y: 0, width: 450, height: 420),
                        housing: Rect(x: 350, y: 0, width: 80, height: 35)),
            DragSurface(bounds: Rect(x: 500, y: 0, width: 220, height: 420), housing: housing),
        ], heldBounds: Rect(x: 55, y: 0, width: 610, height: 380))
        var pose = CharacterPose(); pose.arm = 0.95
        let frame = CompanionSnapshot(scene: scene, presence: .playing, phase: .held, pose: pose,
                                      feet: Point(x: 480, y: 95), windowAnchor: Point(x: 480, y: 95),
                                      rotation: 0, openness: 1, homeGrip: 0.8,
                                      homeAttachment: Point(x: 470, y: 24), dragGeometry: geometry,
                                      time: 0, gesture: nil, canCatch: false)
        let clipped = try render(frame)
        let fullyOpen = DragGeometry(surfaces: [
            DragSurface(bounds: scene.bounds, housing: Rect(x: 2_000, y: 2_000, width: 10, height: 10)),
        ], heldBounds: geometry.heldBounds)
        let control = try render(copy(frame, dragGeometry: fullyOpen))
        let paintedHousing = (Int(housing.minY)..<Int(housing.maxY)).flatMap { y in
            (Int(housing.minX)..<Int(housing.maxX)).map { Point(x: Double($0), y: Double(y)) }
        }.filter { alpha(control, x: Int($0.x), y: Int($0.y)) > 0.05 && controlFrameContains($0, frame: frame, geometry: fullyOpen) }
        #expect(!paintedHousing.isEmpty,
                "The housing control must overlap painted silhouette or attachment pixels")
        #expect(paintedHousing.allSatisfy { alpha(clipped, x: Int($0.x), y: Int($0.y)) == 0 },
                "The finite housing rectangle must clip all pixels painted by the control")
        #expect(paintedHousing.allSatisfy { !frame.contains($0) },
                "Picking and rendering must both exclude housing pixels")
        let validPixels = (0..<420).flatMap { y in (520..<720).map { Point(x: Double($0), y: Double(y)) } }
            .filter { alpha(clipped, x: Int($0.x), y: Int($0.y)) > 0.05 }
        #expect(!validPixels.isEmpty, "Housing clipping must leave nearby valid display pixels visible")
    }

    @Test("Fixed global canvas is pixel-continuous through an engine display transfer")
    func fixedCanvasTransferContinuity() throws {
        let source = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                   home: Rect(x: 260, y: 0, width: 180, height: 30), floor: 380)
        let destination = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 640, height: 420),
                                        home: Rect(x: 430, y: 0, width: 160, height: 30), floor: 380)
        let sourceFrame = Rect(x: 0, y: 0, width: 720, height: 420)
        let destinationFrame = Rect(x: 800, y: 0, width: 640, height: 420)
        let delta = DesktopDragCoordinates.translation(from: sourceFrame, to: destinationFrame)
        #expect(delta == Point(x: -800, y: 0))
        let sourceSurface = DragSurface(bounds: sourceFrame, housing: source.home)
        let destinationInSource = DragSurface(
            bounds: Rect(x: 800, y: 0, width: 640, height: 420),
            housing: Rect(x: 800 + destination.home.x, y: destination.home.y,
                          width: destination.home.width, height: destination.home.height))
        let beforeGeometry = DragGeometry(surfaces: [sourceSurface, destinationInSource],
                                          heldBounds: Rect(x: 55, y: source.ceiling,
                                                           width: 1_330, height: source.floor - source.ceiling))
        var engine = CompanionEngine(scene: source)
        let initial = engine.snapshot
        let press = try visiblePoint(in: initial)
        engine.send(.pointerPressed(press))
        let didBegin = engine.beginDesktopDrag(geometry: beforeGeometry)
        #expect(didBegin)
        let desiredGlobalFeet = Point(x: 760, y: 220)
        let pointerDelta = desiredGlobalFeet - initial.feet
        engine.send(.pointerDragged(press + pointerDelta))
        engine.advance(by: 0.5)
        let before = engine.snapshot
        #expect(before.phase == .held && engine.hasPointerCapture)
        #expect(abs(before.feet.x - desiredGlobalFeet.x) < 10)

        let fullSurface = DragGeometry(surfaces: [
            DragSurface(bounds: Rect(x: 0, y: 0, width: 1_440, height: 420),
                        housing: Rect(x: 2_000, y: 2_000, width: 10, height: 10)),
        ], heldBounds: beforeGeometry.heldBounds)
        let controlFrame = copy(before, dragGeometry: fullSurface)
        let control = try render(controlFrame, width: 1_440, height: 420)
        let gapControlPixels = (0..<420).flatMap { y in (720..<800).map { Point(x: Double($0), y: Double(y)) } }
            .filter { alpha(control, x: Int($0.x), y: Int($0.y)) > 0.05 && controlFrame.contains($0) }
        #expect(!gapControlPixels.isEmpty,
                "The continuous-surface control must paint the body while its global center overlaps the gap")

        let beforePixels = try render(before, width: 1_440, height: 420)
        #expect(gapControlPixels.allSatisfy { alpha(beforePixels, x: Int($0.x), y: Int($0.y)) == 0 })
        #expect(gapControlPixels.allSatisfy { controlFrame.contains($0) && !before.contains($0) },
                "Transfer-aware picking must exclude the same gap pixels removed by rendering")
        let beforeTime = engine.time
        let destinationA = DragSurface(bounds: Rect(x: -800, y: 0, width: 720, height: 420),
                                      housing: Rect(x: -800 + source.home.x, y: source.home.y,
                                                    width: source.home.width, height: source.home.height))
        let afterGeometry = DragGeometry(surfaces: [destinationA,
                                                    DragSurface(bounds: destination.bounds, housing: destination.home)],
                                         heldBounds: Rect(x: -745, y: destination.ceiling,
                                                          width: 1_330, height: destination.floor - destination.ceiling))
        let didTransfer = engine.transferDrag(scene: destination, translation: delta, geometry: afterGeometry)
        #expect(didTransfer)
        let after = engine.snapshot
        #expect(engine.time == beforeTime)
        #expect(after.feet + Point(x: 800, y: 0) == before.feet)
        #expect(after.homeAttachment + Point(x: 800, y: 0) == before.homeAttachment)
        let afterPixels = try render(after, width: 1_440, height: 420, globalXOffset: 800)
        let mismatches = (0..<420).reduce(into: 0) { count, y in
            for x in 0..<1_440 where abs(alpha(beforePixels, x: x, y: y) - alpha(afterPixels, x: x, y: y)) > 0.01 {
                count += 1
            }
        }
        #expect(mismatches == 0, "Retargeting changed the fixed-global silhouette or attachment pixels")
    }

    private func copy(_ frame: CompanionSnapshot, dragGeometry: DragGeometry?) -> CompanionSnapshot {
        CompanionSnapshot(scene: frame.scene, presence: frame.presence, phase: frame.phase, pose: frame.pose,
                          feet: frame.feet, windowAnchor: frame.windowAnchor, rotation: frame.rotation,
                          openness: frame.openness, homeGrip: frame.homeGrip,
                          homeAttachment: frame.homeAttachment, dragGeometry: dragGeometry,
                          time: frame.time, gesture: frame.gesture, canCatch: frame.canCatch)
    }
    private func controlFrameContains(_ point: Point, frame: CompanionSnapshot, geometry: DragGeometry) -> Bool {
        copy(frame, dragGeometry: geometry).contains(point)
    }
    private func visiblePoint(in frame: CompanionSnapshot) throws -> Point {
        let bounds = frame.hitBounds
        for y in stride(from: bounds.minY, through: bounds.maxY, by: 1) {
            for x in stride(from: bounds.minX, through: bounds.maxX, by: 1) {
                let point = Point(x: x, y: y)
                if frame.contains(point) { return point }
            }
        }
        throw NSError(domain: "DisplayTransferRenderingTests", code: 1)
    }
    private func render(_ frame: CompanionSnapshot, width: Int = 720, height: Int = 420,
                        globalXOffset: Double = 0) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.cgContext.translateBy(x: 0, y: CGFloat(height)); context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: globalXOffset, y: 0)
        MallowRenderer().draw(frame)
        return bitmap
    }
    private func alpha(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        image.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}
