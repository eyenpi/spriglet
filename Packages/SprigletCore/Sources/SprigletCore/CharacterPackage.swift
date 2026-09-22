import Foundation

/// Open clip identity. Legacy constants preserve source compatibility while new
/// character packages can add validated identifiers without changing Swift code.
public struct CharacterClipID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...80).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
              }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let result = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid character clip identifier."
            )
        }
        self = result
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let idle = Self(rawValue: "idle")!
    public static let walkRight = Self(rawValue: "walkRight")!
    public static let walkLeft = Self(rawValue: "walkLeft")!
    public static let pet = Self(rawValue: "pet")!
    public static let settle = Self(rawValue: "settle")!
    public static let fallAsleep = Self(rawValue: "fallAsleep")!
    public static let wakeUp = Self(rawValue: "wakeUp")!
    public static let versionOneCases: [Self] = [.idle, .walkRight, .walkLeft, .pet, .settle]
    public static let allCases: [Self] = versionOneCases + [.fallAsleep, .wakeUp]
}

/// A data-driven character package. Schema 3 removes clip names and pose
/// topology from application code while keeping every authored frame paired
/// with its exact root displacement.
public struct CharacterPackage: Codable, Equatable, Sendable {
    public static let schemaVersion = 3
    public static let maximumEncodedBytes = 4_000_000

    public enum CoordinateSystem: String, Codable, Sendable {
        case topLeftPixels
    }

    public struct Rect: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct FeaturePolicy: Codable, Equatable, Sendable {
        /// Every identifier here must be understood by this loader.
        public let required: [String]
        /// Unknown optional identifiers are explicitly safe to ignore.
        public let optional: [String]

        public init(required: [String], optional: [String] = []) {
            self.required = required
            self.optional = optional
        }
    }

    public struct ResourceBudget: Codable, Equatable, Sendable {
        public let maxDecodedImageBytes: Int
        public let maxBufferedFrames: Int
        public let maxDecodedLayerBytes: Int

        public init(
            maxDecodedImageBytes: Int,
            maxBufferedFrames: Int,
            maxDecodedLayerBytes: Int
        ) {
            self.maxDecodedImageBytes = maxDecodedImageBytes
            self.maxBufferedFrames = maxBufferedFrames
            self.maxDecodedLayerBytes = maxDecodedLayerBytes
        }
    }

    public struct Pose: Codable, Equatable, Sendable {
        public let stillFrame: String?
        public let layerIDs: [String]
        public let hitRegionID: String?

        public init(
            stillFrame: String? = nil,
            layerIDs: [String] = [],
            hitRegionID: String? = nil
        ) {
            self.stillFrame = stillFrame
            self.layerIDs = layerIDs
            self.hitRegionID = hitRegionID
        }
    }

    public struct Frame: Codable, Equatable, Sendable {
        public let file: String
        public let rootOffsetPoints: SamplePoint

        public init(file: String, rootOffsetPoints: SamplePoint) {
            self.file = file
            self.rootOffsetPoints = rootOffsetPoints
        }
    }

    public enum MotionClass: String, Codable, Sendable {
        case stationary
        case local
        case relocation
        case depth

        var allowedWithReduceMotion: Bool {
            self == .stationary || self == .local
        }
    }

    public struct ClipRequirements: Codable, Equatable, Sendable {
        public let habitatIDs: [String]
        public let orientationIDs: [String]
        public let capabilityIDs: [String]

        public init(
            habitatIDs: [String] = [],
            orientationIDs: [String] = [],
            capabilityIDs: [String] = []
        ) {
            self.habitatIDs = habitatIDs
            self.orientationIDs = orientationIDs
            self.capabilityIDs = capabilityIDs
        }

        func isSatisfied(by context: CharacterPlaybackContext) -> Bool {
            (habitatIDs.isEmpty || context.habitatID.map(habitatIDs.contains) == true)
                && (orientationIDs.isEmpty || context.orientationID.map(orientationIDs.contains) == true)
                && Set(capabilityIDs).isSubset(of: context.capabilityIDs)
        }
    }

    public struct FrameMarker: Codable, Equatable, Sendable {
        public let frameIndex: Int
        public let id: String

        public init(frameIndex: Int, id: String) {
            self.frameIndex = frameIndex
            self.id = id
        }
    }

    public struct SemanticEvent: Codable, Equatable, Sendable {
        public let frameIndex: Int
        public let id: String

        public init(frameIndex: Int, id: String) {
            self.frameIndex = frameIndex
            self.id = id
        }
    }

    public struct ChannelOwnership: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable {
            case exclusive
            case additive
        }

        public let channelIDs: [String]
        public let mode: Mode

