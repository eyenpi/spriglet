import Foundation

public enum ReactiveBehaviorPolicyError: Error, Equatable, LocalizedError {
    case tooLarge
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge:
            "Reactive behavior tuning exceeds its 64 KiB limit."
        case .invalid(let detail):
            "Invalid reactive behavior tuning: \(detail)"
        }
    }
}

/// Versioned character-authored behavior tuning. This file describes semantic
/// desires and thresholds; the animation graph remains the authority for how a
/// character reaches each intent.
public struct ReactiveBehaviorPolicy: Codable, Equatable, Sendable {
    public struct PersonalityRarity: Codable, Equatable, Sendable {
        public let base: Double
        public let curiosityCenteredWeight: Double
        public let playfulnessCenteredWeight: Double

        public func probability(for traits: PetTraits) -> Double {
            min(1, max(0, base
                + curiosityCenteredWeight * (traits.curiosity - 0.5)
                + playfulnessCenteredWeight * (traits.playfulness - 0.5)))
        }

        fileprivate var isValid: Bool {
            base.isFinite && (0...1).contains(base)
                && curiosityCenteredWeight.isFinite && (-1...1).contains(curiosityCenteredWeight)
                && playfulnessCenteredWeight.isFinite && (-1...1).contains(playfulnessCenteredWeight)
        }
    }

    public struct Requirement: Codable, Equatable, Sendable {
        public let intentID: String
        public let motionClass: CharacterPackage.MotionClass
        public let horizontalDirection: Double?
        public let minimumSafeExtent: Double

        fileprivate func coreValue() -> ReactiveIntentRequirement? {
            ReactiveIntentRequirement(
                intentID: intentID,
                motionClass: motionClass,
                horizontalDirection: horizontalDirection,
                minimumSafeExtent: minimumSafeExtent
            )
        }
    }

    public struct Candidate: Codable, Equatable, Sendable {
        public let intent: Requirement
        public let fallback: Requirement?
        public let trigger: ReactiveBehaviorCandidate.Trigger
        public let priority: ReactiveBehaviorCandidate.Priority
        public let baseUtility: Double
        public let expirySeconds: TimeInterval
        public let cooldownKey: String?
        public let cooldownSeconds: TimeInterval
        public let reactionTokenCost: Int
        public let requiredCapabilityIDs: Set<String>
        public let requiresAwake: Bool
        public let allowsLowPower: Bool
        public let usesRarityGate: Bool

        fileprivate func coreValue() -> ReactiveBehaviorCandidate? {
            guard let intent = intent.coreValue(),
                  let fallback = fallback.map({ $0.coreValue() }) ?? .some(nil) else { return nil }
            return ReactiveBehaviorCandidate(
                intent: intent,
                fallback: fallback,
                trigger: trigger,
                priority: priority,
                baseUtility: baseUtility,
                expiry: expirySeconds,
                cooldownKey: cooldownKey,
                cooldown: cooldownSeconds,
                reactionTokenCost: reactionTokenCost,
                requiredCapabilityIDs: requiredCapabilityIDs,
                requiresAwake: requiresAwake,
                allowsLowPower: allowsLowPower,
                usesRarityGate: usesRarityGate
            )
        }
    }

    public let schemaVersion: Int
    public let characterIdentifier: String
    public let rapidApproachSpeed: Double
    public let maximumProjectedApproachDistance: Double
    public let departureSpeed: Double
    public let directInputLifetimeSeconds: TimeInterval
    public let utilityVariation: Double
    public let rapidReactionRarity: PersonalityRarity
    public let reactionTokenCapacity: Int
    public let reactionTokenRefillSeconds: TimeInterval
    public let candidates: [Candidate]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1_024 else { throw ReactiveBehaviorPolicyError.tooLarge }
        let value: Self
        do {
            value = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ReactiveBehaviorPolicyError.invalid(error.localizedDescription)
        }
        try value.validate()
        return value
    }

    public func configuration(for traits: PetTraits) throws -> ReactiveBehaviorConfiguration {
        let values = candidates.compactMap { $0.coreValue() }
        guard values.count == candidates.count,
              let result = ReactiveBehaviorConfiguration(
                candidates: values,
                rapidApproachSpeed: rapidApproachSpeed,
                maximumProjectedApproachDistance: maximumProjectedApproachDistance,
                departureSpeed: departureSpeed,
                directInputLifetime: directInputLifetimeSeconds,
                utilityVariation: utilityVariation,
                rapidReactionProbability: rapidReactionRarity.probability(for: traits),
                reactionTokenCapacity: reactionTokenCapacity,
                reactionTokenRefillInterval: reactionTokenRefillSeconds
              ) else {
            throw ReactiveBehaviorPolicyError.invalid("candidate or budget values are outside supported bounds")
        }
        return result
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw ReactiveBehaviorPolicyError.invalid("unsupported schema version")
        }
        guard Self.isIdentifier(characterIdentifier) else {
            throw ReactiveBehaviorPolicyError.invalid("invalid character identifier")
        }
        guard rapidReactionRarity.isValid else {
            throw ReactiveBehaviorPolicyError.invalid("invalid personality rarity weights")
        }
        _ = try configuration(for: .sprout)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

extension ReactiveBehaviorCandidate.Trigger: Codable {}
extension ReactiveBehaviorCandidate.Priority: Codable {}
