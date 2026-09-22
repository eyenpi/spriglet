import Foundation
import Testing
@testable import SprigletCore

@Suite("Reactive behavior tuning")
struct ReactiveBehaviorPolicyTests {
    @Test("Character data creates bounded personality-modulated configuration")
    func decodesConfiguration() throws {
        let policy = try ReactiveBehaviorPolicy.decode(Data(validJSON.utf8))
        let quiet = try policy.configuration(for: PetTraits(curiosity: 0, playfulness: 0))
        let playful = try policy.configuration(for: PetTraits(curiosity: 1, playfulness: 1))
        #expect(policy.characterIdentifier == "acorn-hopper")
        #expect(abs(quiet.rapidReactionProbability - 0.05) < 0.000_001)
        #expect(abs(playful.rapidReactionProbability - 0.25) < 0.000_001)
        #expect(playful.candidates.count == 1)
        #expect(playful.candidates[0].intent.motionClass == .relocation)
    }

    @Test("Malformed, oversized, and unsupported tuning fails closed")
    func rejectsBadData() throws {
        #expect(throws: ReactiveBehaviorPolicyError.self) {
            try ReactiveBehaviorPolicy.decode(Data(repeating: 0x20, count: 65 * 1_024))
        }
        #expect(throws: ReactiveBehaviorPolicyError.self) {
            try ReactiveBehaviorPolicy.decode(Data(validJSON.replacingOccurrences(
                of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"
            ).utf8))
        }
        #expect(throws: ReactiveBehaviorPolicyError.self) {
            try ReactiveBehaviorPolicy.decode(Data(validJSON.replacingOccurrences(
                of: "\"minimumSafeExtent\": 40", with: "\"minimumSafeExtent\": -1"
            ).utf8))
        }
        #expect(throws: ReactiveBehaviorPolicyError.self) {
            try ReactiveBehaviorPolicy.decode(Data(validJSON.replacingOccurrences(
                of: "\"base\": 0.15", with: "\"base\": 2"
            ).utf8))
        }
    }

    private var validJSON: String {
        """
        {
          "schemaVersion": 1,
          "characterIdentifier": "acorn-hopper",
          "rapidApproachSpeed": 420,
          "maximumProjectedApproachDistance": 150,
          "departureSpeed": 36,
          "directInputLifetimeSeconds": 0.75,
          "utilityVariation": 0.04,
          "rapidReactionRarity": {
            "base": 0.15,
            "curiosityCenteredWeight": 0.08,
            "playfulnessCenteredWeight": 0.12
          },
          "reactionTokenCapacity": 1,
          "reactionTokenRefillSeconds": 30,
          "candidates": [{
            "intent": {
              "intentID": "dodge.left",
              "motionClass": "relocation",
              "horizontalDirection": -1,
              "minimumSafeExtent": 40
            },
            "fallback": null,
            "trigger": "rapidApproach",
            "priority": 3,
            "baseUtility": 0.9,
            "expirySeconds": 0.5,
            "cooldownKey": "dodge",
            "cooldownSeconds": 35,
            "reactionTokenCost": 1,
            "requiredCapabilityIDs": ["reactiveDodge"],
            "requiresAwake": true,
            "allowsLowPower": false,
            "usesRarityGate": true
          }]
        }
        """
    }
}