        public init(channelIDs: [String], mode: Mode = .exclusive) {
            self.channelIDs = channelIDs
            self.mode = mode
        }
    }

    public struct Clip: Codable, Equatable, Sendable {
        public let startPoseID: String
        public let endPoseID: String
        public let framesPerSecond: Double
        public let frames: [Frame]
        public let tags: [String]
        public let requirements: ClipRequirements
        public let motionClass: MotionClass
        public let interruptionMarkers: [FrameMarker]
        public let semanticEvents: [SemanticEvent]
        public let ownership: ChannelOwnership

        public init(
            startPoseID: String,
            endPoseID: String,
            framesPerSecond: Double,
            frames: [Frame],
            tags: [String] = [],
            requirements: ClipRequirements = ClipRequirements(),
            motionClass: MotionClass = .stationary,
            interruptionMarkers: [FrameMarker] = [],
            semanticEvents: [SemanticEvent] = [],
            ownership: ChannelOwnership = ChannelOwnership(channelIDs: ["body", "face", "shadow", "secondaryMotion"])
        ) {
            self.startPoseID = startPoseID
            self.endPoseID = endPoseID
            self.framesPerSecond = framesPerSecond
            self.frames = frames
            self.tags = tags
            self.requirements = requirements
            self.motionClass = motionClass
            self.interruptionMarkers = interruptionMarkers
            self.semanticEvents = semanticEvents
            self.ownership = ownership
        }
    }

    public struct LayerMask: Codable, Equatable, Sendable {
        public let file: String
        public let activationChannelID: String

        public init(file: String, activationChannelID: String) {
            self.file = file
            self.activationChannelID = activationChannelID
        }
    }

    public struct Layer: Codable, Equatable, Sendable {
        public let file: String
        public let parentID: String?
        public let framePixels: Rect
        public let pivotPixels: SamplePoint
        public let zIndex: Int
        public let defaultOpacity: Double
        public let mask: LayerMask?

        public init(
            file: String,
            parentID: String? = nil,
            framePixels: Rect,
            pivotPixels: SamplePoint,
            zIndex: Int,
            defaultOpacity: Double = 1,
            mask: LayerMask? = nil
        ) {
            self.file = file
            self.parentID = parentID
            self.framePixels = framePixels
            self.pivotPixels = pivotPixels
            self.zIndex = zIndex
            self.defaultOpacity = defaultOpacity
            self.mask = mask
        }
    }

    public struct ProceduralChannel: Codable, Equatable, Sendable {
        public enum Kind: Codable, Equatable, Sendable {
            case translation(maximumOffsetPixels: SamplePoint)
            case scale(maximumDelta: SamplePoint)
            case rotation(maximumDegrees: Double)
            case discreteReplacement(layerIDs: [String], replacesLayerIDs: [String])

            private enum KindName: String, Codable {
                case translation, scale, rotation, discreteReplacement
            }

            private enum CodingKeys: String, CodingKey {
                case type
                case maximumOffsetPixels
                case maximumDelta
                case maximumDegrees
                case layerIDs
                case replacesLayerIDs
            }

            public init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                switch try values.decode(KindName.self, forKey: .type) {
                case .translation:
                    self = .translation(
                        maximumOffsetPixels: try values.decode(SamplePoint.self, forKey: .maximumOffsetPixels)
                    )
                case .scale:
                    self = .scale(
                        maximumDelta: try values.decode(SamplePoint.self, forKey: .maximumDelta)
                    )
                case .rotation:
                    self = .rotation(
                        maximumDegrees: try values.decode(Double.self, forKey: .maximumDegrees)
                    )
                case .discreteReplacement:
                    self = .discreteReplacement(
                        layerIDs: try values.decode([String].self, forKey: .layerIDs),
                        replacesLayerIDs: try values.decode([String].self, forKey: .replacesLayerIDs)
                    )
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .translation(maximumOffsetPixels):
                    try values.encode(KindName.translation, forKey: .type)
                    try values.encode(maximumOffsetPixels, forKey: .maximumOffsetPixels)
                case let .scale(maximumDelta):
                    try values.encode(KindName.scale, forKey: .type)
                    try values.encode(maximumDelta, forKey: .maximumDelta)
                case let .rotation(maximumDegrees):
                    try values.encode(KindName.rotation, forKey: .type)
                    try values.encode(maximumDegrees, forKey: .maximumDegrees)
                case let .discreteReplacement(layerIDs, replacesLayerIDs):
                    try values.encode(KindName.discreteReplacement, forKey: .type)
                    try values.encode(layerIDs, forKey: .layerIDs)
                    try values.encode(replacesLayerIDs, forKey: .replacesLayerIDs)
                }
            }
        }

        /// Renderer-recognized behavior such as gaze, blink, breath, lean, or
        /// secondaryMotion. Unknown semantics are safe to ignore.
        public let semanticID: String?
        public let layerIDs: [String]
        public let kind: Kind
        public let durationSeconds: Double?
        public let delaySeconds: Double
        public let repeats: Bool

        public init(
            semanticID: String? = nil,
            layerIDs: [String],
            kind: Kind,
            durationSeconds: Double? = nil,
            delaySeconds: Double = 0,
            repeats: Bool = false
        ) {
            self.semanticID = semanticID
            self.layerIDs = layerIDs
            self.kind = kind
            self.durationSeconds = durationSeconds
            self.delaySeconds = delaySeconds
            self.repeats = repeats
        }
    }

    public struct HitRegion: Codable, Equatable, Sendable {
        public let pointsPixels: [SamplePoint]

        public init(pointsPixels: [SamplePoint]) {
            self.pointsPixels = pointsPixels
        }
    }

    public let schemaVersion: Int
    public let identifier: String
    public let displayName: String
    public let coordinateSystem: CoordinateSystem
    public let canvasPixels: SampleSize
    public let displaySizePoints: SampleSize
    public let groundAnchorPixels: SamplePoint
    public let contentBoundsPixels: Rect
    public let featurePolicy: FeaturePolicy
    public let capabilities: [String]
    public let poses: [String: Pose]
    public let clips: [String: Clip]
    public let layers: [String: Layer]
    public let proceduralChannels: [String: ProceduralChannel]
    public let hitRegions: [String: HitRegion]
    public let semanticBindings: [String: String]
    /// Optional, data-owned contract for one finite floor-to-ledge visit.
    /// Characters that omit it remain fully valid and expose no habitat action.
    public let habitatVisitContent: HabitatVisitContent?
    public let animationGraph: CharacterAnimationGraph
    public let resourceBudget: ResourceBudget

    public init(
        schemaVersion: Int = CharacterPackage.schemaVersion,
        identifier: String,
        displayName: String,
        coordinateSystem: CoordinateSystem = .topLeftPixels,
        canvasPixels: SampleSize,
        displaySizePoints: SampleSize,
        groundAnchorPixels: SamplePoint,
        contentBoundsPixels: Rect,
        featurePolicy: FeaturePolicy = FeaturePolicy(required: ["character-package.core", "animation-graph.routes"]),
        capabilities: [String] = [],
        poses: [String: Pose],
        clips: [String: Clip],
        layers: [String: Layer] = [:],
        proceduralChannels: [String: ProceduralChannel] = [:],
        hitRegions: [String: HitRegion] = [:],
        semanticBindings: [String: String],
        habitatVisitContent: HabitatVisitContent? = nil,
        animationGraph: CharacterAnimationGraph,
        resourceBudget: ResourceBudget
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.displayName = displayName
        self.coordinateSystem = coordinateSystem
        self.canvasPixels = canvasPixels
        self.displaySizePoints = displaySizePoints
        self.groundAnchorPixels = groundAnchorPixels
        self.contentBoundsPixels = contentBoundsPixels
        self.featurePolicy = featurePolicy
        self.capabilities = capabilities
        self.poses = poses
        self.clips = clips
        self.layers = layers
        self.proceduralChannels = proceduralChannels
        self.hitRegions = hitRegions
        self.semanticBindings = semanticBindings
        self.habitatVisitContent = habitatVisitContent
        self.animationGraph = animationGraph
        self.resourceBudget = resourceBudget
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw CharacterPackageError.invalid("Character package is too large.")
        }
        let package = try JSONDecoder().decode(Self.self, from: data)
        try package.validate()
        return package
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw CharacterPackageError.invalid("Unsupported character package version.")
        }
        try validateIdentityAndGeometry()
        try validateFeaturesAndResources()
        try validateLayersAndChannels()
        try validatePosesAndClips()
        try animationGraph.validate(package: self)
        try validateHabitatVisitContent()
    }

    public init(
        adapting validatedSample: SproutSampleManifest,
        identifier: String = "legacy.sprout"
    ) throws {
        try validatedSample.validate()
        let poseReady = "ready"
        let poseHappy = "happy"
        let poseAsleep = "asleep"
        var adaptedClips: [String: Clip] = [:]

        for legacyID in SampleClipID.allCases {
            guard let source = validatedSample.clips[legacyID.rawValue] else { continue }
            let boundary: (String, String)
            let motion: MotionClass
            switch legacyID {
            case .idle:
                boundary = (poseReady, poseReady)
                motion = .stationary
            case .walkRight, .walkLeft:
                boundary = (poseReady, poseReady)
                motion = .relocation
            case .pet:
                boundary = (poseReady, poseHappy)
                motion = .local
            case .settle:
                boundary = (poseHappy, poseReady)
                motion = .local
            case .fallAsleep:
                boundary = (poseReady, poseAsleep)
                motion = .local
            case .wakeUp:
                boundary = (poseAsleep, poseReady)
                motion = .local
            default:
                continue
            }
            adaptedClips[legacyID.rawValue] = Clip(
                startPoseID: boundary.0,
                endPoseID: boundary.1,
                framesPerSecond: validatedSample.framesPerSecond,
                frames: source.frames.map { Frame(file: $0.file, rootOffsetPoints: $0.rootOffsetPoints) },
                tags: legacyID == .walkLeft || legacyID == .walkRight ? ["locomotion"] : ["gesture"],
                motionClass: motion
            )
        }

        let happyFrame = validatedSample.clips[SampleClipID.pet.rawValue]?.frames.last?.file
            ?? validatedSample.restFrame
        let adaptedPoses: [String: Pose] = [
            poseReady: Pose(stillFrame: validatedSample.restFrame),
            poseHappy: Pose(stillFrame: happyFrame),
            poseAsleep: Pose(stillFrame: validatedSample.sleepFrame)
        ]
        let animatedSleep = validatedSample.supportsAnimatedSleep
        let intents: [String: CharacterAnimationGraph.Intent] = [
            "ready": .init(targetPoseID: poseReady),
            "curious": .init(targetPoseID: poseReady, clipIDs: [SampleClipID.idle.rawValue], replaysAtTarget: true),
            "moveRight": .init(targetPoseID: poseReady, clipIDs: [SampleClipID.walkRight.rawValue],
                               replaysAtTarget: true, fallbackIntentID: "curious", reducedMotionIntentID: "curious"),
            "moveLeft": .init(targetPoseID: poseReady, clipIDs: [SampleClipID.walkLeft.rawValue],
                              replaysAtTarget: true, fallbackIntentID: "curious", reducedMotionIntentID: "curious"),
            "happy": .init(targetPoseID: poseReady,
                           clipIDs: [SampleClipID.pet.rawValue, SampleClipID.settle.rawValue], replaysAtTarget: true),
            "sleep": .init(targetPoseID: poseAsleep,
                           clipIDs: animatedSleep ? [SampleClipID.fallAsleep.rawValue] : []),
            "wake": .init(targetPoseID: poseReady)
        ]
        let transitionClipIDs = animatedSleep
            ? [SampleClipID.settle.rawValue, SampleClipID.wakeUp.rawValue]
            : [SampleClipID.settle.rawValue]
        let instantTransitions = animatedSleep ? [] : [
            CharacterAnimationGraph.InstantTransition(fromPoseID: poseReady, toPoseID: poseAsleep),
            CharacterAnimationGraph.InstantTransition(fromPoseID: poseAsleep, toPoseID: poseReady)
        ]
        let graph = CharacterAnimationGraph(
            defaultPoseID: poseReady,
            intents: intents,
            transitionClipIDs: transitionClipIDs,
            instantTransitions: instantTransitions
        )
        let bindings = Self.legacySemanticBindings
        let frameBytes = Int(validatedSample.canvasPixels.width * validatedSample.canvasPixels.height * 4)

        self.init(
            identifier: identifier,
            displayName: "Legacy Sprout Character",
            canvasPixels: validatedSample.canvasPixels,
            displaySizePoints: validatedSample.displaySizePoints,
            groundAnchorPixels: SamplePoint(
                x: validatedSample.groundAnchorPixels.x,
                y: validatedSample.canvasPixels.height - validatedSample.groundAnchorPixels.y
            ),
            contentBoundsPixels: Rect(
                x: 0,
                y: 0,
                width: validatedSample.canvasPixels.width,
                height: validatedSample.canvasPixels.height
            ),
            featurePolicy: FeaturePolicy(required: ["character-package.core", "animation-graph.routes"]),
            capabilities: animatedSleep ? ["animatedSleep"] : [],
            poses: adaptedPoses,
            clips: adaptedClips,
            semanticBindings: bindings,
            animationGraph: graph,
            resourceBudget: ResourceBudget(
                maxDecodedImageBytes: frameBytes * 15,
                maxBufferedFrames: 12,
                maxDecodedLayerBytes: 0
            )
        )
        try validate()
    }

    public func plan(
        for intentID: String,
        from poseID: String,
        context: CharacterPlaybackContext = CharacterPlaybackContext()
    ) throws -> CharacterAnimationPlan {
        try animationGraph.plan(for: intentID, from: poseID, clips: clips, context: context)
    }

    public func plan(
        for action: PetAction,
        from poseID: String,
        context: CharacterPlaybackContext = CharacterPlaybackContext()
    ) throws -> CharacterAnimationPlan {
        try plan(forBinding: "petAction.\(action.rawValue)", from: poseID, context: context)
    }

    public func plan(
        for transition: SampleTransitionIntent,
        from poseID: String,
        context: CharacterPlaybackContext = CharacterPlaybackContext()
    ) throws -> CharacterAnimationPlan {
        try plan(forBinding: "transition.\(transition.rawValue)", from: poseID, context: context)
    }

    /// Scales only authored point-space presentation and root movement. Pixel
    /// geometry, pivots, masks, frame paths, graph topology, and timing remain
    /// the validated source package.
    public func scaled(to displaySize: PetDisplaySize) throws -> CharacterPackage {
        try validate()
        guard canvasPixels.width == canvasPixels.height,
              displaySizePoints.width == displaySizePoints.height else {
            throw CharacterPackageError.invalid("Character size choices require a square authored canvas.")
        }
        let factor = displaySize.scale
        let result = CharacterPackage(
            identifier: identifier,
            displayName: displayName,
            coordinateSystem: coordinateSystem,
            canvasPixels: canvasPixels,
            displaySizePoints: SampleSize(
                width: displaySizePoints.width * factor,
                height: displaySizePoints.height * factor
            ),
            groundAnchorPixels: groundAnchorPixels,
            contentBoundsPixels: contentBoundsPixels,
            featurePolicy: featurePolicy,
            capabilities: capabilities,
            poses: poses,
            clips: clips.mapValues { clip in
                Clip(
                    startPoseID: clip.startPoseID,
                    endPoseID: clip.endPoseID,
                    framesPerSecond: clip.framesPerSecond,
                    frames: clip.frames.map { frame in
                        Frame(
                            file: frame.file,
                            rootOffsetPoints: SamplePoint(
                                x: frame.rootOffsetPoints.x * factor,
                                y: frame.rootOffsetPoints.y * factor
                            )
                        )
                    },
                    tags: clip.tags,
                    requirements: clip.requirements,
                    motionClass: clip.motionClass,
                    interruptionMarkers: clip.interruptionMarkers,
                    semanticEvents: clip.semanticEvents,
                    ownership: clip.ownership
                )
            },
            layers: layers,
            proceduralChannels: proceduralChannels,
            hitRegions: hitRegions,
            semanticBindings: semanticBindings,
            habitatVisitContent: habitatVisitContent,
            animationGraph: animationGraph,
            resourceBudget: resourceBudget
        )
        try result.validate()
        return result
    }

    private func plan(
        forBinding binding: String,
        from poseID: String,
        context: CharacterPlaybackContext
    ) throws -> CharacterAnimationPlan {
        guard let intentID = semanticBindings[binding] else {
            throw CharacterPackageError.noRoute("Character does not bind \(binding).")
        }
        return try plan(for: intentID, from: poseID, context: context)
    }

    private func validateIdentityAndGeometry() throws {
        guard Self.isIdentifier(identifier), !displayName.isEmpty, displayName.count <= 120,
              canvasPixels.width.isFinite, canvasPixels.height.isFinite,
              (64...2_048).contains(canvasPixels.width), (64...2_048).contains(canvasPixels.height),
              canvasPixels.width.rounded() == canvasPixels.width,
              canvasPixels.height.rounded() == canvasPixels.height,
              displaySizePoints.width.isFinite, displaySizePoints.height.isFinite,
              (32...512).contains(displaySizePoints.width), (32...512).contains(displaySizePoints.height),
              Self.isPoint(groundAnchorPixels, in: canvasPixels),
              Self.isRect(contentBoundsPixels, in: canvasPixels, permitsZero: false) else {
            throw CharacterPackageError.invalid("Invalid character identity or geometry.")
        }
    }

    private func validateFeaturesAndResources() throws {
        let supported = Set(["character-package.core", "animation-graph.routes", "layered-rest-rig"])
        let core = Set(["character-package.core", "animation-graph.routes"])
        guard Self.isUniqueIdentifiers(featurePolicy.required),
              Self.isUniqueIdentifiers(featurePolicy.optional),
              core.isSubset(of: Set(featurePolicy.required)),
              Set(featurePolicy.required).isSubset(of: supported),
              Set(featurePolicy.required).isDisjoint(with: featurePolicy.optional),
              Self.isUniqueIdentifiers(capabilities),
              (1...256 * 1_024 * 1_024).contains(resourceBudget.maxDecodedImageBytes),
              (1...60).contains(resourceBudget.maxBufferedFrames),
              (0...128 * 1_024 * 1_024).contains(resourceBudget.maxDecodedLayerBytes) else {
            throw CharacterPackageError.invalid("Unsupported feature or invalid resource budget.")
        }
        let frameBytes = Int(canvasPixels.width * canvasPixels.height * 4)
        // The renderer keeps its awake and sleeping safety stills available
        // while a bounded timeline buffer is live.
        let stableFrameCount = 2
        guard frameBytes <= resourceBudget.maxDecodedImageBytes,
              resourceBudget.maxBufferedFrames + stableFrameCount
                <= resourceBudget.maxDecodedImageBytes / frameBytes else {
            throw CharacterPackageError.invalid("Frame buffer exceeds the decoded image budget.")
        }
    }

    private func validateLayersAndChannels() throws {
        guard layers.count <= 64, proceduralChannels.count <= 32, hitRegions.count <= 32 else {
            throw CharacterPackageError.invalid("Layer, channel, or hit-region inventory is too large.")
        }
        var decodedLayerBytes = 0
        for (id, layer) in layers {
            guard Self.isIdentifier(id), Self.isSafePNGPath(layer.file),
                  Self.isRect(layer.framePixels, in: canvasPixels, permitsZero: false),
                  layer.framePixels.x.rounded() == layer.framePixels.x,
                  layer.framePixels.y.rounded() == layer.framePixels.y,
                  layer.framePixels.width.rounded() == layer.framePixels.width,
                  layer.framePixels.height.rounded() == layer.framePixels.height,
                  Self.isPoint(layer.pivotPixels, in: canvasPixels), (-1_024...1_024).contains(layer.zIndex),
                  layer.defaultOpacity.isFinite, (0...1).contains(layer.defaultOpacity),
                  layer.parentID.map({ $0 != id && layers[$0] != nil }) ?? true,
                  layer.mask.map({ Self.isSafePNGPath($0.file) && Self.isIdentifier($0.activationChannelID) }) ?? true else {
                throw CharacterPackageError.invalid("Invalid layer \(id).")
            }
            decodedLayerBytes += Int(layer.framePixels.width * layer.framePixels.height * 4)
            if layer.mask != nil {
                decodedLayerBytes += Int(layer.framePixels.width * layer.framePixels.height * 4)
            }
            var visited = Set([id])
            var parent = layer.parentID
            while let current = parent {
                guard visited.insert(current).inserted else {
                    throw CharacterPackageError.invalid("Layer parent cycle.")
                }
                parent = layers[current]?.parentID
            }
        }
        guard decodedLayerBytes <= resourceBudget.maxDecodedLayerBytes else {
            throw CharacterPackageError.invalid("Layers exceed the decoded layer budget.")
        }

        for (id, channel) in proceduralChannels {
            guard Self.isIdentifier(id), Self.areReferences(channel.layerIDs, in: layers),
                  !channel.layerIDs.isEmpty,
                  channel.semanticID.map(Self.isIdentifier) ?? true,
                  channel.delaySeconds.isFinite, (0...30).contains(channel.delaySeconds),
                  channel.durationSeconds.map({ $0.isFinite && (0...60).contains($0) }) ?? true,
                  !channel.repeats else {
                throw CharacterPackageError.invalid("Invalid procedural channel \(id).")
            }
            switch channel.kind {
            case let .translation(maximumOffset):
                guard Self.isFinite(maximumOffset), abs(maximumOffset.x) <= 512,
                      abs(maximumOffset.y) <= 512 else {
                    throw CharacterPackageError.invalid("Invalid translation channel \(id).")
                }
            case let .scale(maximumDelta):
                guard Self.isFinite(maximumDelta), abs(maximumDelta.x) <= 1,
                      abs(maximumDelta.y) <= 1 else {
                    throw CharacterPackageError.invalid("Invalid scale channel \(id).")
                }
            case let .rotation(maximumDegrees):
                guard maximumDegrees.isFinite, abs(maximumDegrees) <= 180 else {
                    throw CharacterPackageError.invalid("Invalid rotation channel \(id).")
                }
            case let .discreteReplacement(layerIDs, replacesLayerIDs):
                guard !layerIDs.isEmpty, !replacesLayerIDs.isEmpty,
                      layerIDs.count <= 32, layerIDs.allSatisfy({ layers[$0] != nil }),
                      Self.areReferences(replacesLayerIDs, in: layers) else {
                    throw CharacterPackageError.invalid("Invalid replacement channel \(id).")
                }
            }
        }
        for (id, layer) in layers {
            if let channelID = layer.mask?.activationChannelID,
               proceduralChannels[channelID] == nil {
                throw CharacterPackageError.invalid("Layer \(id) references a missing mask channel.")
            }
        }
        for (id, region) in hitRegions {
            guard Self.isIdentifier(id), (3...32).contains(region.pointsPixels.count),
                  region.pointsPixels.allSatisfy({ Self.isPoint($0, in: canvasPixels) }) else {
                throw CharacterPackageError.invalid("Invalid hit region \(id).")
            }
        }
    }

    private func validatePosesAndClips() throws {
        guard (1...64).contains(poses.count), (1...256).contains(clips.count) else {
            throw CharacterPackageError.invalid("Invalid pose or clip inventory.")
        }
        for (id, pose) in poses {
            guard Self.isIdentifier(id), pose.stillFrame != nil || !pose.layerIDs.isEmpty,
                  pose.stillFrame.map(Self.isSafePNGPath) ?? true,
                  Self.areReferences(pose.layerIDs, in: layers),
                  pose.hitRegionID.map({ hitRegions[$0] != nil }) ?? true else {
                throw CharacterPackageError.invalid("Invalid pose \(id).")
            }
        }
        var totalFrames = 0
        for (id, clip) in clips {
            guard Self.isIdentifier(id), poses[clip.startPoseID] != nil, poses[clip.endPoseID] != nil,
                  clip.framesPerSecond.isFinite, (1...120).contains(clip.framesPerSecond),
                  (1...600).contains(clip.frames.count), clip.frames.first?.rootOffsetPoints == .zero,
                  Self.isUniqueIdentifiers(clip.tags),
                  Self.isUniqueIdentifiers(clip.requirements.habitatIDs),
                  Self.isUniqueIdentifiers(clip.requirements.orientationIDs),
                  Self.isUniqueIdentifiers(clip.requirements.capabilityIDs),
                  Self.isUniqueIdentifiers(clip.ownership.channelIDs), !clip.ownership.channelIDs.isEmpty else {
                throw CharacterPackageError.invalid("Invalid clip \(id).")
            }
            totalFrames += clip.frames.count
            for frame in clip.frames {
                guard Self.isSafePNGPath(frame.file), Self.isFinite(frame.rootOffsetPoints),
                      abs(frame.rootOffsetPoints.x) <= 4_096,
                      abs(frame.rootOffsetPoints.y) <= 4_096 else {
                    throw CharacterPackageError.invalid("Invalid frame in clip \(id).")
                }
            }
            for marker in clip.interruptionMarkers {
                guard clip.frames.indices.contains(marker.frameIndex), Self.isIdentifier(marker.id) else {
                    throw CharacterPackageError.invalid("Invalid marker in clip \(id).")
                }
            }
            for event in clip.semanticEvents {
                guard clip.frames.indices.contains(event.frameIndex), Self.isIdentifier(event.id) else {
                    throw CharacterPackageError.invalid("Invalid event in clip \(id).")
                }
            }
        }
        guard totalFrames <= 3_000 else {
            throw CharacterPackageError.invalid("Character package has too many frames.")
        }
        guard semanticBindings.count <= 64 else {
            throw CharacterPackageError.invalid("Too many semantic bindings.")
        }
        for (binding, intent) in semanticBindings {
            guard Self.isIdentifier(binding), animationGraph.intents[intent] != nil else {
                throw CharacterPackageError.invalid("Invalid semantic binding \(binding).")
            }
        }
    }

    private func validateHabitatVisitContent() throws {
        guard let content = habitatVisitContent else { return }
        guard featurePolicy.optional.contains("animation.habitat-portals-v1"),
              Set(["localPortal", "ledgeGrip"]).isSubset(of: Set(capabilities)) else {
            throw CharacterPackageError.invalid("Habitat visit content requires its declared feature and capabilities.")
        }

        let upperHabitats = ["topShelf", "notchLeft", "notchRight"]
        let roles: [(
            intentID: String, startPoseID: String, targetPoseID: String,
            habitatIDs: [String], markerID: String, semantic: Bool
        )] = [
            (content.floorExitIntentID, content.floorPoseID, content.hiddenPoseID,
             ["floor"], content.fullyHiddenEventID, true),
            (content.ledgeEntryIntentID, content.hiddenPoseID, content.ledgePoseID,
             upperHabitats, content.settledMarkerID, false),
            (content.edgeLookIntentID, content.ledgePoseID, content.ledgePoseID,
             upperHabitats, content.settledMarkerID, false),
            (content.dangleIntentID, content.ledgePoseID, content.hangingPoseID,
             upperHabitats, content.settledMarkerID, false),
            (content.pullUpIntentID, content.hangingPoseID, content.ledgePoseID,
             upperHabitats, content.settledMarkerID, false),
            (content.ledgeExitIntentID, content.ledgePoseID, content.hiddenPoseID,
             upperHabitats, content.fullyHiddenEventID, true),
            (content.floorReentryIntentID, content.hiddenPoseID, content.floorPoseID,
             ["floor"], content.settledMarkerID, false)
        ]
        guard content.floorPoseID == animationGraph.defaultPoseID,
              [content.hiddenPoseID, content.ledgePoseID, content.hangingPoseID, content.floorPoseID]
                .allSatisfy({ poses[$0] != nil }) else {
            throw CharacterPackageError.invalid("Habitat visit content references an invalid stable pose.")
        }

        for role in roles {
            guard let intent = animationGraph.intents[role.intentID],
                  intent.targetPoseID == role.targetPoseID,
                  let terminalClipID = intent.clipIDs.last,
                  let terminalClip = clips[terminalClipID],
                  terminalClip.endPoseID == role.targetPoseID,
                  let terminalFrameIndex = terminalClip.frames.indices.last else {
                throw CharacterPackageError.invalid("Habitat visit content references an invalid intent endpoint.")
            }
            let hasMarker = role.semantic
                ? terminalClip.semanticEvents.contains {
                    $0.frameIndex == terminalFrameIndex && $0.id == role.markerID
                }
                : terminalClip.interruptionMarkers.contains {
                    $0.frameIndex == terminalFrameIndex && $0.id == role.markerID
                }
            guard hasMarker else {
                throw CharacterPackageError.invalid("Habitat visit content is missing its terminal marker contract.")
            }

            for habitatID in role.habitatIDs {
                let context = CharacterPlaybackContext(
                    capabilityIDs: Set(capabilities),
                    habitatID: habitatID,
                    orientationID: "upright",
                    reduceMotion: false
                )
                guard let plan = try? animationGraph.plan(
                    for: role.intentID,
                    from: role.startPoseID,
                    clips: clips,
                    context: context
                ), plan.resolvedIntentID == role.intentID,
                      plan.startPoseID == role.startPoseID,
                      plan.endPoseID == role.targetPoseID,
                      !plan.clipIDs.isEmpty,
                      plan.clipIDs == intent.clipIDs,
                      plan.clipIDs.allSatisfy({ clipID in
                          clips[clipID]?.frames.allSatisfy { $0.rootOffsetPoints == .zero } == true
                      }) else {
                    throw CharacterPackageError.invalid(
                        "Habitat visit content does not provide an exact zero-root route."
                    )
                }
            }
        }
    }

    static func isIdentifier(_ value: String) -> Bool {
        (1...80).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
            }
    }

    static func isUniqueIdentifiers(_ values: [String]) -> Bool {
        values.count <= 64 && Set(values).count == values.count && values.allSatisfy(isIdentifier)
    }

    fileprivate static func isSafePNGPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 240 && path.hasSuffix(".png") && !path.contains("\\")
            && !path.contains(":") && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    fileprivate static func isFinite(_ point: SamplePoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    fileprivate static func isPoint(_ point: SamplePoint, in canvas: SampleSize) -> Bool {
        isFinite(point) && (0...canvas.width).contains(point.x) && (0...canvas.height).contains(point.y)
    }

    fileprivate static func isRect(_ rect: Rect, in canvas: SampleSize, permitsZero: Bool) -> Bool {
        guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.x >= 0, rect.y >= 0,
              permitsZero ? rect.width >= 0 && rect.height >= 0 : rect.width > 0 && rect.height > 0 else {
            return false
        }
        return rect.x + rect.width <= canvas.width && rect.y + rect.height <= canvas.height
    }

    fileprivate static func areReferences<Value>(_ ids: [String], in values: [String: Value]) -> Bool {
        Set(ids).count == ids.count && ids.allSatisfy { values[$0] != nil }
    }

    private static let legacySemanticBindings: [String: String] = [
        "petAction.blink": "curious",
        "petAction.lookAround": "curious",
        "petAction.stretch": "curious",
        "petAction.fallAsleep": "sleep",
        "petAction.wakeUp": "wake",
        "petAction.react": "happy",
        "transition.ready": "ready",
        "transition.curious": "curious",
        "transition.moveRight": "moveRight",
        "transition.moveLeft": "moveLeft",
        "transition.happy": "happy",
        "transition.sleep": "sleep"
    ]
}

public enum CharacterPackageError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    case noRoute(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message), let .noRoute(message): message
        }
    }
}
