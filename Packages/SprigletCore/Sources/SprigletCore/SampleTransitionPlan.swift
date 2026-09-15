/// Requested experiences, distinct from the intermediate poses in a Blender
/// Action. Happy includes its authored settle; movement includes its landing.
public enum SampleTransitionIntent: String, CaseIterable, Codable, Sendable {
    case ready, curious, moveRight, moveLeft, happy, sleep
}

/// A finite route resolved at playback time, after the preceding request has
/// finished. Resolving on click would use stale state when a nap is still queued.
public struct SampleTransitionPlan: Equatable, Sendable {
    public let clips: [SampleClipID]
    public let sleepsAtEnd: Bool

    public init(to intent: SampleTransitionIntent, isSleeping: Bool, animatedSleep: Bool) {
        sleepsAtEnd = intent == .sleep
        if intent == .sleep {
            clips = isSleeping || !animatedSleep ? [] : [.fallAsleep]
            return
        }
        let wake: [SampleClipID] = isSleeping && animatedSleep ? [.wakeUp] : []
        let gesture: [SampleClipID]
        switch intent {
        case .ready, .sleep: gesture = []
        case .curious: gesture = [.idle]
        case .moveRight: gesture = [.walkRight]
        case .moveLeft: gesture = [.walkLeft]
        case .happy: gesture = [.pet, .settle]
        }
        clips = wake + gesture
    }
}
