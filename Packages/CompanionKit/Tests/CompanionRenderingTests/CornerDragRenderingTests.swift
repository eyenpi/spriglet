import AppKit
import Testing
@testable import CompanionCore
@testable import CompanionRendering

@Suite("Triangle corner drag canvas") @MainActor struct CornerDragRenderingTests {
    private let displays = [Rect(x: -1772, y: 982, width: 2560, height: 1440),
                            Rect(x: 788, y: 982, width: 2560, height: 1440),
                            Rect(x: 0, y: 0, width: 1512, height: 982)]

    @Test("Real corner press, held motion, seam travel and release retain all painted pixels", arguments: [0, 1])
    func cornerSequence(destination: Int) throws {
        var active = 0
        var engine = CompanionEngine(scene: scene(0), idleSeed: 7)
        let start = engine.snapshot.hitBounds.center
        #expect(engine.snapshot.contains(start))
        engine.send(.pointerPressed(start))
        let began = engine.beginDesktopDrag(geometry: desktopGeometry(0))
        #expect(began)
        let startGlobal = global(start, display: displays[0])
        let drop = Point(x: destination == 0 ? 780 : 796, y: 990)
        for step in 1...120 {
            let pointer = startGlobal + (drop - startGlobal) * (Double(step) / 120)
            engine.send(.pointerDragged(WindowGeometry.scenePoint(global: pointer, display: displays[active])))
            if engine.isDragging, !displays[active].contains(pointer), displays[destination].contains(pointer) {
                let transferred = engine.transferDrag(scene: scene(destination),
                                                      translation: DesktopDragCoordinates.translation(from: displays[active], to: displays[destination]),
                                                      geometry: desktopGeometry(destination))
                #expect(transferred)
                active = destination
                engine.send(.pointerDragged(WindowGeometry.scenePoint(global: pointer, display: displays[active])))
            }
            engine.advance(by: 1 / 60.0)
        }
        #expect(active == destination)
        let endpoint = WindowGeometry.scenePoint(global: drop, display: displays[active])
        engine.send(.pointerReleased(endpoint))
        #expect(engine.hasPendingDragRelease)
        try checkPaint(engine.snapshot, display: displays[active])
        for _ in 0..<600 where engine.hasPendingDragRelease { engine.advance(by: 1 / 60.0) }
        #expect(engine.snapshot.dragGeometry == nil)
        for _ in 0..<600 where engine.snapshot.phase != .grounded { engine.advance(by: 1 / 60.0) }
        #expect(engine.snapshot.phase == .grounded)
        let before = engine.snapshot
        let crown = before.geometry.root.apply(before.geometry.body.apply(Point(x: 0, y: -58)))
        #expect(before.contains(crown))
        engine.send(.pointerPressed(crown))
        let regrabbed = engine.beginDesktopDrag(geometry: desktopGeometry(active))
        #expect(regrabbed)
        #expect(engine.hasPointerCapture && !engine.isDragging)
        #expect(engine.snapshot.feet == before.feet && engine.snapshot.pose == before.pose)
        let down = engine.snapshot
        let requested = request(down, display: displays[active])
        let candidate = try layout(down, display: displays[active])
        #expect(requested.minY < 982 && candidate.inputFrame.minY == 982)
        #expect(candidate.canvases.count == 2,
                "The grounded corner must paint on both upper displays without extending a window onto the lower display")
        try checkPaint(down, display: displays[active], checkNegatives: true)

        let inward = destination == 0 ? -1.0 : 1.0
        engine.send(.pointerDragged(crown + Point(x: inward * 3, y: 0)))
        #expect(!engine.isDragging)
        try checkPaint(engine.snapshot, display: displays[active])
        engine.send(.pointerDragged(crown + Point(x: inward * 5, y: 0)))
        engine.advance(by: 1 / 60.0)
        #expect(engine.isDragging && engine.snapshot.phase == .held)
        try checkPaint(engine.snapshot, display: displays[active])
        engine.send(.pointerDragged(crown + Point(x: inward * 35, y: 0)))
        engine.advance(by: 0.1)
        try checkPaint(engine.snapshot, display: displays[active])

