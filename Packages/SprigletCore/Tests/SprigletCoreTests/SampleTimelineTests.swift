import Foundation
import SprigletCore
import Testing

private func sampleManifest(
    clips: [String: SproutSampleManifest.Clip]? = nil,
    framesPerSecond: Double = 30,
    restFrame: String = "rest.png"
) -> SproutSampleManifest {
    let movements: [SampleClipID: [Double]] = [
        .idle: [0, 0], .walkRight: [0, 10, 24], .walkLeft: [0, -10, -24],
        .pet: [0, 0], .settle: [0, 0]
    ]
    let defaultClips = Dictionary(uniqueKeysWithValues: SampleClipID.allCases.map { id in
        (id.rawValue, SproutSampleManifest.Clip(frames: movements[id]!.enumerated().map { index, x in
            .init(file: "frames/\(id.rawValue)-\(index).png", rootOffsetPoints: .init(x: x, y: 0))
        }))
    })
    return SproutSampleManifest(
        schemaVersion: 1, canvasPixels: .init(width: 448, height: 448),
        displaySizePoints: .init(width: 224, height: 224), framesPerSecond: framesPerSecond,
        groundAnchorPixels: .init(x: 224, y: 32), restFrame: restFrame, sleepFrame: "sleep.png",
        clips: clips ?? defaultClips
    )
}

@Suite("Authored frame and movement timeline")
struct SampleTimelineTests {
    @Test("A held image also holds its exact authored root offset")
    func atomicImageAndOffset() throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.walkRight])
        let frame = timeline.snapshot(at: 1.5 / 30)
        #expect(frame.clip == .walkRight)
        #expect(frame.clipFrameIndex == 1 && frame.timelineFrameIndex == 1)
        #expect(frame.file == "frames/walkRight-1.png")
        #expect(frame.rootOffsetPoints == SamplePoint(x: 10, y: 0))
        #expect(!frame.isComplete)
        #expect(timeline.snapshot(at: (2.0 / 30).nextDown) == frame)
    }

    @Test("Every 30 fps boundary selects the associated image and offset together")
    func frameBoundaries() throws {
        var clips = sampleManifest().clips
        clips[SampleClipID.walkRight.rawValue] = .init(frames: (0..<180).map { index in
            .init(file: "frames/boundary-\(index).png", rootOffsetPoints: .init(x: Double(index), y: 0))
        })
        let timeline = try SampleTimeline(manifest: sampleManifest(clips: clips), clips: [.walkRight])
        for index in 0..<180 {
            let snapshot = timeline.snapshot(at: Double(index) / 30)
            #expect(snapshot.timelineFrameIndex == index)
            #expect(snapshot.file == "frames/boundary-\(index).png")
            #expect(snapshot.rootOffsetPoints.x == Double(index))
            if index > 0 {
                let preceding = timeline.snapshot(at: (Double(index) / 30).nextDown)
                #expect(preceding.timelineFrameIndex == index - 1)
            }
        }
    }

    @Test("The last image remains visible for one frame interval before completion")
    func finiteCompletion() throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.walkRight])
        #expect(timeline.frameCount == 3)
        #expect(timeline.duration == 0.1)
        let before = timeline.snapshot(at: timeline.duration.nextDown)
        let completed = timeline.snapshot(at: timeline.duration)
        #expect(!before.isComplete && completed.isComplete)
        #expect(before.file == completed.file)
        #expect(before.rootOffsetPoints == completed.rootOffsetPoints)
        #expect(completed.rootOffsetPoints == SamplePoint(x: 24, y: 0))
        #expect(timeline.snapshot(at: 1_000_000) == completed)
        #expect(timeline.snapshot(at: .infinity) == completed)
    }

    @Test("Invalid and negative time cannot advance a clip", arguments: [Double.nan, -.infinity, -1.0, -0.001])
    func invalidElapsed(elapsed: Double) throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.walkRight])
        #expect(timeline.snapshot(at: elapsed) == timeline.snapshot(at: 0))
    }

    @Test("Clip boundaries accumulate previous movement exactly once")
    func mixedPlaylist() throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.idle, .walkRight, .pet, .settle])
        #expect(timeline.frameCount == 9)
        let entries: [(Int, SampleClipID, Double)] = [(0, .idle, 0), (2, .walkRight, 0), (5, .pet, 24), (7, .settle, 24)]
        for (index, clip, offset) in entries {
            let frame = timeline.snapshot(at: Double(index) / 30)
            #expect(frame.clip == clip && frame.clipFrameIndex == 0)
            #expect(frame.rootOffsetPoints == SamplePoint(x: offset, y: 0))
        }
        #expect(timeline.snapshot(at: timeline.duration).rootOffsetPoints.x == 24)
    }

    @Test("Repeated walks and direction changes preserve completed displacement")
    func repeatedAndReversedClips() throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.walkRight, .walkRight, .walkLeft])
        #expect(timeline.snapshot(at: 3.0 / 30).rootOffsetPoints.x == 24)
        #expect(timeline.snapshot(at: 6.0 / 30).rootOffsetPoints.x == 48)
        #expect(timeline.snapshot(at: timeline.duration).rootOffsetPoints.x == 24)
        let left = try SampleTimeline(manifest: sampleManifest(), clips: [.walkLeft])
        let right = try SampleTimeline(manifest: sampleManifest(), clips: [.walkRight])
        for index in 0..<3 {
            let elapsed = (Double(index) + 0.5) / 30
            #expect(left.snapshot(at: elapsed).rootOffsetPoints.x == -right.snapshot(at: elapsed).rootOffsetPoints.x)
            #expect(left.snapshot(at: elapsed).rootOffsetPoints.y == right.snapshot(at: elapsed).rootOffsetPoints.y)
        }
    }

    @Test("Elapsed jumps and new playback instances have no hidden clock state")
    func statelessSelectionAndRestart() throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.idle, .walkRight, .pet, .settle])
        let initial = timeline.snapshot(at: 0)
        _ = timeline.snapshot(at: timeline.duration + 1)
        #expect(timeline.snapshot(at: 0) == initial)
        let fresh = try SampleTimeline(manifest: sampleManifest(), clips: [.idle, .walkRight, .pet, .settle])
        for elapsed in [0.28, 0.04, 0.16, 9, 0.09, 0] {
            #expect(timeline.snapshot(at: elapsed) == fresh.snapshot(at: elapsed))
        }
        #expect(timeline.rootOffsets.count == timeline.frameCount)
        for (index, offset) in timeline.rootOffsets.enumerated() {
            #expect(timeline.snapshot(at: (Double(index) + 0.5) / 30).rootOffsetPoints == offset)
        }
    }

    @Test("Empty and unbounded playlists are rejected")
    func invalidPlaylists() {
        #expect(throws: SampleManifestError.self) { try SampleTimeline(manifest: sampleManifest(), clips: []) }
        #expect(throws: SampleManifestError.self) {
            try SampleTimeline(manifest: sampleManifest(), clips: Array(repeating: .idle, count: 17))
        }
    }

    @Test("Integer prefetch selection has the same safe completion boundary")
    func integerFrameAccess() throws {
        let timeline = try SampleTimeline(manifest: sampleManifest(), clips: [.walkRight])
        #expect(timeline.snapshot(atFrame: .min) == timeline.snapshot(at: 0))
        #expect(timeline.snapshot(atFrame: -1) == timeline.snapshot(at: 0))
        for index in 0..<3 {
            #expect(timeline.snapshot(atFrame: index) == timeline.snapshot(at: Double(index) / 30))
        }
        #expect(timeline.snapshot(atFrame: 3) == timeline.snapshot(at: timeline.duration))
        #expect(timeline.snapshot(atFrame: .max) == timeline.snapshot(at: .infinity))
    }
}

