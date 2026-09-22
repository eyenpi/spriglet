import Foundation
import SprigletCore
import Testing

@Suite("Priority and utility reactive behavior arbitration")
struct ReactiveBehaviorDirectorTests {
    private func time(_ seconds: Double) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: seconds)!
    }

    private func world(
        _ seconds: Double,
        sleeping: Bool = false,
        lowPower: Bool = false,
        reduceMotion: Bool = false,
        activeSpace: Bool = true,
        interacting: Bool = false,
        animating: Bool = false,
        moving: Bool = false,
        suspended: Bool = false
    ) -> PetWorldSnapshot {
        var policy = ActivityPolicy()
        if suspended { policy.set(.hidden, active: true) }
        return PetWorldSnapshot(
            timestamp: time(seconds), activityPolicy: policy,
            isSleeping: sleeping, isLowPower: lowPower,
            isReduceMotion: reduceMotion, isOnActiveSpace: activeSpace,
            isInteracting: interacting, isAnimating: animating, isMoving: moving
        )
    }

    private func pointer(
        sampleTime: Double,
        relativeX: Double = -40,
        radialVelocity: Double = 500,
        projectedDistance: Double = 30,
        proximity: PointerProximity = .near,
        dwelling: Bool = false,
        discontinued: Bool = false
    ) -> PointerReactionFacts {
        let perception = PointerPerception(
            latestSample: PointerSample(
                timestamp: time(sampleTime),
                location: PointerPoint(x: relativeX, y: 20)!
            ),
            velocity: PointerVector(dx: 300, dy: -400),
            distanceToTarget: 50,
            radialVelocity: radialVelocity,
            approachSpeed: max(0, radialVelocity),
            projectedDistanceToTarget: projectedDistance,
            proximity: proximity,
            dwellStartedAt: dwelling ? time(max(0, sampleTime - 1)) : nil,
            isDwelling: dwelling,
            didDiscontinue: discontinued
        )
        return PointerReactionFacts(
            perception: perception,
            horizontalOffsetFromPet: relativeX,
            verticalOffsetFromPet: 20
        )!
    }

    private func requirement(
        _ id: String,
        motion: CharacterPackage.MotionClass = .local,
        direction: Double? = nil,
        extent: Double = 0
    ) -> ReactiveIntentRequirement {
        ReactiveIntentRequirement(
            intentID: id, motionClass: motion,
            horizontalDirection: direction, minimumSafeExtent: extent
        )!
    }

    private func candidate(
        _ id: String,
        trigger: ReactiveBehaviorCandidate.Trigger = .rapidApproach,
        priority: ReactiveBehaviorCandidate.Priority = .immediateReactive,
        utility: Double = 0.8,
        expiry: Double = 1,
        motion: CharacterPackage.MotionClass = .local,
        direction: Double? = nil,
        extent: Double = 0,
        fallback: ReactiveIntentRequirement? = nil,
        cooldown: Double = 0,
        tokenCost: Int = 0,
        allowsLowPower: Bool = false,
        rarity: Bool = false
    ) -> ReactiveBehaviorCandidate {
        ReactiveBehaviorCandidate(
            intent: requirement(id, motion: motion, direction: direction, extent: extent),
            fallback: fallback,
            trigger: trigger,
            priority: priority,
            baseUtility: utility,
            expiry: expiry,
            cooldownKey: cooldown > 0 ? id + ".cooldown" : nil,
            cooldown: cooldown,
            reactionTokenCost: tokenCost,
            allowsLowPower: allowsLowPower,
            usesRarityGate: rarity
        )!
    }

    private func configuration(
        _ candidates: [ReactiveBehaviorCandidate],
        probability: Double = 1,
        capacity: Int = 1,
        refill: Double = 10,
        variation: Double = 0
    ) -> ReactiveBehaviorConfiguration {
        ReactiveBehaviorConfiguration(
            candidates: candidates,
            rapidApproachSpeed: 200,
            maximumProjectedApproachDistance: 80,
            departureSpeed: 100,
            utilityVariation: variation,
            rapidReactionProbability: probability,
            reactionTokenCapacity: capacity,
            reactionTokenRefillInterval: refill
        )!
    }

    private func route(
        _ id: String,
        motion: CharacterPackage.MotionClass = .local,
        direction: Double? = nil,
        extent: Double = 0
    ) -> ReactiveRouteAvailability.Route {
        ReactiveRouteAvailability.Route(
            intentID: id, motionClass: motion,
            horizontalDirection: direction, safeExtent: extent
        )!
    }

    private func availability(
        _ routes: [ReactiveRouteAvailability.Route],
        capabilities: Set<String> = []
    ) -> ReactiveRouteAvailability {
        ReactiveRouteAvailability(routes: routes, capabilityIDs: capabilities)!
    }

    @Test("Direct input is the sole highest-priority tier")
    func directInputPrecedence() throws {
        let dodge = candidate(
            "reactive.dodge.right", motion: .relocation, direction: 1, extent: 30
        )
        var director = ReactiveBehaviorDirector(configuration: configuration([dodge]))
        let routes = availability([
            route("direct.happy"),
            route("reactive.dodge.right", motion: .relocation, direction: 1, extent: 50)
        ])
        let direct = try #require(ReactiveDirectIntent(intentID: "direct.happy", occurredAt: time(1)))
        let decision = director.decide(
            in: world(1, interacting: true), pointer: pointer(sampleTime: 1),
            availability: routes, directInput: direct, entropy: 0
        )
        #expect(decision?.intentID == "direct.happy")
        #expect(decision?.priority == .direct)

        let unsafeDirect = try #require(ReactiveDirectIntent(
            intentID: "reactive.dodge.right", occurredAt: time(1.1)
        ))
        #expect(director.decide(
            in: world(1.1, interacting: true), pointer: pointer(sampleTime: 1.1),
            availability: routes, directInput: unsafeDirect, entropy: 0
        ) == nil)
    }

    @Test("Intent names cannot masquerade as direct-input feedback")
    func directLikeIntentNameRemainsContextual() throws {
        let contextual = candidate(
            "direct.alert", trigger: .pointerNear,
            priority: .contextual, expiry: 2
        )
        var director = ReactiveBehaviorDirector(configuration: configuration([contextual]))
        let routes = availability([route("direct.alert")])
        let facts = pointer(sampleTime: 1, radialVelocity: 0)
        let proposal = director.decide(
            in: world(1), pointer: facts,
            availability: routes, entropy: 0
        )
        let performed = try #require(proposal)
        #expect(performed.cause == .pointerNear)
        director.didPerform(performed, at: time(1))
        #expect(director.decide(
            in: world(1), pointer: facts,
            availability: routes, entropy: 0
        ) == nil)
    }

    @Test("A rapid approach chooses only a safe route away from the pointer")
    func directionalSafety() {
        let left = candidate(
            "reactive.dodge.left", motion: .relocation, direction: -1, extent: 30,
            fallback: requirement("reactive.alert")
        )
        let right = candidate(
            "reactive.dodge.right", motion: .relocation, direction: 1, extent: 30,
            fallback: requirement("reactive.alert")
        )
        let allRoutes = availability([
            route("reactive.dodge.left", motion: .relocation, direction: -1, extent: 60),
            route("reactive.dodge.right", motion: .relocation, direction: 1, extent: 60),
            route("reactive.alert")
        ])
        var director = ReactiveBehaviorDirector(configuration: configuration([left, right]))
        let away = director.decide(
            in: world(1), pointer: pointer(sampleTime: 1, relativeX: -50),
            availability: allRoutes, entropy: .max
        )
        #expect(away?.intentID == "reactive.dodge.right")

        let shortRoutes = availability([
            route("reactive.dodge.left", motion: .relocation, direction: -1, extent: 60),
            route("reactive.dodge.right", motion: .relocation, direction: 1, extent: 10),
            route("reactive.alert")
        ])
        var fallbackDirector = ReactiveBehaviorDirector(configuration: configuration([left, right]))
        let fallback = fallbackDirector.decide(
            in: world(1), pointer: pointer(sampleTime: 1, relativeX: -50),
            availability: shortRoutes, entropy: 0
        )
        #expect(fallback?.intentID == "reactive.alert")
    }

    @Test("Pointer expiry is anchored to the delivered sample")
    func expiryDoesNotRefresh() {
        let gaze = candidate(
            "context.gaze", trigger: .pointerNear, priority: .contextual,
            expiry: 0.5
        )
        var director = ReactiveBehaviorDirector(configuration: configuration([gaze]))
        let routes = availability([route("context.gaze")])
        let facts = pointer(sampleTime: 1, radialVelocity: 0)
        #expect(director.decide(
            in: world(1.4), pointer: facts, availability: routes, entropy: 0
        )?.intentID == "context.gaze")
        #expect(director.decide(
            in: world(1.500_001), pointer: facts, availability: routes, entropy: .max
        ) == nil)
    }

    @Test("Rarity is sampled once per approach episode and rearms only after departure")
    func rarityGateIsEpisodeBound() {
        let dodge = candidate("reactive.alert", expiry: 2, rarity: true)
        var director = ReactiveBehaviorDirector(configuration: configuration(
            [dodge], probability: 0.5
        ))
        let routes = availability([route("reactive.alert")])
        let firstEvent = pointer(sampleTime: 1)
        #expect(director.decide(
            in: world(1), pointer: firstEvent, availability: routes, entropy: .max
        ) == nil)
        #expect(director.decide(
            in: world(1.2), pointer: firstEvent, availability: routes, entropy: 0
        ) == nil)
        #expect(director.decide(
            in: world(1.3), pointer: pointer(sampleTime: 1.3),
            availability: routes, entropy: 0
        ) == nil)
        #expect(director.decide(
            in: world(1.4), pointer: pointer(
                sampleTime: 1.4, radialVelocity: 0, proximity: .near
            ), availability: routes, entropy: 0
        ) == nil)

        // A real departure closes the rejected episode. The next approach gets
        // exactly one fresh gate result.
        #expect(director.decide(
            in: world(1.5), pointer: pointer(
                sampleTime: 1.5, radialVelocity: -200, proximity: .far
            ), availability: routes, entropy: 0
        ) == nil)
        #expect(director.decide(
            in: world(1.6), pointer: pointer(sampleTime: 1.6),
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
    }

    @Test("An approach keeps its original expiry across newer samples")
    func approachExpiryDoesNotRefresh() {
        let dodge = candidate("reactive.alert", expiry: 0.5, rarity: true)
        var director = ReactiveBehaviorDirector(configuration: configuration(
            [dodge], probability: 1
        ))
        let unavailable = availability([])
        let routes = availability([route("reactive.alert")])

        #expect(director.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: unavailable, entropy: 0
        ) == nil)
        #expect(director.decide(
            in: world(1.4), pointer: pointer(sampleTime: 1.4),
            availability: routes, entropy: .max
        )?.sourceTimestamp == time(1))
        #expect(director.decide(
            in: world(1.500_001), pointer: pointer(sampleTime: 1.500_001),
            availability: routes, entropy: .max
        ) == nil)
    }

    @Test("Busy and direct suppression cannot resurface an active approach")
    func approachSuppressionIsLatched() throws {
        let dodge = candidate("reactive.alert", expiry: 10, rarity: true)
        let config = configuration([dodge], probability: 1)
        let routes = availability([route("reactive.alert"), route("direct.happy")])

        var busy = ReactiveBehaviorDirector(configuration: config)
        #expect(busy.decide(
            in: world(1, animating: true), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 0
        ) == nil)
        #expect(busy.decide(
            in: world(1.1), pointer: pointer(sampleTime: 1.1),
            availability: routes, entropy: 0
        ) == nil)

        var explicit = ReactiveBehaviorDirector(configuration: config)
        #expect(explicit.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
        explicit.suppressCurrentApproach()
        let noCoordinate = PointerReactionFacts(
            perception: .empty,
            horizontalOffsetFromPet: 0,
            verticalOffsetFromPet: 0
        )!
        #expect(explicit.decide(
            in: world(1.05), pointer: noCoordinate,
            availability: routes, entropy: 0
        ) == nil)
        #expect(explicit.decide(
            in: world(1.1), pointer: pointer(sampleTime: 1.1),
            availability: routes, entropy: 0
        ) == nil)

        // Even an invalid direct request is the sole tier for its pass and
        // suppresses the prior episode before stale pointer input is rejected.
        let direct = try #require(ReactiveDirectIntent(
            intentID: "missing.direct", occurredAt: time(1.2)
        ))
        #expect(explicit.decide(
            in: world(1.2), pointer: pointer(sampleTime: 0.9),
            availability: routes, directInput: direct, entropy: 0
        ) == nil)
        #expect(explicit.decide(
            in: world(1.3), pointer: pointer(sampleTime: 1.3),
            availability: routes, entropy: 0
        ) == nil)

        #expect(explicit.decide(
            in: world(1.4), pointer: pointer(
                sampleTime: 1.4, radialVelocity: -200, proximity: .far
            ), availability: routes, entropy: 0
        ) == nil)
        #expect(explicit.decide(
            in: world(1.5), pointer: pointer(sampleTime: 1.5),
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")

        var intentional = ReactiveBehaviorDirector(configuration: config)
        #expect(intentional.decide(
            in: world(2), pointer: pointer(sampleTime: 2),
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
        #expect(intentional.decide(
            in: world(2.1), pointer: pointer(sampleTime: 2.1, dwelling: true),
            availability: routes, entropy: 0
        ) == nil)
        #expect(intentional.decide(
            in: world(2.2), pointer: pointer(sampleTime: 2.2),
            availability: routes, entropy: 0
        ) == nil)
    }

    @Test("Cooldowns and reaction tokens are consumed only by execution")
    func feedbackBudgets() throws {
        let dodge = candidate(
            "reactive.alert", expiry: 100, cooldown: 5, tokenCost: 1
        )
        var director = ReactiveBehaviorDirector(configuration: configuration(
            [dodge], capacity: 1, refill: 10
        ))
        let routes = availability([route("reactive.alert")])
        let proposed = director.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 0
        )
        let first = try #require(proposed)
        #expect(director.reactionTokenCount() == 1)
        #expect(director.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 0
        ) == first)

        director.didPerform(first, at: time(1))
        #expect(director.reactionTokenCount() == 0)
        director.didPerform(first, at: time(1))
        #expect(director.reactionTokenCount() == 0)
        #expect(director.decide(
            in: world(2), pointer: pointer(sampleTime: 2),
            availability: routes, entropy: 0
        ) == nil)
        #expect(director.nextDeadline(at: time(2)) == time(6))
        #expect(director.nextDeadline(at: time(6)) == time(11))
        #expect(director.decide(
            in: world(10.9), pointer: pointer(
                sampleTime: 10.9, radialVelocity: -200, proximity: .far
            ), availability: routes, entropy: 0
        ) == nil)
        #expect(director.decide(
            in: world(11), pointer: pointer(sampleTime: 11),
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
    }

    @Test("Reduce Motion and Low Power apply semantic motion policy")
    func motionPolicy() {
        let dodge = candidate(
            "reactive.dodge.right", utility: 1,
            motion: .relocation, direction: 1, extent: 20,
            allowsLowPower: true
        )
        let alert = candidate(
            "reactive.alert", priority: .contextual, utility: 0.1,
            allowsLowPower: true
        )
        let routes = availability([
            route("reactive.dodge.right", motion: .relocation, direction: 1, extent: 40),
            route("reactive.alert")
        ])
        let facts = pointer(sampleTime: 1, relativeX: -20)

        var normal = ReactiveBehaviorDirector(configuration: configuration([dodge, alert]))
        #expect(normal.decide(
            in: world(1), pointer: facts, availability: routes, entropy: 0
        )?.intentID == "reactive.dodge.right")
        var reduced = ReactiveBehaviorDirector(configuration: configuration([dodge, alert]))
        #expect(reduced.decide(
            in: world(1, reduceMotion: true), pointer: facts,
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
        var lowPower = ReactiveBehaviorDirector(configuration: configuration([dodge, alert]))
        #expect(lowPower.decide(
            in: world(1, lowPower: true), pointer: facts,
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
    }

    @Test("Safety, busy state and intentional dwell suppress reactions")
    func blockers() throws {
        let dodge = candidate("reactive.alert")
        let config = configuration([dodge])
        let routes = availability([route("reactive.alert"), route("direct.happy")])
        for blockedWorld in [
            world(1, activeSpace: false), world(1, interacting: true),
            world(1, animating: true), world(1, moving: true), world(1, suspended: true)
        ] {
            var director = ReactiveBehaviorDirector(configuration: config)
            #expect(director.decide(
                in: blockedWorld, pointer: pointer(sampleTime: 1),
                availability: routes, entropy: 0
            ) == nil)
        }
        var dwelling = ReactiveBehaviorDirector(configuration: config)
        #expect(dwelling.decide(
            in: world(1), pointer: pointer(sampleTime: 1, dwelling: true),
            availability: routes, entropy: 0
        ) == nil)

        var suspended = ReactiveBehaviorDirector(configuration: config)
        let direct = try #require(ReactiveDirectIntent(intentID: "direct.happy", occurredAt: time(1)))
        #expect(suspended.decide(
            in: world(1, interacting: true, suspended: true),
            pointer: pointer(sampleTime: 1), availability: routes,
            directInput: direct, entropy: 0
        ) == nil)
    }

    @Test("Malformed directions, budgets, identifiers and stale clocks fail closed")
    func malformedAndStaleInput() {
        #expect(ReactiveIntentRequirement(
            intentID: "../escape", motionClass: .local
        ) == nil)
        #expect(ReactiveIntentRequirement(
            intentID: "move", motionClass: .relocation,
            horizontalDirection: 0, minimumSafeExtent: 20
        ) == nil)
        #expect(ReactiveIntentRequirement(
            intentID: "move", motionClass: .relocation,
            horizontalDirection: 0.5, minimumSafeExtent: 20
        ) == nil)
        #expect(ReactiveRouteAvailability.Route(
            intentID: "move", motionClass: .relocation,
            horizontalDirection: 1, safeExtent: .infinity
        ) == nil)
        #expect(ReactiveRouteAvailability.Route(
            intentID: "move", motionClass: .relocation,
            horizontalDirection: -0.5, safeExtent: 20
        ) == nil)
        #expect(PointerReactionFacts(
            perception: .empty,
            horizontalOffsetFromPet: .nan,
            verticalOffsetFromPet: 0
        ) == nil)

        let alert = candidate("reactive.alert")
        #expect(ReactiveBehaviorConfiguration(
            candidates: [alert], rapidApproachSpeed: 0,
            maximumProjectedApproachDistance: 80, departureSpeed: 100
        ) == nil)
        var director = ReactiveBehaviorDirector(configuration: configuration([alert]))
        let routes = availability([route("reactive.alert")])
        _ = director.decide(
            in: world(2), pointer: pointer(sampleTime: 2),
            availability: routes, entropy: 0
        )
        #expect(director.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 0
        ) == nil)

        var boundedMath = ReactiveBehaviorDirector(configuration: configuration([
            candidate("reactive.token", expiry: 100, tokenCost: 1)
        ]))
        let tokenRoutes = availability([route("reactive.token")])
        let proposal = boundedMath.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: tokenRoutes, entropy: 0
        )!
        boundedMath.didPerform(proposal, at: time(1))
        #expect(boundedMath.nextDeadline(at: time(.greatestFiniteMagnitude)) == nil)
    }

    @Test("Clock regression cannot refill tokens or accept stale execution feedback")
    func monotonicBudgetAccounting() throws {
        let alert = candidate(
            "reactive.alert", expiry: 20, cooldown: 5, tokenCost: 1
        )
        var director = ReactiveBehaviorDirector(configuration: configuration(
            [alert], capacity: 1, refill: 10
        ))
        let routes = availability([route("reactive.alert")])
        let proposal = director.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 0
        )
        let first = try #require(proposal)
        director.didPerform(first, at: time(1))
        #expect(director.reactionTokenCount() == 0)

        #expect(director.nextDeadline(at: time(5)) == time(6))
        director.didPerform(first, at: time(4))
        #expect(director.reactionTokenCount() == 0)
        #expect(director.decide(
            in: world(4), pointer: pointer(sampleTime: 4),
            availability: routes, entropy: 0
        ) == nil)
        #expect(director.nextDeadline(at: time(6)) == time(11))
        #expect(director.nextDeadline(at: time(11)) == nil)
        #expect(director.reactionTokenCount() == 1)
    }

    @Test("Explicit monotonic time supports pointer events newer than world facts")
    func explicitEventTime() {
        let alert = candidate("reactive.alert")
        var director = ReactiveBehaviorDirector(configuration: configuration([alert]))
        let routes = availability([route("reactive.alert")])
        let staleWorld = world(0)
        let freshPointer = pointer(sampleTime: 1)
        #expect(director.decide(
            in: staleWorld, pointer: freshPointer,
            availability: routes, entropy: 0
        ) == nil)
        #expect(director.decide(
            in: staleWorld, at: time(1), pointer: freshPointer,
            availability: routes, entropy: 0
        )?.intentID == "reactive.alert")
    }

    @Test("Hard priority precedes utility and required capabilities fail closed")
    func priorityAndCapabilities() {
        let contextual = candidate(
            "context.gaze", trigger: .pointerNear,
            priority: .contextual, utility: 1
        )
        let reactive = ReactiveBehaviorCandidate(
            intent: requirement("reactive.alert"),
            trigger: .rapidApproach,
            priority: .immediateReactive,
            baseUtility: 0,
            expiry: 1,
            requiredCapabilityIDs: ["reactive.alert"]
        )!
        let config = configuration([contextual, reactive])
        let routes = [route("context.gaze"), route("reactive.alert")]
        var missing = ReactiveBehaviorDirector(configuration: config)
        #expect(missing.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: availability(routes), entropy: 0
        )?.intentID == "context.gaze")
        var capable = ReactiveBehaviorDirector(configuration: config)
        #expect(capable.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: availability(routes, capabilities: ["reactive.alert"]), entropy: 0
        )?.intentID == "reactive.alert")
    }

    @Test("The same event trace and supplied entropy replay exactly")
    func deterministicReplay() throws {
        let alert = candidate("reactive.alert", expiry: 10, cooldown: 2, tokenCost: 1)
        let config = configuration([alert], probability: 0.4, capacity: 1, refill: 5, variation: 0.1)
        let routes = availability([route("reactive.alert")])
        var first = ReactiveBehaviorDirector(configuration: config)
        var second = ReactiveBehaviorDirector(configuration: config)

        let a = first.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 42
        )
        let b = second.decide(
            in: world(1), pointer: pointer(sampleTime: 1),
            availability: routes, entropy: 42
        )
        #expect(a == b)
        let performed = try #require(a)
        first.didPerform(performed, at: time(1.1))
        second.didPerform(performed, at: time(1.1))
        #expect(first.reactionTokenCount() == second.reactionTokenCount())
        #expect(first.nextDeadline(at: time(2)) == second.nextDeadline(at: time(2)))
        let replayA = first.decide(
            in: world(6.1), pointer: pointer(sampleTime: 6.1),
            availability: routes, entropy: 99
        )
        let replayB = second.decide(
            in: world(6.1), pointer: pointer(sampleTime: 6.1),
            availability: routes, entropy: 99
        )
        #expect(replayA == replayB)
    }
}
