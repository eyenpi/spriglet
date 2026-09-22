import Foundation

/// Pointer facts needed for a reaction decision. The relative vector is
/// ephemeral and value-only; the director never retains it or the raw point.
public struct PointerReactionFacts: Equatable, Sendable {
    public let perception: PointerPerception
    public let pointerRelativeToPet: PointerVector

    public init?(
        perception: PointerPerception,
        horizontalOffsetFromPet: Double,
        verticalOffsetFromPet: Double
    ) {
        guard horizontalOffsetFromPet.isFinite, verticalOffsetFromPet.isFinite,
              perception.distanceToTarget.map({ $0.isFinite && $0 >= 0 }) ?? true,
              perception.projectedDistanceToTarget.map({ $0.isFinite && $0 >= 0 }) ?? true,
              perception.approachSpeed.isFinite, perception.approachSpeed >= 0 else { return nil }
        self.perception = perception
        pointerRelativeToPet = PointerVector(
            dx: horizontalOffsetFromPet,
            dy: verticalOffsetFromPet
        )
    }
}

/// A graph route that is currently playable from the authored pose. Relocation
/// routes also carry the direction and usable extent proven by the host.
public struct ReactiveRouteAvailability: Equatable, Sendable {
    public struct Route: Equatable, Sendable {
        public let intentID: String
        public let motionClass: CharacterPackage.MotionClass
        public let horizontalDirection: Double?
        public let safeExtent: Double

        public init?(
            intentID: String,
            motionClass: CharacterPackage.MotionClass,
            horizontalDirection: Double? = nil,
            safeExtent: Double = 0
        ) {
            guard ReactiveBehaviorDirector.isIdentifier(intentID), safeExtent.isFinite, safeExtent >= 0,
                  horizontalDirection.map(Self.isNormalizedDirection) ?? true else { return nil }
            if motionClass == .relocation {
                guard horizontalDirection != nil, safeExtent > 0 else { return nil }
            } else if horizontalDirection != nil || safeExtent != 0 {
                return nil
            }
            self.intentID = intentID
            self.motionClass = motionClass
            self.horizontalDirection = horizontalDirection
            self.safeExtent = safeExtent
        }

        private static func isNormalizedDirection(_ value: Double) -> Bool {
            value.isFinite && abs(value) == 1
        }
    }

    public let routes: [String: Route]
    public let capabilityIDs: Set<String>

    public init?(routes: [Route], capabilityIDs: Set<String> = []) {
        guard routes.count <= 128,
              Set(routes.map(\.intentID)).count == routes.count,
              capabilityIDs.count <= 64,
              capabilityIDs.allSatisfy(ReactiveBehaviorDirector.isIdentifier) else { return nil }
        self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.intentID, $0) })
        self.capabilityIDs = capabilityIDs
    }
}

public struct ReactiveIntentRequirement: Equatable, Sendable {
    public let intentID: String
    public let motionClass: CharacterPackage.MotionClass
    public let horizontalDirection: Double?
    public let minimumSafeExtent: Double

    public init?(
        intentID: String,
        motionClass: CharacterPackage.MotionClass,
        horizontalDirection: Double? = nil,
        minimumSafeExtent: Double = 0
    ) {
        guard ReactiveBehaviorDirector.isIdentifier(intentID),
              minimumSafeExtent.isFinite, minimumSafeExtent >= 0,
              horizontalDirection.map({ $0.isFinite && abs($0) == 1 }) ?? true else { return nil }
        if motionClass == .relocation {
            guard horizontalDirection != nil, minimumSafeExtent > 0 else { return nil }
        } else if horizontalDirection != nil || minimumSafeExtent != 0 {
            return nil
        }
        self.intentID = intentID
        self.motionClass = motionClass
        self.horizontalDirection = horizontalDirection
        self.minimumSafeExtent = minimumSafeExtent
    }
}

