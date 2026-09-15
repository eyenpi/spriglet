import Foundation
import SprigletCore
import Testing

@Suite("Production Acorn asset contract")
struct AcornAssetTests {
    private func manifest() throws -> SproutSampleManifest {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try SproutSampleManifest.decode(Data(contentsOf:
            root.appendingPathComponent("Sources/Spriglet/Resources/AcornHopper/manifest.json")))
    }

    @Test("A single injected definition identifies the production pet")
    func definition() {
        #expect(PetAssetDefinition.acornHopper.id == "acorn-hopper")
        #expect(PetAssetDefinition.acornHopper.resourceName == "AcornHopper")
        #expect(PetProfile().name == "Acorn")
        #expect(PetProfile(name: "Sprout").name == "Sprout")
    }

    @Test("Relative size choices retain the approved tiny canvas", arguments: PetDisplaySize.allCases)
    func nativeSize(size: PetDisplaySize) throws {
        let source = try manifest()
        let scaled = try size.scaledManifest(source)
        let expected: [PetDisplaySize: Double] = [.small: 72, .standard: 96, .large: 120]
        let points = try #require(expected[size])
        #expect(scaled.supportsAnimatedSleep)
        #expect(scaled.displaySizePoints.width == points)
        #expect(Double(size.size(for: source.displaySizePoints).width) == points)
        #expect(scaled.canvasPixels == SampleSize(width: 448, height: 448))
        let walk = try SampleTimeline(manifest: scaled, clips: [.walkRight])
        #expect(abs(walk.duration - 0.8) < 1e-9)
        #expect(abs(walk.rootOffsets.last!.x - 102.4 * size.scale) < 1e-5)
    }

    @Test("Wake-up prefix keeps the firefly hidden until the actual game", arguments: PetDisplaySize.allCases)
    func sleepingFirefly(size: PetDisplaySize) throws {
        let source = try size.scaledManifest(manifest())
        let lead = source.clips[SampleClipID.wakeUp.rawValue]!.frames.count
        let timeline = try SampleTimeline(manifest: source,
                                          clips: [.wakeUp] + PetRoutine.firefly.clips(stationary: true))
        var visible = 0
        for index in 0..<timeline.frameCount {
            let pose = FireflyMotion.pose(for: timeline.snapshot(atFrame: index), manifest: source,
                                          stationary: true, leadingFrameCount: lead)
            if index < lead { #expect(pose == nil) }
            if let pose {
                visible += 1
                let radius = 14 * source.displaySizePoints.width / 224
                #expect((radius...(source.displaySizePoints.width - radius)).contains(pose.position.x))
                #expect((radius...(source.displaySizePoints.height - radius)).contains(pose.position.y))
            }
        }
        #expect(visible > 30)
    }
}
