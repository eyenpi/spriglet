import Foundation
import SprigletCore
import Testing

private func legacyManifest(version: Int = 2) -> SproutSampleManifest {
    let offsets: [SampleClipID: [SamplePoint]] = [
        .idle: [.zero, .zero],
        .walkRight: [.zero, .init(x: 12, y: 0), .init(x: 24, y: 0)],
        .walkLeft: [.zero, .init(x: -12, y: 0), .init(x: -24, y: 0)],
        .pet: [.zero, .zero],
        .settle: [.zero, .zero],
        .fallAsleep: [.zero, .zero],
        .wakeUp: [.zero, .zero]
    ]
    let ids = version == 1 ? SampleClipID.versionOneCases : SampleClipID.allCases
    return SproutSampleManifest(
        schemaVersion: version,
        canvasPixels: .init(width: 448, height: 448),
        displaySizePoints: .init(width: 96, height: 96),
        framesPerSecond: 30,
        groundAnchorPixels: .init(x: 224, y: 30),
        restFrame: "rest.png",
        sleepFrame: "sleep.png",
        clips: Dictionary(uniqueKeysWithValues: ids.map { id in
            (id.rawValue, .init(frames: offsets[id]!.enumerated().map { index, offset in
                .init(file: "clips/\(id.rawValue)/\(index).png", rootOffsetPoints: offset)
            }))
        })
    )
}

private func layeredCharacterPackage(
    layers replacementLayers: [String: CharacterPackage.Layer]? = nil,
    graph replacementGraph: CharacterAnimationGraph? = nil,
    budget replacementBudget: CharacterPackage.ResourceBudget? = nil
) -> CharacterPackage {
    let layers: [String: CharacterPackage.Layer] = replacementLayers ?? [
        "body": .init(
            file: "layers/body.png",
            framePixels: .init(x: 10, y: 10, width: 80, height: 80),
            pivotPixels: .init(x: 50, y: 70),
            zIndex: 0
        ),
        "eye": .init(
            file: "layers/eye.png",
            parentID: "body",
            framePixels: .init(x: 40, y: 30, width: 10, height: 10),
            pivotPixels: .init(x: 45, y: 35),
            zIndex: 1,
            mask: .init(file: "layers/eye.mask.png", activationChannelID: "gaze")
        ),
        "blink": .init(
            file: "layers/blink.png",
            parentID: "body",
            framePixels: .init(x: 40, y: 30, width: 10, height: 10),
            pivotPixels: .init(x: 45, y: 35),
            zIndex: 1,
            defaultOpacity: 0
        )
    ]
    let clips: [String: CharacterPackage.Clip] = [
        "idle": .init(
            startPoseID: "ready",
            endPoseID: "ready",
            framesPerSecond: 30,
            frames: [.init(file: "clips/idle.png", rootOffsetPoints: .zero)],
            tags: ["idle"],
            interruptionMarkers: [.init(frameIndex: 0, id: "settled")],
            semanticEvents: [.init(frameIndex: 0, id: "blinkClosed")]
        )
    ]
    let graph = replacementGraph ?? CharacterAnimationGraph(
        defaultPoseID: "ready",
        intents: ["curious": .init(targetPoseID: "ready", clipIDs: ["idle"], replaysAtTarget: true)]
    )
    return CharacterPackage(
        identifier: "acorn.test",
        displayName: "Acorn Test",
        canvasPixels: .init(width: 100, height: 100),
        displaySizePoints: .init(width: 96, height: 96),
        groundAnchorPixels: .init(x: 50, y: 90),
        contentBoundsPixels: .init(x: 10, y: 10, width: 80, height: 80),
        featurePolicy: .init(required: [
            "character-package.core", "animation-graph.routes", "layered-rest-rig"
        ]),
        capabilities: ["floor"],
        poses: [
            "ready": .init(layerIDs: ["body", "eye"], hitRegionID: "body")
        ],
        clips: clips,
        layers: layers,
        proceduralChannels: [
            "gaze": .init(
                semanticID: "gaze",
                layerIDs: ["eye"],
                kind: .translation(maximumOffsetPixels: .init(x: 1, y: 1))
            ),
            "breath": .init(
                semanticID: "breath",
                layerIDs: ["body"],
                kind: .scale(maximumDelta: .init(x: 0, y: 0.004)),
                durationSeconds: 3.2
            ),
            "blink": .init(
                semanticID: "blink",
                layerIDs: ["eye"],
                kind: .discreteReplacement(
                    layerIDs: ["blink", "blink", "blink"],
                    replacesLayerIDs: ["eye"]
                ),
                durationSeconds: 0.16
            )
        ],
        hitRegions: [
            "body": .init(pointsPixels: [
                .init(x: 20, y: 20), .init(x: 80, y: 20),
                .init(x: 80, y: 90), .init(x: 20, y: 90)
            ])
        ],
        semanticBindings: ["petAction.blink": "curious"],
        animationGraph: graph,
        resourceBudget: replacementBudget ?? .init(
            maxDecodedImageBytes: 160_000,
            maxBufferedFrames: 2,
            maxDecodedLayerBytes: 30_000
        )
    )
}

