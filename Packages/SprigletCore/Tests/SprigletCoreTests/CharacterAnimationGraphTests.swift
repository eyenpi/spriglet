import SprigletCore
import Testing

private func graphPackage(
    graph replacement: CharacterAnimationGraph? = nil
) -> CharacterPackage {
    let frame = CharacterPackage.Frame(file: "frame.png", rootOffsetPoints: .zero)
    let clips: [String: CharacterPackage.Clip] = [
        "idle": .init(startPoseID: "ready", endPoseID: "ready", framesPerSecond: 30, frames: [frame]),
        "pet": .init(startPoseID: "ready", endPoseID: "happy", framesPerSecond: 30, frames: [frame]),
        "settle": .init(startPoseID: "happy", endPoseID: "ready", framesPerSecond: 30, frames: [frame]),
        "sleep": .init(startPoseID: "ready", endPoseID: "asleep", framesPerSecond: 30, frames: [frame]),
        "wake": .init(startPoseID: "asleep", endPoseID: "ready", framesPerSecond: 30, frames: [frame]),
        "move": .init(
            startPoseID: "ready", endPoseID: "ready", framesPerSecond: 30, frames: [frame],
            motionClass: .relocation
        ),
        "shelf": .init(
            startPoseID: "ready", endPoseID: "ready", framesPerSecond: 30, frames: [frame],
            requirements: .init(habitatIDs: ["topShelf"])
        ),
        "ledgeLeft": .init(
            startPoseID: "ready", endPoseID: "ready", framesPerSecond: 30, frames: [frame],
            requirements: .init(orientationIDs: ["left"], capabilityIDs: ["ledge"])
        )
    ]
    let graph = replacement ?? CharacterAnimationGraph(
        defaultPoseID: "ready",
        intents: [
            "ready": .init(targetPoseID: "ready"),
            "curious": .init(targetPoseID: "ready", clipIDs: ["idle"], replaysAtTarget: true),
            "happy": .init(targetPoseID: "ready", clipIDs: ["pet", "settle"], replaysAtTarget: true),
            "sleep": .init(targetPoseID: "asleep", clipIDs: ["sleep"]),
            "move": .init(targetPoseID: "ready", clipIDs: ["move"], replaysAtTarget: true,
                          fallbackIntentID: "curious", reducedMotionIntentID: "curious"),
            "shelf": .init(targetPoseID: "ready", clipIDs: ["shelf"], replaysAtTarget: true,
                           fallbackIntentID: "curious"),
            "ledge": .init(targetPoseID: "ready", clipIDs: ["ledgeLeft"], replaysAtTarget: true,
                           fallbackIntentID: "curious")
        ],
        transitionClipIDs: ["settle", "wake"]
    )
    return CharacterPackage(
        identifier: "graph.test",
        displayName: "Graph Test",
        canvasPixels: .init(width: 100, height: 100),
        displaySizePoints: .init(width: 96, height: 96),
        groundAnchorPixels: .init(x: 50, y: 90),
        contentBoundsPixels: .init(x: 0, y: 0, width: 100, height: 100),
        poses: [
            "ready": .init(stillFrame: "ready.png"),
            "happy": .init(stillFrame: "happy.png"),
            "asleep": .init(stillFrame: "asleep.png")
        ],
        clips: clips,
        semanticBindings: ["petAction.react": "happy"],
        animationGraph: graph,
        resourceBudget: .init(
            maxDecodedImageBytes: 160_000,
            maxBufferedFrames: 2,
            maxDecodedLayerBytes: 0
        )
    )
}

@Suite("Data-driven character animation graph")
struct CharacterAnimationGraphTests {
    @Test("A sleeping character takes a pose-compatible authored route")
    func poseCompatibleRoute() throws {
        let package = graphPackage()
        try package.validate()
        let plan = try package.plan(for: "happy", from: "asleep")
        #expect(plan.clipIDs == ["wake", "pet", "settle"])
        #expect(plan.startPoseID == "asleep")
        #expect(plan.endPoseID == "ready")
    }

    @Test("Reduce Motion selects the declared semantic alternative")
    func reducedMotionAlternative() throws {
        let package = graphPackage()
        let plan = try package.plan(
            for: "move",
            from: "ready",
            context: CharacterPlaybackContext(reduceMotion: true)
        )
        #expect(plan.requestedIntentID == "move")
        #expect(plan.resolvedIntentID == "curious")
        #expect(plan.clipIDs == ["idle"])
    }

    @Test("Unavailable habitat requirements use fallback, available ones play")
    func capabilityFallback() throws {
        let package = graphPackage()
        let fallback = try package.plan(for: "shelf", from: "ready")
        #expect(fallback.resolvedIntentID == "curious")
        #expect(fallback.clipIDs == ["idle"])

        let supported = try package.plan(
            for: "shelf",
            from: "ready",
            context: CharacterPlaybackContext(habitatID: "topShelf")
        )
        #expect(supported.resolvedIntentID == "shelf")
        #expect(supported.clipIDs == ["shelf"])

        let missingOrientation = try package.plan(
            for: "ledge",
            from: "ready",
            context: CharacterPlaybackContext(capabilityIDs: ["ledge"])
        )
        #expect(missingOrientation.resolvedIntentID == "curious")
        let ledge = try package.plan(
            for: "ledge",
            from: "ready",
            context: CharacterPlaybackContext(capabilityIDs: ["ledge"], orientationID: "left")
        )
        #expect(ledge.clipIDs == ["ledgeLeft"])
    }

    @Test("A held target pose resolves without creating a visual clock")
    func heldPose() throws {
        let package = graphPackage()
        let sleeping = try package.plan(for: "sleep", from: "asleep")
        let ready = try package.plan(for: "ready", from: "ready")
        #expect(sleeping.clipIDs.isEmpty)
        #expect(ready.clipIDs.isEmpty)
    }

    @Test("Dangling graph references and discontinuous intent sequences fail validation")
    func danglingAndDiscontinuous() {
        let dangling = CharacterAnimationGraph(
            defaultPoseID: "ready",
            intents: ["bad": .init(targetPoseID: "ready", clipIDs: ["missing"])]
        )
        #expect(throws: CharacterPackageError.self) {
            try graphPackage(graph: dangling).validate()
        }

        let discontinuous = CharacterAnimationGraph(
            defaultPoseID: "ready",
            intents: ["bad": .init(targetPoseID: "ready", clipIDs: ["pet", "idle"])]
        )
        #expect(throws: CharacterPackageError.self) {
            try graphPackage(graph: discontinuous).validate()
        }
    }

    @Test("Fallback and reduced-motion cycles are rejected before playback")
    func fallbackCycles() {
        let cycle = CharacterAnimationGraph(
            defaultPoseID: "ready",
            intents: [
                "a": .init(targetPoseID: "ready", fallbackIntentID: "b"),
                "b": .init(targetPoseID: "ready", reducedMotionIntentID: "a")
            ]
        )
        #expect(throws: CharacterPackageError.self) {
            try graphPackage(graph: cycle).validate()
        }
    }

    @Test("Unknown intents and impossible routes fail deterministically")
    func noRoute() throws {
        let package = graphPackage()
        #expect(throws: CharacterPackageError.self) {
            try package.plan(for: "missing", from: "ready")
        }
        #expect(throws: CharacterPackageError.self) {
            try package.plan(for: "happy", from: "unknownPose")
        }
    }
}