/// One data-declared semantic desire. Clip names and pose topology remain in the
/// animation graph; this value only states when an intent is worth requesting.
public struct ReactiveBehaviorCandidate: Equatable, Sendable {
    public enum Trigger: String, Equatable, Sendable {
        case rapidApproach
        case pointerNear
        case pointerDwell
        case pointerDeparture
        case autonomous
    }

    public enum Priority: Int, Equatable, Comparable, Sendable {
        case autonomous = 1
        case contextual = 2
        case immediateReactive = 3
        case direct = 4

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let intent: ReactiveIntentRequirement
    public let fallback: ReactiveIntentRequirement?
    public let trigger: Trigger
    public let priority: Priority
    public let baseUtility: Double
    public let expiry: TimeInterval
    public let cooldownKey: String?
    public let cooldown: TimeInterval
    public let reactionTokenCost: Int
    public let requiredCapabilityIDs: Set<String>
    public let requiresAwake: Bool
    public let allowsLowPower: Bool
    public let usesRarityGate: Bool

    public var intentID: String { intent.intentID }

    public init?(
        intent: ReactiveIntentRequirement,
        fallback: ReactiveIntentRequirement? = nil,
        trigger: Trigger,
        priority: Priority,
        baseUtility: Double,
        expiry: TimeInterval,
        cooldownKey: String? = nil,
        cooldown: TimeInterval = 0,
        reactionTokenCost: Int = 0,
        requiredCapabilityIDs: Set<String> = [],
        requiresAwake: Bool = true,
        allowsLowPower: Bool = false,
        usesRarityGate: Bool = false
    ) {
        guard priority != .direct,
              baseUtility.isFinite, (0...1).contains(baseUtility),
              expiry.isFinite, expiry > 0, expiry <= 300,
              cooldown.isFinite, cooldown >= 0, cooldown <= 3_600,
              reactionTokenCost >= 0, reactionTokenCost <= 8,
              requiredCapabilityIDs.count <= 32,
              requiredCapabilityIDs.allSatisfy(ReactiveBehaviorDirector.isIdentifier),
              cooldownKey.map(ReactiveBehaviorDirector.isIdentifier) ?? true,
              (cooldown == 0) == (cooldownKey == nil),
              !usesRarityGate || trigger == .rapidApproach else { return nil }
        self.intent = intent
        self.fallback = fallback
        self.trigger = trigger
        self.priority = priority
        self.baseUtility = baseUtility
        self.expiry = expiry
        self.cooldownKey = cooldownKey
        self.cooldown = cooldown
        self.reactionTokenCost = reactionTokenCost
        self.requiredCapabilityIDs = requiredCapabilityIDs
        self.requiresAwake = requiresAwake
        self.allowsLowPower = allowsLowPower
        self.usesRarityGate = usesRarityGate
    }
}

public struct ReactiveBehaviorConfiguration: Equatable, Sendable {
    public let candidates: [ReactiveBehaviorCandidate]
    public let rapidApproachSpeed: Double
    public let maximumProjectedApproachDistance: Double
    public let departureSpeed: Double
    public let directInputLifetime: TimeInterval
    public let utilityVariation: Double
    public let rapidReactionProbability: Double
    public let reactionTokenCapacity: Int
    public let reactionTokenRefillInterval: TimeInterval