@Suite("Character package schema 3")
struct CharacterPackageTests {
    @Test("Legacy schemas adapt without changing frame timing or root motion", arguments: [1, 2])
    func exactLegacyAdaptation(version: Int) throws {
        let legacy = legacyManifest(version: version)
        let package = try CharacterPackage(adapting: legacy, identifier: "acorn.legacy")

        #expect(package.schemaVersion == 3)
        #expect(package.canvasPixels == legacy.canvasPixels)
        #expect(package.displaySizePoints == legacy.displaySizePoints)
        #expect(package.groundAnchorPixels == SamplePoint(x: 224, y: 418))
        #expect(package.capabilities.contains("animatedSleep") == (version == 2))
        for (id, source) in legacy.clips {
            let adapted = try #require(package.clips[id])
            #expect(adapted.framesPerSecond == legacy.framesPerSecond)
            #expect(adapted.frames.map(\.file) == source.frames.map(\.file))
            #expect(adapted.frames.map(\.rootOffsetPoints) == source.frames.map(\.rootOffsetPoints))
        }
    }

    @Test("Legacy graph produces every existing transition plan", arguments: [1, 2])
    func legacyGraphCompatibility(version: Int) throws {
        let package = try CharacterPackage(adapting: legacyManifest(version: version))
        for transition in SampleTransitionIntent.allCases {
            for sleeping in [false, true] {
                let expected = SampleTransitionPlan(
                    to: transition,
                    isSleeping: sleeping,
                    animatedSleep: version == 2
                )
                let plan = try package.plan(
                    for: transition,
                    from: sleeping ? "asleep" : "ready"
                )
                #expect(plan.clipIDs == expected.clips.map(\.rawValue))
                #expect(plan.endPoseID == (transition == .sleep ? "asleep" : "ready"))
            }
        }
    }

    @Test("Schema 3 JSON round-trips after complete validation")
    func roundTrip() throws {
        let package = try CharacterPackage(adapting: legacyManifest())
        let decoded = try CharacterPackage.decode(JSONEncoder().encode(package))
        #expect(decoded == package)
    }