@Suite("Local character manifest validation")
struct SampleManifestTests {
    @Test("Resource paths cannot escape the bundle or request a remote file", arguments: [
        "../rest.png", "/rest.png", "frames/../rest.png", "frames//rest.png", "frames/./rest.png",
        "https://example.test/rest.png", "frames\\rest.png", "bad\0name.png", "frame.jpg"
    ])
    func invalidPaths(path: String) throws {
        #expect(throws: SampleManifestError.self) { try sampleManifest(restFrame: path).validate() }
        var clips = sampleManifest().clips
        clips["idle"] = .init(frames: [.init(file: path, rootOffsetPoints: .zero)])
        let data = try JSONEncoder().encode(sampleManifest(clips: clips))
        #expect(throws: SampleManifestError.self) { try SproutSampleManifest.decode(data) }
    }

    @Test("Nonfinite timing and root movement are rejected", arguments: [Double.nan, .infinity, -.infinity])
    func nonfiniteValues(value: Double) {
        #expect(throws: SampleManifestError.self) { try sampleManifest(framesPerSecond: value).validate() }
        var clips = sampleManifest().clips
        clips["walkRight"] = .init(frames: [
            .init(file: "first.png", rootOffsetPoints: .zero),
            .init(file: "second.png", rootOffsetPoints: .init(x: value, y: 0))
        ])
        #expect(throws: SampleManifestError.self) { try sampleManifest(clips: clips).validate() }
    }

    @Test("Every clip requires a zero-offset entry and at least one image")
    func invalidClipEntries() {
        var clips = sampleManifest().clips
        clips["pet"] = .init(frames: [])
        #expect(throws: SampleManifestError.self) { try sampleManifest(clips: clips).validate() }
        clips["pet"] = .init(frames: [.init(file: "pet.png", rootOffsetPoints: .init(x: 1, y: 0))])
        #expect(throws: SampleManifestError.self) { try sampleManifest(clips: clips).validate() }
        clips.removeValue(forKey: "pet")
        #expect(throws: SampleManifestError.self) { try sampleManifest(clips: clips).validate() }
    }

    @Test("Resource limits prevent oversized decode and frame inventories")
    func resourceBounds() {
        #expect(throws: SampleManifestError.self) {
            try SproutSampleManifest.decode(Data(repeating: 32, count: 2_000_001))
        }
        let frame = SproutSampleManifest.Frame(file: "rest.png", rootOffsetPoints: .zero)
        var clips = sampleManifest().clips
        clips["idle"] = .init(frames: Array(repeating: frame, count: 601))
        #expect(throws: SampleManifestError.self) { try sampleManifest(clips: clips).validate() }
        for id in SampleClipID.allCases { clips[id.rawValue] = .init(frames: Array(repeating: frame, count: 301)) }
        #expect(throws: SampleManifestError.self) { try sampleManifest(clips: clips).validate() }
    }
}
