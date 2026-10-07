import AppKit
import Testing
@testable import CompanionCore
@testable import CompanionRendering

@Suite("Production vector rendering") @MainActor struct RendererTests {
    @Test("A resting unnotched home never exposes a crown above its menu-bar edge", arguments: [0.8, 1.0, 1.2])
    func unnotchedHomeMask(scale: Double) throws {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                  home: Rect(x: 490, y: 13, width: 180, height: 20),
                                  floor: 408, scale: scale, hasHardwareNotch: false)
        var engine = CompanionEngine(scene: scene)
        let resting = engine.snapshot
        engine.send(.pointerPressed(resting.hitBounds.center))
        let began = engine.beginDesktopDrag(geometry: DragGeometry(
            surfaces: [DragSurface(bounds: scene.bounds, housing: scene.homeOcclusion)], heldBounds: scene.bounds))
        #expect(began)
        for frame in [resting, engine.snapshot] {
            let image = try characterImage(frame)
            var exposedCrown = 0, hiddenControl = 0, hiddenHits = 0, visibleFace = 0
            for y in 0..<33 {
                for x in 490..<670 {
                    let point = Point(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if y < 13 && frame.geometry.contains(point) { hiddenControl += 1 }
                    if (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { exposedCrown += 1 }
                    if frame.contains(point) { hiddenHits += 1 }
                }
            }
            for y in 33..<93 {
                for x in 490..<670 where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { visibleFace += 1 }
            }
            #expect(hiddenControl > 20, "The unmasked crown must actually reach above the finite Home rectangle")
            #expect(exposedCrown == 0, "Resting crown leaked above Home: \(exposedCrown) pixels")
            #expect(hiddenHits == 0, "Hidden artwork must also be click-through")
            #expect(visibleFace > 400, "The resting face below Home must remain visible")
        }
    }

    @Test("Picking agrees with painted pixels through peek, stretch, rotation and walking", arguments: [0, 1, 2, 3, 4])
    func paintedSilhouette(variant: Int) throws {
        let scene = SceneGeometry.preview
        var pose = CharacterPose()
        if variant == 1 { pose.height = 1.3; pose.width = 1 / pose.height; pose.lean = -0.12; pose.arm = 0.85 }
        if variant == 2 { pose.height = 0.7; pose.width = 1 / pose.height; pose.arm = 0.9 }
        if variant == 3 { pose.walk = 1; pose.gaitPhase = 0.8; pose.facing = -0.8; pose.direction = -1 }
        let frame = variant == 0 ? CompanionEngine(scene: scene).snapshot : CompanionSnapshot(
            scene: scene, presence: .playing, phase: .held, pose: pose,
            feet: variant == 4 ? Point(x: scene.home.midX, y: scene.home.maxY + 55) : Point(x: 360, y: 250),
            windowAnchor: scene.homeFeet, rotation: variant == 2 ? 0.5 : -0.15,
            openness: variant == 4 ? 0.85 : 1, homeGrip: variant == 4 ? 0.75 : 0,
            time: 0, gesture: nil, canCatch: false)
        let image = try characterImage(frame)
        var missedInterior = 0, emptyHits = 0, paintedHits = 0
        let bounds = frame.hitBounds
        for y in stride(from: max(0, Int(bounds.minY) - 4), to: min(image.pixelsHigh, Int(bounds.maxY) + 5), by: 2) {
            for x in stride(from: max(0, Int(bounds.minX) - 4), to: min(image.pixelsWide, Int(bounds.maxX) + 5), by: 2) {
                let hit = frame.contains(Point(x: Double(x) + 0.5, y: Double(y) + 0.5))
                let alpha = image.colorAt(x: x, y: y)?.alphaComponent ?? 0
                // Pixel coverage varies at antialiased edges; interior and wholly
                // empty neighborhoods must still agree with the vector hit shape.
                if alpha > 0.99 && !hit { missedInterior += 1 }
                if hit {
                    paintedHits += 1
                    let nearby = (-1...1).contains { dy in (-1...1).contains { dx in
                        let px = x + dx, py = y + dy
                        return px >= 0 && px < image.pixelsWide && py >= 0 && py < image.pixelsHigh
                            && (image.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.05
                    } }
                    if !nearby { emptyHits += 1 }
                }
            }
        }
        #expect(paintedHits > 400)
        #expect(missedInterior == 0)
        #expect(emptyHits == 0)
    }
    private func characterImage(_ frame: CompanionSnapshot) throws -> NSBitmapImageRep {
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
    @Test("Oversized scenes are rejected before integer conversion or bitmap allocation")
    func oversizedScene() {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 1e100, height: 420),
                                  home: Rect(x: 260, y: 0, width: 200, height: 54), floor: 365)
        #expect(throws: BitmapRenderingError.invalidSize) {
            try ScenePreviewRenderer().image(CompanionEngine(scene: scene).snapshot)
        }
    }
    @Test("Resting face and invited body render visible pixels below the notch")
    func visibleFace() throws {
        let painter = ScenePreviewRenderer()
        var engine = CompanionEngine(scene: .preview)
        for invited in [false, true] {
            if invited { engine.send(.activate); engine.advance(by: 0.25); engine.advance(by: 0.25) }
            let image = try painter.image(engine.snapshot)
            let scene = engine.snapshot.scene
            var darkPixels = 0
            // Eyes and outline must be below the housing, even in the default peek.
            for y in Int(scene.home.maxY)..<Int(scene.home.maxY + 65) {
                for x in Int(scene.home.midX - 70)..<Int(scene.home.midX + 70) {
                    if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent < 0.45 && c.blueComponent < 0.55 { darkPixels += 1 }
                }
            }
            #expect(darkPixels > 90)
            #expect(image.representation(using: .png, properties: [:]) != nil)
        }
    }
    @Test("Rendering does not advance or mutate the model")
    func readOnlyRendering() throws {
        let engine = CompanionEngine(scene: .preview), before = engine.snapshot
        let painter = ScenePreviewRenderer()
        for _ in 0..<3 { _ = try painter.image(engine.snapshot) }
        #expect(engine.time == before.time && engine.snapshot.feet == before.feet && engine.snapshot.pose == before.pose)
    }
    @Test("Reusing artwork across deformations cannot change later frames")
    func reusableArtwork() throws {
        var engine = CompanionEngine(scene: .preview)
        let resting = engine.snapshot
        engine.send(.command(.greet)); engine.advance(by: 0.25)
        let waving = engine.snapshot
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 520, y: 200))); engine.advance(by: 0.25)
        let held = engine.snapshot
        engine.send(.pointerReleased(Point(x: 520, y: 200))); engine.advance(by: 0.25)
        let falling = engine.snapshot
        let reused = ScenePreviewRenderer()
        for snapshot in [resting, waving, held, falling, resting] {
            let sharedImage = try reused.image(snapshot).representation(using: .png, properties: [:])
            let freshImage = try ScenePreviewRenderer().image(snapshot).representation(using: .png, properties: [:])
            #expect(sharedImage != nil && sharedImage == freshImage)
        }
    }
    @Test("Hands emerge continuously across the former reveal threshold")
    func continuousHands() throws {
        let painter = ScenePreviewRenderer(), scene = SceneGeometry.preview
        func frame(open: Double, fixedFeet: Point? = nil) -> CompanionSnapshot {
            var pose = CharacterPose(); pose.arm = 0.4
            let feet = fixedFeet ?? scene.homeFeet - Point(x: 0, y: (1 - open) * 75 * scene.scale)
            return CompanionSnapshot(scene: scene, presence: .engaged, phase: .hanging, pose: pose,
                                     feet: feet, windowAnchor: scene.homeFeet, rotation: 0, openness: open,
                                     homeGrip: 1, time: 0, gesture: nil, canCatch: false)
        }
        let before = try painter.image(frame(open: 0.7799))
        let after = try painter.image(frame(open: 0.7801))
        var changedPixels = 0
        // This region contains the left grip, clear of the face and feet.
        for y in Int(scene.home.maxY)..<Int(scene.home.maxY + 24) {
            for x in Int(scene.home.midX - 57)..<Int(scene.home.midX - 30) {
                let a = try #require(before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try #require(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if abs(a.redComponent - b.redComponent) > 0.05 { changedPixels += 1 }
            }
        }
        #expect(changedPixels < 8)
        // Hold the body still to prove that the hand itself emerges, rather
        // than passing the continuity check by omitting the hands altogether.
        let hidden = try painter.image(frame(open: 0.6, fixedFeet: scene.homeFeet))
        let emerged = try painter.image(frame(open: 1, fixedFeet: scene.homeFeet))
        var handPixels = 0
        for y in Int(scene.home.maxY)..<Int(scene.home.maxY + 10) {
            for x in Int(scene.home.midX - 57)..<Int(scene.home.midX - 30) {
                let a = try #require(hidden.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try #require(emerged.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if abs(a.redComponent - b.redComponent) > 0.05 { handPixels += 1 }
            }
        }
        #expect(handPixels > 20)
    }
    @Test("Greet paints only the articulated character and keeps both hands waving", arguments: [1.0, 1.45])
    func greetSilhouette(scale: Double) throws {
        let base = SceneGeometry.preview
        let scene = SceneGeometry(bounds: base.bounds, home: base.home, floor: base.floor, scale: scale)
        var engine = CompanionEngine(scene: scene)
        engine.send(.command(.greet))
        var arms: [Double] = [], hands: [Point] = [], paintedHandPixels: [Int] = []
        var frames: [CompanionSnapshot] = []
        for index in 0..<84 {
            engine.advance(by: 1 / 120.0)
            let frame = engine.snapshot
            arms.append(frame.pose.arm)
            hands.append(frame.geometry.hands[1].arm.end)
            if [6, 18, 30, 42, 54, 66, 78, 83].contains(index) {
                frames.append(frame)
                let image = try characterImage(frame)
                var detachedPaint = 0, handPixels = 0
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        let alpha = image.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        let point = Point(x: Double(x) + 0.5, y: Double(y) + 0.5)
                        if alpha > 0.02 {
                            // One-pixel neighborhood accounts for rasterization
                            // versus the geometry's sampled curves. A detached
                            // mark remains well outside this tolerance.
                            let belongsToSilhouette = (-1...1).contains { dy in (-1...1).contains { dx in
                                frame.contains(Point(x: point.x + Double(dx), y: point.y + Double(dy)))
                            } }
                            if !belongsToSilhouette { detachedPaint += 1 }
                        }
                        if alpha > 0.2 && frame.geometry.hands.contains(where: { hand in
                            let xValues = [hand.arm.start.x, hand.arm.control1.x, hand.arm.control2.x,
                                           hand.arm.end.x, hand.palm.minX, hand.palm.maxX]
                            let yValues = [hand.arm.start.y, hand.arm.control1.y, hand.arm.control2.y,
                                           hand.arm.end.y, hand.palm.minY, hand.palm.maxY]
                            return (xValues.min()!-2...xValues.max()!+2).contains(point.x)
                                && (yValues.min()!-2...yValues.max()!+2).contains(point.y)
                        }) { handPixels += 1 }
                    }
                }
                paintedHandPixels.append(handPixels)
                #expect(detachedPaint <= 2)
                if index == 83 {
                    let palm = frame.geometry.hands[1].palm.center
                    let paintedPalm = (-3...3).contains { dy in (-3...3).contains { dx in
                        let x = Int(palm.x.rounded()) + dx, y = Int(palm.y.rounded()) + dy
                        return x >= 0 && x < image.pixelsWide && y >= 0 && y < image.pixelsHigh
                            && (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2
                    } }
                    #expect(paintedPalm)
                }
            }
        }
        #expect((arms.max() ?? 0) - (arms.min() ?? 0) > 0.15)
        #expect(zip(hands, hands.dropFirst()).contains { $0.distance(to: $1) > 1 })
        #expect(paintedHandPixels.allSatisfy { $0 > 12 })
        #expect(frames.count == 8)
    }
    @Test("Stretch keeps both eyes visible below the housing")
    func stretchedFace() throws {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.activate)
        for _ in 0..<84 { engine.advance(by: 1 / 120.0) }
        engine.send(.command(.stretch))
        for _ in 0..<120 { engine.advance(by: 1 / 120.0) }
        let frame = engine.snapshot, image = try ScenePreviewRenderer().image(engine.snapshot)
        #expect(frame.pose.height > 1.15)
        for side in [-1.0, 1.0] {
            let center = frame.feet.x + side * 14 * frame.pose.width * frame.scene.scale
            var eyePixels = 0
            for y in Int(frame.scene.home.maxY + 5)..<Int(frame.scene.home.maxY + 19) {
                for x in Int(center - 7)..<Int(center + 7) {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent < 0.45 && color.blueComponent < 0.55 { eyePixels += 1 }
                }
            }
            #expect(eyePixels >= 8)
        }
    }
    @Test("Phase and gesture changes cannot switch the rendered arms", arguments: [0.12, 0.6])
    func renderedHandoff(age: Double) throws {
        let painter = ScenePreviewRenderer()
        var engine = CompanionEngine(scene: .preview)
        engine.send(.activate)
        for _ in 0..<Int(age * 120) { engine.advance(by: 1 / 120.0) }
        let before = engine.snapshot
        let beforePixels = try painter.image(before).representation(using: .png, properties: [:])
        engine.send(.command(.stretch))
        #expect(try painter.image(engine.snapshot).representation(using: .png, properties: [:]) == beforePixels)
        let pointer = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(pointer)); engine.send(.pointerDragged(pointer + Point(x: 6, y: 0)))
        #expect(engine.snapshot.phase == .held)
        #expect(try painter.image(engine.snapshot).representation(using: .png, properties: [:]) == beforePixels)
    }
    @Test("Icon exports are opaque RGB at small and full sizes", arguments: [16, 32, 1024])
    func icons(pixels: Int) throws {
        let image = try MallowIconRenderer().image(pixels: pixels)
        #expect(!image.hasAlpha)
        let data = try #require(image.representation(using: .png, properties: [:]))
        #expect(data[25] == 2)
        #expect(image.pixelsWide == pixels && image.pixelsHigh == pixels)
    }
}
