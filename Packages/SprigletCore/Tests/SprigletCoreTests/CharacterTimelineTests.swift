import SprigletCore
import Testing

private func timelinePackage() -> CharacterPackage {
    let clips: [String: CharacterPackage.Clip] = [
        "lead": .init(
            startPoseID: "ready", endPoseID: "turned", framesPerSecond: 20,
            frames: [
                .init(file: "lead-0.png", rootOffsetPoints: .zero),
                .init(file: "lead-1.png", rootOffsetPoints: .init(x: 5, y: 0))
            ]
        ),
        "finish": .init(
            startPoseID: "turned", endPoseID: "ready", framesPerSecond: 40,
            frames: [
                .init(file: "finish-0.png", rootOffsetPoints: .zero),
                .init(file: "finish-1.png", rootOffsetPoints: .init(x: 0, y: 2)),
                .init(file: "finish-2.png", rootOffsetPoints: .init(x: -5, y: 0))
            ]
        )
    ]
    let graph = CharacterAnimationGraph(
        defaultPoseID: "ready",
        intents: [
            "turn": .init(targetPoseID: "ready", clipIDs: ["lead", "finish"], replaysAtTarget: true)
        ],
        transitionClipIDs: ["finish"]
    )
    return CharacterPackage(
        identifier: "timeline.test",
        displayName: "Timeline Test",
        canvasPixels: .init(width: 100, height: 100),
        displaySizePoints: .init(width: 96, height: 96),
        groundAnchorPixels: .init(x: 50, y: 90),
        contentBoundsPixels: .init(x: 0, y: 0, width: 100, height: 100),
        poses: [
            "ready": .init(stillFrame: "ready.png"),
            "turned": .init(stillFrame: "turned.png")
        ],
        clips: clips,
        semanticBindings: [:],
        animationGraph: graph,
        resourceBudget: .init(
            maxDecodedImageBytes: 160_000,
            maxBufferedFrames: 2,
            maxDecodedLayerBytes: 0
        )
    )
}

private func longTimelinePackage() -> CharacterPackage {
    let frames = (0..<180).map { index in
        CharacterPackage.Frame(
            file: "frames/\(index).png",
            rootOffsetPoints: SamplePoint(x: Double(index), y: 0)
        )
    }
    let graph = CharacterAnimationGraph(
        defaultPoseID: "ready",
        intents: [
            "long": .init(targetPoseID: "ready", clipIDs: ["long"], replaysAtTarget: true)
        ]
    )
    return CharacterPackage(
        identifier: "timeline.long",
        displayName: "Long Timeline",
        canvasPixels: .init(width: 100, height: 100),
        displaySizePoints: .init(width: 96, height: 96),
        groundAnchorPixels: .init(x: 50, y: 90),
        contentBoundsPixels: .init(x: 0, y: 0, width: 100, height: 100),
        poses: ["ready": .init(stillFrame: "ready.png")],
        clips: [
            "long": .init(
                startPoseID: "ready",
                endPoseID: "ready",
                framesPerSecond: 30,
                frames: frames
            )
        ],
        semanticBindings: [:],
        animationGraph: graph,
        resourceBudget: .init(
            maxDecodedImageBytes: 160_000,
            maxBufferedFrames: 2,
            maxDecodedLayerBytes: 0
        )
    )
}

@Suite("Generic character timeline")
struct CharacterTimelineTests {
    @Test("Mixed frame rates retain exact boundaries and atomic root motion")
    func mixedRates() throws {
        let timeline = try CharacterTimeline(
            package: timelinePackage(),
            intentID: "turn",
            from: "ready"
        )
        #expect(timeline.frameCount == 5)
        #expect(timeline.maximumFramesPerSecond == 40)
        #expect(timeline.duration == 2.0 / 20 + 3.0 / 40)
        #expect(timeline.snapshot(at: 0).file == "lead-0.png")
        #expect(timeline.snapshot(at: 1.0 / 20).file == "lead-1.png")
        #expect(timeline.snapshot(at: 2.0 / 20).file == "finish-0.png")
        #expect(timeline.snapshot(at: (2.0 / 20).nextDown).file == "lead-1.png")
        #expect(timeline.snapshot(at: 2.0 / 20).rootOffsetPoints == SamplePoint(x: 5, y: 0))
        #expect(timeline.snapshot(at: 2.0 / 20 + 1.0 / 40).rootOffsetPoints == SamplePoint(x: 5, y: 2))
        #expect(timeline.snapshot(at: (2.0 / 20 + 1.0 / 40).nextDown).file == "finish-0.png")
        #expect(timeline.snapshot(at: timeline.duration).rootOffsetPoints == .zero)
        #expect(timeline.snapshot(at: timeline.duration).isComplete)
    }

    @Test("Uniform 30 fps boundaries stay exact through long authored clips")
    func exactUniformBoundaries() throws {
        let package = longTimelinePackage()
        let clipID = try #require(CharacterClipID(rawValue: "long"))
        let timeline = try CharacterTimeline(package: package, clips: [clipID])
        #expect(timeline.maximumFramesPerSecond == 30)
        #expect(timeline.duration == 180.0 / 30)
        for index in 0..<180 {
            let boundary = Double(index) / 30
            #expect(timeline.snapshot(at: boundary).timelineFrameIndex == index)
            if index > 0 {
                #expect(timeline.snapshot(at: boundary.nextDown).timelineFrameIndex == index - 1)
            }
        }
        #expect(timeline.snapshot(at: 123.0 / 30).timelineFrameIndex == 123)
        #expect(timeline.snapshot(at: (123.0 / 30).nextDown).timelineFrameIndex == 122)
    }

    @Test("Frame indexing has the same bounded completion behavior as legacy playback")
    func frameIndexing() throws {
        let package = timelinePackage()
        let plan = try package.plan(for: "turn", from: "ready")
        let timeline = try CharacterTimeline(package: package, plan: plan)
        #expect(timeline.snapshot(atFrame: .min) == timeline.snapshot(at: 0))
        #expect(timeline.snapshot(atFrame: 5).isComplete)
        #expect(timeline.snapshot(atFrame: .max) == timeline.snapshot(at: .infinity))
        #expect(timeline.rootOffsets.count == timeline.frameCount)
    }

    @Test("Held poses and discontinuous caller-built plans do not create clocks")
    func invalidPlans() throws {
        let package = timelinePackage()
        let held = CharacterAnimationPlan(
            requestedIntentID: "ready", resolvedIntentID: "ready",
            startPoseID: "ready", endPoseID: "ready", clipIDs: []
        )
        #expect(throws: CharacterPackageError.self) {
            try CharacterTimeline(package: package, plan: held)
        }
        let discontinuous = CharacterAnimationPlan(
            requestedIntentID: "bad", resolvedIntentID: "bad",
            startPoseID: "turned", endPoseID: "ready", clipIDs: ["lead"]
        )
        #expect(throws: CharacterPackageError.self) {
            try CharacterTimeline(package: package, plan: discontinuous)
        }
    }
}