    public init?(
        candidates: [ReactiveBehaviorCandidate],
        rapidApproachSpeed: Double,
        maximumProjectedApproachDistance: Double,
        departureSpeed: Double,
        directInputLifetime: TimeInterval = 0.75,
        utilityVariation: Double = 0.05,
        rapidReactionProbability: Double = 0.35,
        reactionTokenCapacity: Int = 1,
        reactionTokenRefillInterval: TimeInterval = 30
    ) {
        guard (1...64).contains(candidates.count),
              Set(candidates.map { $0.intentID + "|" + $0.trigger.rawValue }).count == candidates.count,
              rapidApproachSpeed.isFinite, rapidApproachSpeed > 0,
              maximumProjectedApproachDistance.isFinite, maximumProjectedApproachDistance >= 0,
              departureSpeed.isFinite, departureSpeed > 0,
              directInputLifetime.isFinite, (0.05...10).contains(directInputLifetime),
              utilityVariation.isFinite, (0...0.25).contains(utilityVariation),
              rapidReactionProbability.isFinite, (0...1).contains(rapidReactionProbability),
              (0...8).contains(reactionTokenCapacity),
              reactionTokenRefillInterval.isFinite, reactionTokenRefillInterval > 0,
              candidates.allSatisfy({ $0.reactionTokenCost <= reactionTokenCapacity }) else { return nil }
        self.candidates = candidates
        self.rapidApproachSpeed = rapidApproachSpeed
        self.maximumProjectedApproachDistance = maximumProjectedApproachDistance
        self.departureSpeed = departureSpeed
        self.directInputLifetime = directInputLifetime
        self.utilityVariation = utilityVariation
        self.rapidReactionProbability = rapidReactionProbability
        self.reactionTokenCapacity = reactionTokenCapacity
        self.reactionTokenRefillInterval = reactionTokenRefillInterval
    }
}

/// A direct interaction request. Supplying one makes the direct-input tier the
/// sole tier considered for that arbitration pass.
public struct ReactiveDirectIntent: Equatable, Sendable {
    public let intentID: String
    public let occurredAt: MonotonicTimestamp

    public init?(intentID: String, occurredAt: MonotonicTimestamp) {
        guard ReactiveBehaviorDirector.isIdentifier(intentID) else { return nil }
        self.intentID = intentID
        self.occurredAt = occurredAt
    }
}

public struct ReactiveBehaviorDecision: Equatable, Sendable {
    public enum Cause: String, Equatable, Sendable {
        case directInput
        case rapidApproach
        case pointerNear
        case pointerDwell
        case pointerDeparture
        case autonomous
    }

    public let intentID: String
    public let priority: ReactiveBehaviorCandidate.Priority
    public let utility: Double
    public let cause: Cause
    public let sourceTimestamp: MonotonicTimestamp
    public let expiresAt: MonotonicTimestamp

    fileprivate let candidateIdentity: String
    fileprivate let cooldownKey: String?
    fileprivate let cooldown: TimeInterval
    fileprivate let reactionTokenCost: Int
}

/// Pure, event-driven semantic arbitration. It retains only bounded cooldown,
/// token and evaluated-event summaries; it owns no timer or platform object.
public struct ReactiveBehaviorDirector: Sendable {
    private let configuration: ReactiveBehaviorConfiguration
    private var availableReactionTokens: Int
    private var tokenRefillBase: MonotonicTimestamp?
    private var cooldownUntil: [String: MonotonicTimestamp] = [:]
    private var lastPerformedSource: [String: MonotonicTimestamp] = [:]
    private var lastPerformedDirectAt: MonotonicTimestamp?
    private var lastObservedAt: MonotonicTimestamp = .zero
    private var latestPointerTimestamp: MonotonicTimestamp?
    private var approachEpisode: ApproachEpisode?

    public init(configuration: ReactiveBehaviorConfiguration) {
        self.configuration = configuration
        availableReactionTokens = configuration.reactionTokenCapacity
    }

    public mutating func decide(
        in world: PetWorldSnapshot,
        pointer: PointerReactionFacts,
        availability: ReactiveRouteAvailability,
        directInput: ReactiveDirectIntent? = nil,
        entropy: UInt64
    ) -> ReactiveBehaviorDecision? {
        decide(
            in: world, at: world.timestamp, pointer: pointer,
            availability: availability, directInput: directInput, entropy: entropy
        )
    }

