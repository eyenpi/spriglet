import AppKit
import Testing
import CompanionCore
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
    @Test("Icon exports are opaque RGB at small and full sizes", arguments: [16, 32, 1024])
    func icons(pixels: Int) throws {
        let image = try MallowIconRenderer().image(pixels: pixels)
        #expect(!image.hasAlpha)
        let data = try #require(image.representation(using: .png, properties: [:]))
        #expect(data[25] == 2)
        #expect(image.pixelsWide == pixels && image.pixelsHigh == pixels)
    }
}
