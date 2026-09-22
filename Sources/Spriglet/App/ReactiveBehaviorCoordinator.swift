import Foundation
import SprigletCore

/// Application composition for the pure reaction arbiter. It derives playable
/// routes from the current graph and host geometry only when a semantic pointer
/// update arrives; it owns no sensor, timer, display link, or coordinate log.
@MainActor
final class ReactiveBehaviorCoordinator {
    private var director: ReactiveBehaviorDirector
    private let configuration: ReactiveBehaviorConfiguration
    private let capabilityIDs: Set<String>
    private let previewIntent: @MainActor (String) -> CharacterTimeline?
    private let canFitRootMotion: @MainActor ([SamplePoint]) -> Bool
    private let performIntent: @MainActor (String) -> Bool
    private let entropy: @MainActor () -> UInt64

    init(
        policy: ReactiveBehaviorPolicy,
        characterIdentifier: String,
        traits: PetTraits,
        capabilityIDs: Set<String>,
        previewIntent: @escaping @MainActor (String) -> CharacterTimeline?,
        canFitRootMotion: @escaping @MainActor ([SamplePoint]) -> Bool,
        performIntent: @escaping @MainActor (String) -> Bool,
        entropy: @escaping @MainActor () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) throws {
        guard policy.characterIdentifier == characterIdentifier else {
            throw ReactiveBehaviorPolicyError.invalid("character identifier mismatch")
        }
        let configuration = try policy.configuration(for: traits)
        self.configuration = configuration
        director = ReactiveBehaviorDirector(configuration: configuration)
        self.capabilityIDs = capabilityIDs
        self.previewIntent = previewIntent
        self.canFitRootMotion = canFitRootMotion
        self.performIntent = performIntent
        self.entropy = entropy
    }

    /// Evaluates only the newest ephemeral sample. Nothing in this type retains
    /// a raw desktop position beyond the world snapshot that already owns it.
    @discardableResult
    func receive(world: PetWorldSnapshot) -> ReactiveBehaviorDecision? {
        guard let sample = world.pointer.latestSample, let bounds = world.petBounds,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              let facts = PointerReactionFacts(
                perception: world.pointer,
                horizontalOffsetFromPet: sample.location.x - bounds.midX,
                verticalOffsetFromPet: sample.location.y - bounds.midY
              ),
              let availability = routeAvailability(),
              let decision = director.decide(
                in: world, pointer: facts, availability: availability, entropy: entropy()
              ),
              performIntent(decision.intentID) else { return nil }
        director.didPerform(decision, at: world.timestamp)
        return decision
    }

    /// A press, drag, accessibility action, or competing authored animation
    /// consumes the current approach without spending a reaction token.
    func suppressCurrentApproach() {
        director.suppressCurrentApproach()
    }

    private func routeAvailability() -> ReactiveRouteAvailability? {
        var requirements: [String: ReactiveIntentRequirement] = [:]
        for candidate in configuration.candidates {
            requirements[candidate.intent.intentID] = candidate.intent
            if let fallback = candidate.fallback { requirements[fallback.intentID] = fallback }
        }
        let routes = requirements.values.compactMap { requirement -> ReactiveRouteAvailability.Route? in
            guard let timeline = previewIntent(requirement.intentID) else { return nil }
            switch requirement.motionClass {
            case .relocation:
                guard let direction = requirement.horizontalDirection,
                      routeMoves(timeline.rootOffsets, in: direction),
                      canFitRootMotion(timeline.rootOffsets) else { return nil }
                // `canFitRootMotion` validates every authored offset against the
                // current visible frame, so the declared minimum is proven safe.
                return ReactiveRouteAvailability.Route(
                    intentID: requirement.intentID,
                    motionClass: .relocation,
                    horizontalDirection: direction,
                    safeExtent: requirement.minimumSafeExtent
                )
            case .stationary, .local:
                guard timeline.rootOffsets.allSatisfy({
                    abs($0.x) < 0.001 && abs($0.y) < 0.001
                }) else { return nil }
                return ReactiveRouteAvailability.Route(
                    intentID: requirement.intentID,
                    motionClass: requirement.motionClass
                )
            case .depth:
                return nil
            }
        }
        return ReactiveRouteAvailability(routes: routes, capabilityIDs: capabilityIDs)
    }

    private func routeMoves(_ offsets: [SamplePoint], in direction: Double) -> Bool {
        guard let final = offsets.last, direction != 0,
              direction * final.x >= 1 else { return false }
        return offsets.allSatisfy { direction * $0.x >= -0.001 }
    }
}