    /// Explicit-time form for pointer stimuli that arrive after the latest
    /// non-pointer world observation.
    public mutating func decide(
        in world: PetWorldSnapshot,
        at timestamp: MonotonicTimestamp,
        pointer: PointerReactionFacts,
        availability: ReactiveRouteAvailability,
        directInput: ReactiveDirectIntent? = nil,
        entropy: UInt64
    ) -> ReactiveBehaviorDecision? {
        guard timestamp >= world.timestamp, timestamp >= lastObservedAt else { return nil }
        lastObservedAt = timestamp
        replenishTokens(at: timestamp)
        discardElapsedCooldowns(at: timestamp)

        let reactionsSuppressed = world.isSuspended || !world.isOnActiveSpace
            || world.isInteracting || world.isAnimating || world.isMoving || directInput != nil
        observeApproachEpisode(
            pointer: pointer, now: timestamp, suppressed: reactionsSuppressed, entropy: entropy
        )
        guard !world.isSuspended, world.isOnActiveSpace else { return nil }
        if let directInput {
            return directDecision(
                directInput, now: timestamp, availability: availability
            )
        }
        guard !world.isInteracting, !world.isAnimating, !world.isMoving else { return nil }

        let eligible = configuration.candidates.compactMap { candidate -> RankedDecision? in
            guard let sourceTimestamp = sourceTimestamp(
                for: candidate.trigger, pointer: pointer, now: timestamp
            ),
            let expiresAt = MonotonicTimestamp(seconds: sourceTimestamp.seconds + candidate.expiry),
            sourceTimestamp <= timestamp, timestamp <= expiresAt,
            candidate.requiresAwake ? !world.isSleeping : true,
            candidate.allowsLowPower || !world.isLowPower,
            candidate.requiredCapabilityIDs.isSubset(of: availability.capabilityIDs),
            candidate.reactionTokenCost <= availableReactionTokens,
            candidate.cooldownKey.flatMap({ cooldownUntil[$0] }).map({ timestamp >= $0 }) ?? true,
            triggerMatches(candidate.trigger, pointer: pointer),
            !candidate.usesRarityGate || approachEpisode?.rarityPassed == true,
            lastPerformedSource[Self.identity(for: candidate)].map({ sourceTimestamp > $0 }) ?? true,
            let resolved = resolve(candidate: candidate, world: world, pointer: pointer,
                                   availability: availability) else { return nil }

            let utility = min(1, candidate.baseUtility
                + triggerStrength(candidate.trigger, pointer: pointer) * configuration.utilityVariation
                + stableUnit(entropy: entropy, identifier: resolved.intentID) * configuration.utilityVariation)
            return RankedDecision(
                decision: ReactiveBehaviorDecision(
                    intentID: resolved.intentID,
                    priority: candidate.priority,
                    utility: utility,
                    cause: Self.cause(for: candidate.trigger),
                    sourceTimestamp: sourceTimestamp,
                    expiresAt: expiresAt,
                    candidateIdentity: Self.identity(for: candidate),
                    cooldownKey: candidate.cooldownKey,
                    cooldown: candidate.cooldown,
                    reactionTokenCost: candidate.reactionTokenCost
                ),
                tieBreaker: stableWord(entropy: entropy, identifier: resolved.intentID)
            )
        }
        return eligible.max(by: Self.isLowerRank)?.decision
    }

    /// Prevents an already observed approach from surfacing after a direct
    /// interaction or another host-owned interruption ends. This intentionally
    /// retains the episode's start and rarity result: only a later, genuine
    /// departure or discontinuity rearms the behavior.
    public mutating func suppressCurrentApproach() {
        approachEpisode?.canSurface = false
    }

