import Foundation

public struct CharacterPlaybackContext: Equatable, Sendable {
    public let capabilityIDs: Set<String>
    public let habitatID: String?
    public let orientationID: String?
    public let reduceMotion: Bool

    public init(
        capabilityIDs: Set<String> = [],
        habitatID: String? = nil,
        orientationID: String? = nil,
        reduceMotion: Bool = false
    ) {
        self.capabilityIDs = capabilityIDs
        self.habitatID = habitatID
        self.orientationID = orientationID
        self.reduceMotion = reduceMotion
    }
}

public struct CharacterAnimationPlan: Equatable, Sendable {
    public let requestedIntentID: String
    public let resolvedIntentID: String
    public let startPoseID: String
    public let endPoseID: String
    public let clipIDs: [String]

    public init(
        requestedIntentID: String,
        resolvedIntentID: String,
        startPoseID: String,
        endPoseID: String,
        clipIDs: [String]
    ) {
        self.requestedIntentID = requestedIntentID
        self.resolvedIntentID = resolvedIntentID
        self.startPoseID = startPoseID
        self.endPoseID = endPoseID
        self.clipIDs = clipIDs
    }
}

/// A bounded, event-resolved graph. It selects finite authored routes and owns
/// no clock, renderer, or platform state.
public struct CharacterAnimationGraph: Codable, Equatable, Sendable {
    public struct Intent: Codable, Equatable, Sendable {
        public let targetPoseID: String
        public let clipIDs: [String]
        public let replaysAtTarget: Bool
        public let fallbackIntentID: String?
        public let reducedMotionIntentID: String?

        public init(
            targetPoseID: String,
            clipIDs: [String] = [],
            replaysAtTarget: Bool = false,
            fallbackIntentID: String? = nil,
            reducedMotionIntentID: String? = nil
        ) {
            self.targetPoseID = targetPoseID
            self.clipIDs = clipIDs
            self.replaysAtTarget = replaysAtTarget
            self.fallbackIntentID = fallbackIntentID
            self.reducedMotionIntentID = reducedMotionIntentID
        }
    }

    /// A deliberate zero-frame pose handoff, used by compatibility adapters for
    /// legacy held states that have no authored bridge clip.
    public struct InstantTransition: Codable, Equatable, Sendable {
        public let fromPoseID: String
        public let toPoseID: String

        public init(fromPoseID: String, toPoseID: String) {
            self.fromPoseID = fromPoseID
            self.toPoseID = toPoseID
        }
    }

    public let defaultPoseID: String
    public let intents: [String: Intent]
    public let transitionClipIDs: [String]
    public let instantTransitions: [InstantTransition]

    public init(
        defaultPoseID: String,
        intents: [String: Intent],
        transitionClipIDs: [String] = [],
        instantTransitions: [InstantTransition] = []
    ) {
        self.defaultPoseID = defaultPoseID
        self.intents = intents
        self.transitionClipIDs = transitionClipIDs
        self.instantTransitions = instantTransitions
    }

    public func plan(
        for intentID: String,
        from poseID: String,
        clips: [String: CharacterPackage.Clip],
        context: CharacterPlaybackContext = CharacterPlaybackContext()
    ) throws -> CharacterAnimationPlan {
        guard intents[intentID] != nil else {
            throw CharacterPackageError.noRoute("Unknown character intent \(intentID).")
        }

        var candidateID = intentID
        var visited: Set<String> = []
        while visited.insert(candidateID).inserted, visited.count <= intents.count {
            guard let intent = intents[candidateID] else { break }
            if context.reduceMotion, let reducedID = intent.reducedMotionIntentID {
                guard !visited.contains(reducedID), intents[reducedID] != nil else {
                    throw CharacterPackageError.noRoute("Invalid reduced-motion intent route.")
                }
                candidateID = reducedID
                continue
            }

            if let clipIDs = route(for: intent, from: poseID, clips: clips, context: context) {
                return CharacterAnimationPlan(
                    requestedIntentID: intentID,
                    resolvedIntentID: candidateID,
                    startPoseID: poseID,
                    endPoseID: intent.targetPoseID,
                    clipIDs: clipIDs
                )
            }
            guard let fallbackID = intent.fallbackIntentID, !visited.contains(fallbackID) else { break }
            candidateID = fallbackID
        }
        throw CharacterPackageError.noRoute("No compatible route for character intent \(intentID).")
    }

    func validate(package: CharacterPackage) throws {
        guard package.poses[defaultPoseID] != nil,
              (1...64).contains(intents.count), transitionClipIDs.count <= 128,
              instantTransitions.count <= 128,
              CharacterPackage.isUniqueIdentifiers(transitionClipIDs) else {
            throw CharacterPackageError.invalid("Invalid animation graph inventory.")
        }
        for clipID in transitionClipIDs where package.clips[clipID] == nil {
            throw CharacterPackageError.invalid("Animation graph references missing transition clip \(clipID).")
        }
        for transition in instantTransitions {
            guard package.poses[transition.fromPoseID] != nil,
                  package.poses[transition.toPoseID] != nil,
                  transition.fromPoseID != transition.toPoseID else {
                throw CharacterPackageError.invalid("Invalid instant pose transition.")
            }
        }
        for (id, intent) in intents {
            guard CharacterPackage.isIdentifier(id), package.poses[intent.targetPoseID] != nil,
                  intent.clipIDs.count <= 16,
                  intent.clipIDs.allSatisfy({ package.clips[$0] != nil }),
                  intent.fallbackIntentID.map({ intents[$0] != nil }) ?? true,
                  intent.reducedMotionIntentID.map({ intents[$0] != nil }) ?? true else {
                throw CharacterPackageError.invalid("Invalid animation intent \(id).")
            }
            var pose: String?
            for clipID in intent.clipIDs {
                guard let clip = package.clips[clipID] else { continue }
                if let pose, pose != clip.startPoseID {
                    throw CharacterPackageError.invalid("Intent \(id) has a discontinuous clip sequence.")
                }
                pose = clip.endPoseID
            }
            if let pose, pose != intent.targetPoseID {
                throw CharacterPackageError.invalid("Intent \(id) does not finish at its target pose.")
            }
        }
        try validateIntentCycles()
        try validateTopology(package: package)
    }

