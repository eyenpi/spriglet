import AppKit
import Testing
@testable import CompanionCore
@testable import CompanionRendering

@Suite("Production vector rendering") @MainActor struct RendererTests {
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
    @Test("Hands emerge continuously across the former reveal threshold")
    func continuousHands() throws {
        let painter = ScenePreviewRenderer(), scene = SceneGeometry.preview
        func frame(open: Double, fixedFeet: Point? = nil) -> CompanionSnapshot {
            var pose = CharacterPose(); pose.arm = 0.4
            let feet = fixedFeet ?? scene.homeFeet - Point(x: 0, y: (1 - open) * 75 * scene.scale)
            return CompanionSnapshot(scene: scene, presence: .engaged, phase: .hanging, pose: pose,
                                     feet: feet, windowAnchor: scene.homeFeet, rotation: 0, openness: open,
                                     homeGrip: 1, time: 0, gesture: nil, hitBounds: scene.home)
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
