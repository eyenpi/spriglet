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

    @Test("Contained corner frames never remove production renderer pixels")
    func containedCornerPaintOracle() throws {
        let displays = [Rect(x: -1772, y: 982, width: 2560, height: 1440),
                        Rect(x: 788, y: 982, width: 2560, height: 1440)]
        for (index, display) in displays.enumerated() {
            let home = index == 0 ? Rect(x: 2330, y: 0, width: 180, height: 20)
                                  : Rect(x: 50, y: 0, width: 180, height: 20)
            let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 2560, height: 1440),
                                      home: home, floor: 1428, scale: 0.8, hasHardwareNotch: false)
            var engine = CompanionEngine(scene: scene, idleSeed: 7)
            var snapshots = [engine.snapshot]
            let initial = engine.snapshot
            let hit = initial.hitBounds
            guard let press = stride(from: hit.minY, through: hit.maxY, by: 1).flatMap({ y in
                stride(from: hit.minX, through: hit.maxX, by: 1).map { Point(x: $0, y: y) }
            }).first(where: initial.contains) else {
                Issue.record("Production engine had no visible point for corner trace")
                continue
            }
            engine.send(.pointerPressed(press))
            let target = Point(x: index == 0 ? scene.rightLimit : scene.leftLimit, y: scene.floor)
            let endpoint = press + (target - initial.feet)
            engine.send(.pointerDragged(endpoint))
            for _ in 0..<120 { engine.advance(by: 1 / 60.0) }
            engine.send(.pointerReleased(endpoint))
            if engine.snapshot.phase == .falling { snapshots.append(engine.snapshot) }
            for _ in 0..<600 {
                engine.advance(by: 1 / 60.0)
                if engine.snapshot.phase == .falling { snapshots.append(engine.snapshot); break }
            }
            for _ in 0..<900 {
                engine.advance(by: 1 / 60.0)
                if engine.snapshot.phase == .grounded { snapshots.append(engine.snapshot); break }
            }
            engine.send(.command(.hop))
            var hopSamples: [CompanionSnapshot] = []
            for _ in 0..<600 {
                engine.advance(by: 1 / 60.0)
                if engine.snapshot.phase == .jumping { hopSamples.append(engine.snapshot) }
                else if !hopSamples.isEmpty { break }
            }
            if let apex = hopSamples.min(by: { $0.feet.y < $1.feet.y }) { snapshots.append(apex) }
            for _ in 0..<900 {
                engine.advance(by: 1 / 60.0)
                if engine.snapshot.phase == .grounded { snapshots.append(engine.snapshot); break }
            }
            engine.send(.command(.returnHome))
            for _ in 0..<900 {
                engine.advance(by: 1 / 60.0)
                if engine.snapshot.phase == .catching { snapshots.append(engine.snapshot); break }
            }
            for _ in 0..<900 {
                engine.advance(by: 1 / 60.0)
                if engine.snapshot.phase == .hanging { snapshots.append(engine.snapshot); break }
            }
            for phase in [BodyPhase.falling, .grounded, .jumping, .catching, .hanging] {
                #expect(snapshots.contains(where: { $0.phase == phase }), "Corner trace missed renderer state \(phase)")
            }
            #expect(snapshots.contains(where: { $0.presence == .peek }), "Corner trace missed home/peek renderer state")

            var sawEscape = false
            for snapshot in snapshots {
                let old = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: display,
                                                      scale: snapshot.scene.scale, visibleBounds: snapshot.hitBounds)
                let next = WindowGeometry.containedFrame(old, in: display)
                guard old != next else { continue }
                sawEscape = true
                let render = try render(snapshot, width: 2560, height: 1440)
                let oldOrigin = WindowGeometry.drawingOrigin(window: old, display: display)
                let nextOrigin = WindowGeometry.drawingOrigin(window: next, display: display)
                let oldIn = Rect(x: max(old.minX, display.minX), y: max(old.minY, display.minY),
                                 width: max(0, min(old.maxX, display.maxX) - max(old.minX, display.minX)),
                                 height: max(0, min(old.maxY, display.maxY) - max(old.minY, display.minY)))
                let scanLeft = max(0, Int(floor(min(oldIn.minX, next.minX) - display.minX)))
                let scanRight = min(2560, Int(ceil(max(oldIn.maxX, next.maxX) - display.minX)))
                let scanTop = max(0, Int(floor(display.maxY - max(oldIn.maxY, next.maxY))))
                let scanBottom = min(1440, Int(ceil(display.maxY - min(oldIn.minY, next.minY))))
                var controlPaint = 0, retained = 0, added = 0, lost = 0, rgbaMismatches = 0
                var bodyFootControl = 0, handControl = 0, shadowControl = 0
                let geometry = snapshot.geometry
                let shadowY = snapshot.feet.y - 7 * snapshot.scene.scale
                for y in scanTop..<scanBottom {
                    for x in scanLeft..<scanRight {
                        let scenePoint = Point(x: Double(x) + 0.5, y: Double(y) + 0.5)
                        let oldGlobal = Point(x: old.minX + scenePoint.x + oldOrigin.x,
                                              y: old.maxY - scenePoint.y - oldOrigin.y)
                        let nextGlobal = Point(x: next.minX + scenePoint.x + nextOrigin.x,
                                               y: next.maxY - scenePoint.y - nextOrigin.y)
                        #expect(abs(oldGlobal.x - nextGlobal.x) < 0.000001
                                && abs(oldGlobal.y - nextGlobal.y) < 0.000001)
                        let global = Point(x: display.minX + scenePoint.x, y: display.maxY - scenePoint.y)
                        let oldVisible = global.x >= old.minX && global.x < old.maxX
                            && global.y >= old.minY && global.y < old.maxY
                        let nextVisible = global.x >= next.minX && global.x < next.maxX
                            && global.y >= next.minY && global.y < next.maxY
                        guard oldVisible || nextVisible else { continue }
                        let color = render.colorAt(x: x, y: y)
                        let control = [color?.redComponent ?? 0, color?.greenComponent ?? 0,
                                       color?.blueComponent ?? 0, color?.alphaComponent ?? 0]
                        if control[3] > 0 { controlPaint += 1 }
                        let oldPixel = oldVisible ? control : [CGFloat](repeating: 0, count: 4)
                        let nextPixel = nextVisible ? control : [CGFloat](repeating: 0, count: 4)
                        if oldPixel != nextPixel { rgbaMismatches += 1 }
                        if oldPixel[3] > 0 && nextPixel[3] > 0 { retained += 1 }
                        if oldPixel[3] == 0 && nextPixel[3] > 0 { added += 1 }
                        if oldPixel[3] > 0 && nextPixel[3] == 0 { lost += 1 }
                        if scenePoint.x >= snapshot.feet.x - 70 && scenePoint.x <= snapshot.feet.x + 70
                            && scenePoint.y >= snapshot.feet.y - 110 && scenePoint.y <= snapshot.feet.y + 14
                            && control[3] > 0 { bodyFootControl += 1 }
                        if geometry.hands.contains(where: { hand in
                            let xs = [hand.arm.start.x, hand.arm.control1.x, hand.arm.control2.x, hand.arm.end.x]
                            let ys = [hand.arm.start.y, hand.arm.control1.y, hand.arm.control2.y, hand.arm.end.y]
                            let bounds = Rect(x: xs.min()! - 4, y: ys.min()! - 4,
                                              width: xs.max()! - xs.min()! + 8, height: ys.max()! - ys.min()! + 8)
                            return bounds.contains(scenePoint) || hand.palm.contains(scenePoint)
                        }), control[3] > 0 { handControl += 1 }
                        if snapshot.phase == .grounded
                            && scenePoint.x >= snapshot.feet.x - 50 * snapshot.scene.scale
                            && scenePoint.x <= snapshot.feet.x + 50 * snapshot.scene.scale
                            && scenePoint.y >= shadowY - 2 * snapshot.scene.scale
                            && scenePoint.y <= shadowY + 8 * snapshot.scene.scale
                            && control[3] > 0 { shadowControl += 1 }
                    }
                }
                #expect(controlPaint > 0, "Generous full-renderer reference must be non-vacuous")
                #expect(retained > 0, "Full renderer control must paint within the old panel")
                #expect(bodyFootControl > 0, "Body/feet pixel control must be non-vacuous")
                #expect(handControl > 0, "Hand pixel control must be non-vacuous")
                if snapshot.phase == .grounded { #expect(shadowControl > 0, "Grounded shadow pixel control must be non-vacuous") }
                #expect(added == max(0, controlPaint - retained), "Added renderer pixels are counted on the global grid")
                #expect(lost == 0, "Containment lost renderer pixels")
                #expect(rgbaMismatches == added + lost, "All RGBA differences must be accounted for as added or lost paint")
            }
            #expect(sawEscape, "Corner trace must include an escaping old panel frame")
        }
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