    /// Feedback is separate from selection. An unstarted or cancelled decision
    /// consumes neither cooldown nor reaction capacity. Report the actual start,
    /// while the decision remains live, rather than the eventual clip completion.
    public mutating func didPerform(
        _ decision: ReactiveBehaviorDecision,
        at timestamp: MonotonicTimestamp
    ) {
        let isDirect = decision.cause == .directInput
        let alreadyPerformed: Bool
        if isDirect {
            alreadyPerformed = lastPerformedDirectAt.map { decision.sourceTimestamp <= $0 } ?? false
        } else {
            alreadyPerformed = lastPerformedSource[decision.candidateIdentity].map {
                decision.sourceTimestamp <= $0
            } ?? false
        }
        guard !alreadyPerformed, timestamp >= lastObservedAt,
              timestamp >= decision.sourceTimestamp, timestamp <= decision.expiresAt else { return }
        lastObservedAt = timestamp
        replenishTokens(at: timestamp)
        if decision.cause == .rapidApproach,
           decision.sourceTimestamp == approachEpisode?.startedAt {
            approachEpisode?.canSurface = false
        }
        if isDirect {
            lastPerformedDirectAt = decision.sourceTimestamp
        } else {
            lastPerformedSource[decision.candidateIdentity] = decision.sourceTimestamp
        }
        if let key = decision.cooldownKey,
           let end = MonotonicTimestamp(seconds: timestamp.seconds + decision.cooldown) {
            cooldownUntil[key] = end
        }
        if decision.reactionTokenCost > 0,
           availableReactionTokens == configuration.reactionTokenCapacity {
            tokenRefillBase = timestamp
        }
        availableReactionTokens = max(0, availableReactionTokens - decision.reactionTokenCost)
    }

    /// Earliest cooldown or token-refill boundary. The caller owns the single
    /// cancellable timer and may also reevaluate on fresh stimuli.
    public mutating func nextDeadline(at timestamp: MonotonicTimestamp) -> MonotonicTimestamp? {
        guard timestamp >= lastObservedAt else { return nil }
        lastObservedAt = timestamp
        replenishTokens(at: timestamp)
        discardElapsedCooldowns(at: timestamp)
        var deadlines = cooldownUntil.values.filter { $0 > timestamp }
        if availableReactionTokens < configuration.reactionTokenCapacity,
           let tokenRefillBase,
           let next = MonotonicTimestamp(
            seconds: tokenRefillBase.seconds + configuration.reactionTokenRefillInterval
           ), next > timestamp {
            deadlines.append(next)
        }
        return deadlines.min()
    }

    public func reactionTokenCount() -> Int { availableReactionTokens }

    private mutating func directDecision(
        _ input: ReactiveDirectIntent,
        now: MonotonicTimestamp,
        availability: ReactiveRouteAvailability
    ) -> ReactiveBehaviorDecision? {
        guard input.occurredAt <= now,
              let expiry = MonotonicTimestamp(
                seconds: input.occurredAt.seconds + configuration.directInputLifetime
              ), now <= expiry,
              lastPerformedDirectAt.map({ input.occurredAt > $0 }) ?? true,
              let route = availability.routes[input.intentID],
              route.motionClass == .stationary || route.motionClass == .local else { return nil }
        return ReactiveBehaviorDecision(
            intentID: input.intentID,
            priority: .direct,
            utility: 1,
            cause: .directInput,
            sourceTimestamp: input.occurredAt,
            expiresAt: expiry,
            candidateIdentity: "direct." + input.intentID,
            cooldownKey: nil,
            cooldown: 0,
            reactionTokenCost: 0
        )
    }

    private func sourceTimestamp(
        for trigger: ReactiveBehaviorCandidate.Trigger,
        pointer: PointerReactionFacts,
        now: MonotonicTimestamp
    ) -> MonotonicTimestamp? {
        if trigger == .autonomous { return now }
        guard let sample = pointer.perception.latestSample?.timestamp,
              sample <= now, sample == latestPointerTimestamp else { return nil }
        if trigger == .rapidApproach {
            guard let episode = approachEpisode, episode.canSurface else { return nil }
            return episode.startedAt
        }
        return sample
    }