    @Test("Display choices scale point-space roots without changing pixel rig data",
          arguments: PetDisplaySize.allCases)
    func displayScaling(size: PetDisplaySize) throws {
        let source = try CharacterPackage(adapting: legacyManifest())
        let scaled = try source.scaled(to: size)
        #expect(scaled.displaySizePoints == SampleSize(
            width: source.displaySizePoints.width * size.scale,
            height: source.displaySizePoints.height * size.scale
        ))
        #expect(scaled.canvasPixels == source.canvasPixels)
        #expect(scaled.groundAnchorPixels == source.groundAnchorPixels)
        #expect(scaled.contentBoundsPixels == source.contentBoundsPixels)
        #expect(scaled.layers == source.layers)
        #expect(scaled.proceduralChannels == source.proceduralChannels)
        #expect(scaled.animationGraph == source.animationGraph)
        for (id, clip) in source.clips {
            let resized = try #require(scaled.clips[id])
            #expect(resized.framesPerSecond == clip.framesPerSecond)
            #expect(resized.frames.map(\.file) == clip.frames.map(\.file))
            for (frame, authored) in zip(resized.frames, clip.frames) {
                #expect(frame.rootOffsetPoints == SamplePoint(
                    x: authored.rootOffsetPoints.x * size.scale,
                    y: authored.rootOffsetPoints.y * size.scale
                ))
            }
        }
    }

    @Test("Unknown required features fail while optional metadata is ignored")
    func featureCompatibility() throws {
        let source = try CharacterPackage(adapting: legacyManifest())
        let encoded = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var features = try #require(object["featurePolicy"] as? [String: Any])
        features["required"] = ["character-package.core", "future.renderer.required"]
        object["featurePolicy"] = features
        #expect(throws: CharacterPackageError.self) {
            try CharacterPackage.decode(JSONSerialization.data(withJSONObject: object))
        }

        features["required"] = ["character-package.core", "animation-graph.routes"]
        features["optional"] = ["future.sparkles.optional"]
        object["featurePolicy"] = features
        let optional = try CharacterPackage.decode(JSONSerialization.data(withJSONObject: object))
        #expect(optional.featurePolicy.optional == ["future.sparkles.optional"])
    }

    @Test("Layered rig data validates masks, pivots, channels, hit regions and budgets")
    func layeredRig() throws {
        let package = layeredCharacterPackage()
        try package.validate()
        let decoded = try CharacterPackage.decode(JSONEncoder().encode(package))
        #expect(decoded.proceduralChannels.count == 3)
        #expect(decoded.layers["eye"]?.mask?.activationChannelID == "gaze")

        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(package)
        ) as? [String: Any])
        var channels = try #require(object["proceduralChannels"] as? [String: Any])
        var breath = try #require(channels["breath"] as? [String: Any])
        breath["repeats"] = true
        channels["breath"] = breath
        object["proceduralChannels"] = channels
        #expect(throws: CharacterPackageError.self) {
            try CharacterPackage.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("Layer ancestry cycles and decoded-byte overruns fail closed")
    func invalidLayerResources() {
        let cycle: [String: CharacterPackage.Layer] = [
            "a": .init(
                file: "a.png", parentID: "b",
                framePixels: .init(x: 0, y: 0, width: 10, height: 10),
                pivotPixels: .zero, zIndex: 0
            ),
            "b": .init(
                file: "b.png", parentID: "a",
                framePixels: .init(x: 0, y: 0, width: 10, height: 10),
                pivotPixels: .zero, zIndex: 1
            )
        ]
        #expect(throws: CharacterPackageError.self) {
            try layeredCharacterPackage(layers: cycle).validate()
        }
        #expect(throws: CharacterPackageError.self) {
            try layeredCharacterPackage(budget: .init(
                maxDecodedImageBytes: 40_000,
                maxBufferedFrames: 1,
                maxDecodedLayerBytes: 1
            )).validate()
        }
    }

    @Test("Layer crops use whole pixels and image budgets reserve stable poses")
    func exactLayerCropsAndStableBudget() throws {
        let package = layeredCharacterPackage()
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(package)
        ) as? [String: Any])
        var layers = try #require(object["layers"] as? [String: Any])
        var body = try #require(layers["body"] as? [String: Any])
        var frame = try #require(body["framePixels"] as? [String: Any])
        frame["width"] = 79.5
        body["framePixels"] = frame
        layers["body"] = body
        object["layers"] = layers
        #expect(throws: CharacterPackageError.self) {
            try CharacterPackage.decode(JSONSerialization.data(withJSONObject: object))
        }

        #expect(throws: CharacterPackageError.self) {
            try layeredCharacterPackage(budget: .init(
                maxDecodedImageBytes: 80_000,
                maxBufferedFrames: 2,
                maxDecodedLayerBytes: 30_000
            )).validate()
        }
    }

    @Test("Oversized input and unsafe resource paths are rejected")
    func boundedDecodeAndPaths() throws {
        #expect(throws: CharacterPackageError.self) {
            try CharacterPackage.decode(Data(repeating: 32, count: CharacterPackage.maximumEncodedBytes + 1))
        }
        let source = try CharacterPackage(adapting: legacyManifest())
        let encoded = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var poses = try #require(object["poses"] as? [String: Any])
        var ready = try #require(poses["ready"] as? [String: Any])
        ready["stillFrame"] = "../escape.png"
        poses["ready"] = ready
        object["poses"] = poses
        #expect(throws: CharacterPackageError.self) {
            try CharacterPackage.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("Clip identifiers remain open and reject malformed values")
    func openClipIdentity() throws {
        let custom = try #require(CharacterClipID(rawValue: "acorn.peek.notchLeft"))
        #expect(custom.rawValue == "acorn.peek.notchLeft")
        #expect(CharacterClipID(rawValue: "../peek") == nil)
        #expect(try JSONDecoder().decode(CharacterClipID.self, from: Data("\"newClip\"".utf8)).rawValue == "newClip")
    }
}
