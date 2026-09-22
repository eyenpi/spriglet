import Foundation
import SprigletCore
import Testing

@Suite("Production Acorn asset contract")
struct AcornAssetTests {
    @Test("Shipping schema 3 preserves timing and pairs every ready boundary with the rest rig")
    func layeredPackage() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let package = try CharacterPackage.decode(Data(contentsOf:
            root.appendingPathComponent("Sources/Spriglet/Resources/AcornHopper/character.json")))
        let legacy = try manifest()
        let ready = try #require(package.poses[package.animationGraph.defaultPoseID])
        let canonical = try #require(ready.stillFrame)
        #expect(!ready.layerIDs.isEmpty)
        #expect(package.resourceBudget.maxBufferedFrames == 12)
        #expect(package.resourceBudget.maxDecodedLayerBytes <= 1_048_576)
        for (id, source) in legacy.clips {
            let clip = try #require(package.clips[id])
            #expect(clip.framesPerSecond == legacy.framesPerSecond)
            #expect(clip.frames.map(\.rootOffsetPoints) == source.frames.map(\.rootOffsetPoints))
            if clip.startPoseID == "ready" { #expect(clip.frames.first?.file == canonical) }
            if clip.endPoseID == "ready" { #expect(clip.frames.last?.file == canonical) }
        }
        let context = CharacterPlaybackContext(
            capabilityIDs: Set(package.capabilities), habitatID: "desktop"
        )
        // Habitat poses deliberately require a coordinator-owned context
        // switch at a hidden portal; ordinary desktop graph routing must never
        // synthesize that host relocation.
        for pose in ["ready", "happy", "asleep"] {
            for intent in package.animationGraph.intents.keys {
                let plan = try package.plan(for: intent, from: pose, context: context)
                #expect(plan.endPoseID == package.animationGraph.intents[plan.resolvedIntentID]?.targetPoseID)
            }
        }
        let behavior = try ReactiveBehaviorPolicy.decode(Data(contentsOf:
            root.appendingPathComponent("Sources/Spriglet/Resources/AcornHopper/reactive/behavior.json")))
        #expect(behavior.characterIdentifier == package.identifier)
        let configured = try behavior.configuration(for: .sprout)
        #expect(configured.candidates.allSatisfy {
            package.animationGraph.intents[$0.intentID] != nil
        })
    }

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