    private func triggerMatches(
        _ trigger: ReactiveBehaviorCandidate.Trigger,
        pointer: PointerReactionFacts
    ) -> Bool {
        let perception = pointer.perception
        guard !perception.didDiscontinue else { return trigger == .autonomous }
        switch trigger {
        case .rapidApproach:
            return !perception.isDwelling
                && perception.radialVelocity >= configuration.rapidApproachSpeed
                && perception.projectedDistanceToTarget.map {
                    $0 <= configuration.maximumProjectedApproachDistance
                } == true
        case .pointerNear:
            return perception.proximity == .near
        case .pointerDwell:
            return perception.isDwelling
        case .pointerDeparture:
            return perception.radialVelocity <= -configuration.departureSpeed
        case .autonomous:
            return true
        }
    }

    private func resolve(
        candidate: ReactiveBehaviorCandidate,
        world: PetWorldSnapshot,
        pointer: PointerReactionFacts,
        availability: ReactiveRouteAvailability
    ) -> ReactiveIntentRequirement? {
        for requirement in [candidate.intent, candidate.fallback].compactMap({ $0 }) {
            guard let route = availability.routes[requirement.intentID],
                  route.motionClass == requirement.motionClass,
                  policyAllows(route.motionClass, world: world),
                  geometryAllows(requirement, route: route),
                  pointsAwayWhenRequired(requirement, trigger: candidate.trigger, pointer: pointer) else { continue }
            return requirement
        }
        return nil
    }

    private func policyAllows(
        _ motion: CharacterPackage.MotionClass,
        world: PetWorldSnapshot
    ) -> Bool {
        if world.isReduceMotion, motion == .relocation || motion == .depth { return false }
        if world.isLowPower, motion == .relocation || motion == .depth { return false }
        return true
    }

    private func geometryAllows(
        _ requirement: ReactiveIntentRequirement,
        route: ReactiveRouteAvailability.Route
    ) -> Bool {
        guard requirement.motionClass == .relocation else { return true }
        guard let requiredDirection = requirement.horizontalDirection,
              let routeDirection = route.horizontalDirection else { return false }
        return requiredDirection * routeDirection > 0
            && route.safeExtent >= requirement.minimumSafeExtent
    }

    private func pointsAwayWhenRequired(
        _ requirement: ReactiveIntentRequirement,
        trigger: ReactiveBehaviorCandidate.Trigger,
        pointer: PointerReactionFacts
    ) -> Bool {
        guard trigger == .rapidApproach, let direction = requirement.horizontalDirection else { return true }
        let offset = pointer.pointerRelativeToPet.dx
        return offset == 0 || direction * offset < 0
    }

    private func triggerStrength(
        _ trigger: ReactiveBehaviorCandidate.Trigger,
        pointer: PointerReactionFacts
    ) -> Double {
        switch trigger {
        case .rapidApproach:
            return min(1, max(0, pointer.perception.radialVelocity / configuration.rapidApproachSpeed - 1))
        case .pointerDeparture:
            return min(1, max(0, -pointer.perception.radialVelocity / configuration.departureSpeed - 1))
        case .pointerNear, .pointerDwell:
            return 1
        case .autonomous:
            return 0
        }
    }

    /// Retain only episode/time summaries, never a coordinate history. The
    /// perception reducer already supplies hysteretic near/far classification.
    /// Slowing, dwelling, or briefly crossing the rapid-speed threshold does not
    /// rearm a rejected approach. A clear departure or discontinuity does.
    private mutating func observeApproachEpisode(
        pointer: PointerReactionFacts,
        now: MonotonicTimestamp,
        suppressed: Bool,
        entropy: UInt64
    ) {
        if suppressed { suppressCurrentApproach() }
        guard let sample = pointer.perception.latestSample?.timestamp else { return }
        guard sample <= now, latestPointerTimestamp.map({ sample >= $0 }) ?? true else { return }
        if pointer.perception.isDwelling { suppressCurrentApproach() }
        if latestPointerTimestamp.map({ sample > $0 }) ?? true {
            latestPointerTimestamp = sample
            let perception = pointer.perception
            let departed = perception.radialVelocity <= -configuration.departureSpeed
                || (perception.proximity == .far && perception.radialVelocity <= 0)
            if perception.didDiscontinue || departed {
                clearApproachEpisode()
                return
            }
            if approachEpisode == nil, triggerMatches(.rapidApproach, pointer: pointer) {
                approachEpisode = ApproachEpisode(
                    startedAt: sample,
                    canSurface: !suppressed,
                    rarityPassed: unit(entropy) < configuration.rapidReactionProbability
                )
            }
        }
    }

