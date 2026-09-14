import Foundation
import SprigletCore
import Testing

private var routineRepository: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}

private func routineManifest() throws -> SproutSampleManifest {
    try SproutSampleManifest.decode(Data(contentsOf: routineRepository.appendingPathComponent("Sources/Spriglet/Resources/SproutSample/manifest.json")))
}

private struct RecordedRoutineContacts: Decodable {
    struct Endpoint: Decodable { let pose: String; let boneMatrices: [String: [Double]] }
    struct Clip: Decodable { let endpoints: [String: Endpoint] }
    let clips: [String: Clip]
}

@Suite("Finite authored companion routines")
struct PetRoutineTests {
    @Test("Every routine joins recorded rig poses and finishes at its original root", arguments: PetRoutine.allCases, [false, true])
    func authoredJoinsAndReturn(routine: PetRoutine, stationary: Bool) throws {
        let manifest = try routineManifest()
        let contacts = try JSONDecoder().decode(RecordedRoutineContacts.self, from: Data(contentsOf:
            routineRepository.appendingPathComponent("art/sprout/sample-v01/contact-samples.json")))
        for direction in [SampleClipID.walkLeft, .walkRight] {
            let clips = routine.clips(direction: direction, stationary: stationary)
            let timeline = try SampleTimeline(manifest: manifest, clips: clips)
            #expect(timeline.snapshot(atFrame: 0).rootOffsetPoints == .zero)
            #expect(timeline.snapshot(at: timeline.duration).rootOffsetPoints == .zero)
            #expect(timeline.rootOffsets.allSatisfy { abs($0.x) <= 78.4 && $0.y == 0 })
            if stationary || routine == .observe || routine == .greet {
                #expect(timeline.rootOffsets.allSatisfy { $0 == .zero })
            } else {
                let excursion = timeline.rootOffsets.map { abs($0.x) }.max() ?? 0
                #expect(abs(excursion - 78.4) < 0.00001)
                #expect(clips.filter { $0 == .walkLeft }.count == 1)
                #expect(clips.filter { $0 == .walkRight }.count == 1)
            }
            let first = try #require(contacts.clips[clips[0].rawValue]?.endpoints["entry"])
            let lastClip = try #require(clips.last)
            let last = try #require(contacts.clips[lastClip.rawValue]?.endpoints["exit"])
            #expect(first.pose == "neutral" && last.pose == "neutral")
            for (left, right) in zip(clips, clips.dropFirst()) {
                let exit = try #require(contacts.clips[left.rawValue]?.endpoints["exit"])
                let entry = try #require(contacts.clips[right.rawValue]?.endpoints["entry"])
                #expect(exit.pose == entry.pose)
                #expect(Set(exit.boneMatrices.keys) == Set(entry.boneMatrices.keys))
                for (bone, matrix) in exit.boneMatrices {
                    let next = try #require(entry.boneMatrices[bone])
                    #expect(matrix.count == next.count)
                    #expect(zip(matrix, next).allSatisfy { abs($0 - $1) < 0.00001 })
                }
            }
        }
    }

    @Test("Firefly follows the committed frame, remains in the canvas, and vanishes during catch", arguments: [SampleClipID.walkLeft, .walkRight], [false, true])
    func deterministicToy(direction: SampleClipID, stationary: Bool) throws {
        let manifest = try routineManifest()
        let clips = PetRoutine.firefly.clips(direction: direction, stationary: stationary)
        let timeline = try SampleTimeline(manifest: manifest, clips: clips)
        var visibleFrames = 0
        var approachingDistance = 0.0
        var catchDistance = 0.0
        for index in 0..<timeline.frameCount {
            let frame = timeline.snapshot(atFrame: index)
            let pose = FireflyMotion.pose(for: frame, manifest: manifest, direction: direction, stationary: stationary)
            #expect(pose == FireflyMotion.pose(for: frame, manifest: manifest, direction: direction, stationary: stationary))
            if let pose {
                visibleFrames += 1
                // Includes the complete 28-point visual container, not just its core.
                #expect((14...210).contains(pose.position.x) && (14...210).contains(pose.position.y))
                #expect(pose.opacity > 0 && pose.opacity <= 1)
                #expect((0.35...1).contains(pose.wingSpread))
                if frame.clip == .idle {
                    #expect(direction == .walkLeft ? pose.position.x < 112 : pose.position.x > 112)
                    approachingDistance = abs(pose.position.x - 112)
                }
                if frame.clip == .pet { catchDistance = abs(pose.position.x - 112) }
            }
            if frame.clip == .settle || (frame.clip == .walkLeft || frame.clip == .walkRight) && frame.clip != direction {
                #expect(pose == nil)
            }
        }
        #expect(visibleFrames > 30)
        #expect(catchDistance < approachingDistance / 5)
        #expect(FireflyMotion.pose(for: timeline.snapshot(at: timeline.duration), manifest: manifest, direction: direction, stationary: stationary) == nil)
        let held = timeline.snapshot(at: 0.501)
        #expect(held == timeline.snapshot(at: 0.519))
        #expect(FireflyMotion.pose(for: held, manifest: manifest, direction: direction, stationary: stationary) ==
                FireflyMotion.pose(for: timeline.snapshot(at: 0.519), manifest: manifest, direction: direction, stationary: stationary))
    }

    @Test("Direction means an authored walk clip, never a flipped image", arguments: [SampleClipID.idle, .pet, .settle])
    func invalidDirection(direction: SampleClipID) throws {
        for routine in PetRoutine.allCases { #expect(routine.clips(direction: direction).isEmpty) }
        let manifest = try routineManifest()
        let timeline = try SampleTimeline(manifest: manifest, clips: [.idle])
        #expect(FireflyMotion.pose(for: timeline.snapshot(at: 0.5), manifest: manifest, direction: direction) == nil)
    }
}