    private func validateIntentCycles() throws {
        enum Mark { case visiting, complete }
        var marks: [String: Mark] = [:]

        func visit(_ id: String) throws {
            if marks[id] == .visiting {
                throw CharacterPackageError.invalid("Animation intent fallback cycle.")
            }
            if marks[id] == .complete { return }
            marks[id] = .visiting
            guard let intent = intents[id] else { return }
            if let next = intent.fallbackIntentID { try visit(next) }
            if let next = intent.reducedMotionIntentID { try visit(next) }
            marks[id] = .complete
        }

        for id in intents.keys { try visit(id) }
    }

    /// Every declared intent must be structurally reachable from every pose.
    /// Runtime capability and policy filtering may still select its fallback.
    private func validateTopology(package: CharacterPackage) throws {
        let unrestricted = CharacterPlaybackContext(
            capabilityIDs: Set(package.capabilities),
            habitatID: nil,
            orientationID: nil,
            reduceMotion: false
        )
        for poseID in package.poses.keys {
            for (intentID, intent) in intents {
                if route(for: intent, from: poseID, clips: package.clips,
                         context: unrestricted, ignoresRequirements: true) == nil,
                   intent.fallbackIntentID == nil {
                    throw CharacterPackageError.invalid(
                        "Intent \(intentID) is unreachable from pose \(poseID)."
                    )
                }
            }
        }
    }

    private func route(
        for intent: Intent,
        from startPoseID: String,
        clips: [String: CharacterPackage.Clip],
        context: CharacterPlaybackContext,
        ignoresRequirements: Bool = false
    ) -> [String]? {
        if startPoseID == intent.targetPoseID, !intent.replaysAtTarget {
            return []
        }

        var result: [String] = []
        var currentPoseID = startPoseID
        if let firstClipID = intent.clipIDs.first {
            guard let firstClip = clips[firstClipID],
                  let prefix = connectingRoute(
                    from: currentPoseID,
                    to: firstClip.startPoseID,
                    clips: clips,
                    context: context,
                    ignoresRequirements: ignoresRequirements
                  ) else { return nil }
            result += prefix
            currentPoseID = firstClip.startPoseID
        }

        for clipID in intent.clipIDs {
            guard let clip = clips[clipID], clip.startPoseID == currentPoseID,
                  isCompatible(clip, with: context, ignoresRequirements: ignoresRequirements) else {
                return nil
            }
            result.append(clipID)
            currentPoseID = clip.endPoseID
        }

        guard let suffix = connectingRoute(
            from: currentPoseID,
            to: intent.targetPoseID,
            clips: clips,
            context: context,
            ignoresRequirements: ignoresRequirements
        ) else { return nil }
        result += suffix
        return result.count <= 32 ? result : nil
    }

    private func connectingRoute(
        from startPoseID: String,
        to targetPoseID: String,
        clips: [String: CharacterPackage.Clip],
        context: CharacterPlaybackContext,
        ignoresRequirements: Bool
    ) -> [String]? {
        guard startPoseID != targetPoseID else { return [] }
        struct Step {
            let previousPoseID: String
            let clipID: String?
        }

        var queue = [startPoseID]
        var index = 0
        var predecessor: [String: Step] = [:]
        var discovered: Set<String> = [startPoseID]

        while index < queue.count, discovered.count <= 64 {
            let poseID = queue[index]
            index += 1
            var edges: [(String, String?)] = []
            for clipID in transitionClipIDs {
                guard let clip = clips[clipID], clip.startPoseID == poseID,
                      isCompatible(clip, with: context, ignoresRequirements: ignoresRequirements) else { continue }
                edges.append((clip.endPoseID, clipID))
            }
            for transition in instantTransitions where transition.fromPoseID == poseID {
                edges.append((transition.toPoseID, nil))
            }
            for (nextPoseID, clipID) in edges where discovered.insert(nextPoseID).inserted {
                predecessor[nextPoseID] = Step(previousPoseID: poseID, clipID: clipID)
                if nextPoseID == targetPoseID {
                    var reversed: [String] = []
                    var cursor = targetPoseID
                    while cursor != startPoseID {
                        guard let step = predecessor[cursor] else { return nil }
                        if let clipID = step.clipID { reversed.append(clipID) }
                        cursor = step.previousPoseID
                    }
                    return reversed.reversed()
                }
                queue.append(nextPoseID)
            }
        }
        return nil
    }

    private func isCompatible(
        _ clip: CharacterPackage.Clip,
        with context: CharacterPlaybackContext,
        ignoresRequirements: Bool
    ) -> Bool {
        if context.reduceMotion, !clip.motionClass.allowedWithReduceMotion { return false }
        return ignoresRequirements || clip.requirements.isSatisfied(by: context)
    }
}