    private mutating func clearApproachEpisode() {
        approachEpisode = nil
    }

    private mutating func replenishTokens(at timestamp: MonotonicTimestamp) {
        guard configuration.reactionTokenCapacity > 0 else {
            availableReactionTokens = 0
            tokenRefillBase = timestamp
            return
        }
        guard let base = tokenRefillBase else {
            tokenRefillBase = timestamp
            return
        }
        guard timestamp >= base, availableReactionTokens < configuration.reactionTokenCapacity else { return }
        let elapsed = timestamp.seconds - base.seconds
        let missing = configuration.reactionTokenCapacity - availableReactionTokens
        let intervals = elapsed / configuration.reactionTokenRefillInterval
        let count = intervals >= Double(missing) ? missing : Int(intervals)
        guard count > 0 else { return }
        availableReactionTokens += count
        tokenRefillBase = if availableReactionTokens == configuration.reactionTokenCapacity {
            timestamp
        } else {
            MonotonicTimestamp(
                seconds: base.seconds + Double(count) * configuration.reactionTokenRefillInterval
            )
        }
    }

    private mutating func discardElapsedCooldowns(at timestamp: MonotonicTimestamp) {
        cooldownUntil = cooldownUntil.filter { $0.value > timestamp }
    }

    private struct RankedDecision {
        let decision: ReactiveBehaviorDecision
        let tieBreaker: UInt64
    }

    private struct ApproachEpisode: Sendable {
        let startedAt: MonotonicTimestamp
        var canSurface: Bool
        let rarityPassed: Bool
    }

    private static func isLowerRank(_ lhs: RankedDecision, _ rhs: RankedDecision) -> Bool {
        if lhs.decision.priority != rhs.decision.priority {
            return lhs.decision.priority < rhs.decision.priority
        }
        if lhs.decision.utility != rhs.decision.utility {
            return lhs.decision.utility < rhs.decision.utility
        }
        if lhs.tieBreaker != rhs.tieBreaker { return lhs.tieBreaker < rhs.tieBreaker }
        return lhs.decision.intentID > rhs.decision.intentID
    }

    private static func cause(
        for trigger: ReactiveBehaviorCandidate.Trigger
    ) -> ReactiveBehaviorDecision.Cause {
        switch trigger {
        case .rapidApproach: .rapidApproach
        case .pointerNear: .pointerNear
        case .pointerDwell: .pointerDwell
        case .pointerDeparture: .pointerDeparture
        case .autonomous: .autonomous
        }
    }

    private static func identity(for candidate: ReactiveBehaviorCandidate) -> String {
        candidate.intentID + "|" + candidate.trigger.rawValue
    }

    fileprivate static func isIdentifier(_ value: String) -> Bool {
        (1...80).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
    }

    private func stableWord(entropy: UInt64, identifier: String) -> UInt64 {
        var value = entropy ^ 0x9E37_79B9_7F4A_7C15
        for byte in identifier.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
            value ^= value >> 29
        }
        return value
    }

    private func stableUnit(entropy: UInt64, identifier: String) -> Double {
        unit(stableWord(entropy: entropy, identifier: identifier))
    }

    private func unit(_ value: UInt64) -> Double {
        Double(value >> 11) / 9_007_199_254_740_992
    }
}