        // Put real artwork across the bottom seam, away from the main notch.
        let bottomSeam = WindowGeometry.scenePoint(global: Point(x: 1100, y: 1030), display: displays[active])
        engine.send(.pointerDragged(bottomSeam))
        for _ in 0..<60 { engine.advance(by: 1 / 60.0) }
        let across = engine.snapshot
        let seamPaint = paint(across, display: displays[active])
        #expect(seamPaint.minY < 982 && seamPaint.maxY > 982)
        let crossingLayout = try layout(across, display: displays[active])
        #expect(crossingLayout.canvases.contains { $0.display == displays[2] })
        #expect(crossingLayout.canvases.allSatisfy { canvas in
            canvas.frame.minX >= canvas.display.minX && canvas.frame.maxX <= canvas.display.maxX
                && canvas.frame.minY >= canvas.display.minY && canvas.frame.maxY <= canvas.display.maxY
        })
        try checkPaint(across, display: displays[active])
        engine.send(.pointerReleased(bottomSeam))
        try checkPaint(engine.snapshot, display: displays[active])
        for _ in 0..<600 where engine.hasPendingDragRelease { engine.advance(by: 1 / 60.0) }
        #expect(!engine.hasPointerCapture && engine.snapshot.dragGeometry == nil)
        let recovered = engine.snapshot
        let regrab = recovered.geometry.root.apply(recovered.geometry.body.apply(Point(x: 0, y: -58)))
        #expect(recovered.contains(regrab))
        engine.send(.pointerPressed(regrab))
        let recaptured = engine.beginDesktopDrag(geometry: desktopGeometry(active))
        #expect(recaptured && engine.hasPointerCapture && !engine.isDragging)
        #expect(engine.snapshot.feet == recovered.feet && engine.snapshot.pose == recovered.pose)
        try checkPaint(engine.snapshot, display: displays[active])
        engine.send(.cancelInteraction)
        #expect(engine.snapshot.phase == .hanging)
    }

    @Test("Rotated crown, raised hands and ground shadow keep their full canvas", arguments: [0.0, 0.7, -1.1])
    func transformedPaint(rotation: Double) throws {
        var pose = CharacterPose(); pose.lean = 0.25; pose.arm = 1; pose.width = 0.5
        let snapshot = CompanionSnapshot(scene: scene(0), presence: .playing, phase: .grounded,
                                         pose: pose, feet: Point(x: 2520, y: 1415), windowAnchor: Point(x: 2520, y: 1415),
                                         rotation: rotation, openness: 1, homeGrip: 0,
                                         dragGeometry: desktopGeometry(0), time: 0, gesture: nil, canCatch: false)
        try checkPaint(snapshot, display: displays[0])
    }

    private func scene(_ index: Int) -> SceneGeometry {
        let display = displays[index]
        return SceneGeometry(bounds: Rect(x: 0, y: 0, width: display.width, height: display.height),
                             home: index == 2 ? Rect(x: 663.5, y: 0, width: 185, height: 32)
                                              : Rect(x: 2330, y: 0, width: 180, height: 20),
                             floor: index == 2 ? 897 : 1428, scale: 0.8, hasHardwareNotch: index == 2)
    }
    private func desktopGeometry(_ active: Int) -> DragGeometry {
        let offsets = displays.map { Point(x: $0.minX - displays[active].minX, y: displays[active].maxY - $0.maxY) }
        let surfaces = displays.indices.map { index in
            let d = displays[index], s = scene(index), offset = offsets[index]
            return DragSurface(bounds: Rect(x: offset.x, y: offset.y, width: d.width, height: d.height),
                               housing: Rect(x: offset.x + s.home.x, y: offset.y + s.home.y,
                                             width: s.home.width, height: s.home.height))
        }
        let left = displays.indices.map { offsets[$0].x + scene($0).leftLimit }.min()!
        let right = displays.indices.map { offsets[$0].x + scene($0).rightLimit }.max()!
        let top = displays.indices.map { offsets[$0].y + scene($0).ceiling }.min()!
        let bottom = displays.indices.map { offsets[$0].y + scene($0).floor }.max()!
        return DragGeometry(surfaces: surfaces, heldBounds: Rect(x: left, y: top, width: right - left, height: bottom - top))
    }
    private func global(_ point: Point, display: Rect) -> Point {
        Point(x: display.minX + point.x, y: display.maxY - point.y)
    }
    private func request(_ snapshot: CompanionSnapshot, display: Rect) -> Rect {
        WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: display,
                                    scale: snapshot.scene.scale, visibleBounds: snapshot.dragGeometry == nil ? snapshot.hitBounds : snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded))
    }
    private func paint(_ snapshot: CompanionSnapshot, display: Rect) -> Rect {
        let bounds = snapshot.geometry.paintBounds(drawShadow: snapshot.phase == .grounded)
        let margin = 4 * snapshot.scene.scale
        return Rect(x: display.minX + bounds.minX - margin, y: display.maxY - bounds.maxY - margin,
                    width: bounds.width + 2 * margin, height: bounds.height + 2 * margin)
    }
    private func layout(_ snapshot: CompanionSnapshot, display: Rect) throws -> DesktopWindowLayout {
        try #require(WindowGeometry.desktopLayout(requested: request(snapshot, display: display),
                                                   paint: paint(snapshot, display: display), activeDisplay: display,
                                                   displays: displays))
    }

    private func checkPaint(_ snapshot: CompanionSnapshot, display: Rect, checkNegatives: Bool = false) throws {
        let envelope = paint(snapshot, display: display)
        let crop = Rect(x: floor(envelope.minX) - 16, y: floor(envelope.minY) - 16,
                        width: ceil(envelope.maxX) - floor(envelope.minX) + 32,
                        height: ceil(envelope.maxY) - floor(envelope.minY) + 32)
        let old = request(snapshot, display: display), next = try layout(snapshot, display: display)
        for scale in [1, 2] {
            let control = try render(snapshot, display: display, crop: crop, scale: scale)
            let oldImage = try render(snapshot, display: display, crop: crop, scale: scale, window: old)
            let nextImage = try render(snapshot, display: display, crop: crop, scale: scale, canvases: next.canvases)
            let pixels = control.pixelsWide * control.pixelsHigh
            var painted = 0, lost = 0, mismatched = 0, oldMismatches = 0
            var maximumByteDifference = 0
            var firstMismatch = ""
            var headPixels: [(Int, Int)] = []
            let crown = NSBezierPath()
            crown.move(to: NSPoint(x: MallowGeometry.bodyCurves[0].start.x, y: MallowGeometry.bodyCurves[0].start.y))
            for curve in MallowGeometry.bodyCurves {
                crown.curve(to: NSPoint(x: curve.end.x, y: curve.end.y),
                            controlPoint1: NSPoint(x: curve.control1.x, y: curve.control1.y),
                            controlPoint2: NSPoint(x: curve.control2.x, y: curve.control2.y))
            }
            crown.close()
            for index in 0..<pixels {
                let x = index % control.pixelsWide, y = index / control.pixelsWide
                let color = control.colorAt(x: x, y: y)!
                if color.alphaComponent > 0 {
                    painted += 1
                    let local = Point(x: crop.minX - display.minX + (Double(x) + 0.5) / Double(scale),
                                      y: display.maxY - crop.maxY + (Double(y) + 0.5) / Double(scale))
                    let canonical = snapshot.geometry.body.inverse(snapshot.geometry.root.inverse(local))
                    if canonical.y <= -40 && crown.contains(NSPoint(x: canonical.x, y: canonical.y)) { headPixels.append((x, y)) }
                    if nextImage.colorAt(x: x, y: y)!.alphaComponent == 0 { lost += 1 }
                }
                if color != nextImage.colorAt(x: x, y: y) {
                    mismatched += 1
                    if firstMismatch.isEmpty { firstMismatch = "pixel=(\(x),\(y)) reference=\(color) tiled=\(String(describing: nextImage.colorAt(x: x, y: y)))" }
                }
                for component in 0..<4 {
                    let reference = control.bitmapData![y * control.bytesPerRow + x * 4 + component]
                    let tiled = nextImage.bitmapData![y * nextImage.bytesPerRow + x * 4 + component]
                    maximumByteDifference = max(maximumByteDifference, abs(Int(reference) - Int(tiled)))
                }
                if color != oldImage.colorAt(x: x, y: y) { oldMismatches += 1 }
            }
            #expect(painted > 0 && !headPixels.isEmpty, "Full artwork and crown controls must be nonempty")
            // Independently clipped Core Graphics gradients differ by up to
            // two 8-bit quanta. No painted pixel may disappear; the wrong-origin
            // and cropped-crown controls below must still reject displacement.
            #expect(lost == 0 && maximumByteDifference <= 2 && oldMismatches == 0,
                    "Canvas changed pixels: lost=\(lost) maxByteDelta=\(maximumByteDifference) tiledMismatch=\(mismatched) oldMismatch=\(oldMismatches) phase=\(snapshot.phase) t=\(snapshot.time) scale=\(scale) \(firstMismatch)")
            if checkNegatives {
                let cut = Rect(x: old.x, y: old.y, width: old.width,
                               height: envelope.maxY - old.y - 16 * snapshot.scene.scale)
                let cropped = try render(snapshot, display: display, crop: crop, scale: scale, window: cut)
                let shifted = try render(snapshot, display: display, crop: crop, scale: scale,
                                         canvases: next.canvases, originOffset: Point(x: 0, y: 16 * snapshot.scene.scale))
                #expect(headPixels.contains { cropped.colorAt(x: $0.0, y: $0.1)!.alphaComponent == 0 },
                        "Crown crop negative control must lose actual head pixels")
                #expect(headPixels.contains { shifted.colorAt(x: $0.0, y: $0.1) != control.colorAt(x: $0.0, y: $0.1) },
                        "Wrong drawing origin negative control must change actual head pixels")
            }
        }
    }
    private func render(_ snapshot: CompanionSnapshot, display: Rect, crop: Rect, scale: Int,
                        window: Rect? = nil, canvases: [DisplayWindowFrame]? = nil, originOffset: Point = .zero) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(crop.width) * scale,
                                                  pixelsHigh: Int(crop.height) * scale, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = graphics.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        cg.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh)); cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        func draw(window: Rect, surface: Rect?) {
            cg.saveGState()
            cg.translateBy(x: window.minX - crop.minX, y: crop.maxY - window.maxY)
            cg.clip(to: CGRect(x: 0, y: 0, width: window.width, height: window.height))
            let origin = WindowGeometry.drawingOrigin(window: window, display: display) + originOffset
            cg.translateBy(x: origin.x, y: origin.y)
            if let surface {
                cg.clip(to: CGRect(x: surface.minX - display.minX, y: display.maxY - surface.maxY,
                                   width: surface.width, height: surface.height))
            }
            MallowRenderer().draw(snapshot)
            cg.restoreGState()
        }
        if let canvases {
            for canvas in canvases { draw(window: canvas.frame, surface: canvas.display) }
        } else if let window { draw(window: window, surface: nil) }
        else {
            cg.translateBy(x: display.minX - crop.minX, y: crop.maxY - display.maxY)
            MallowRenderer().draw(snapshot)
        }
        return bitmap
    }
}
