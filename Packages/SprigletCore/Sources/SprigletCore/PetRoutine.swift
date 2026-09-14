import Foundation

/// A finite composition of existing authored poses, never an autonomous movement clock.
public enum PetRoutine: String, CaseIterable, Codable, Sendable {
    case observe, greet, explore, firefly

    /// The settle clip begins in the petted pose. Neutral walks therefore end
    /// with idle, while a pet reaction always settles before another walk.
    /// An invalid walking direction produces no playable request.
    public func clips(direction: SampleClipID = .walkLeft, stationary: Bool = false) -> [SampleClipID] {
        guard direction == .walkLeft || direction == .walkRight else { return [] }
        let returning: SampleClipID = direction == .walkLeft ? .walkRight : .walkLeft
        switch self {
        case .observe: return [.idle]
        case .greet: return [.pet, .settle]
        case .explore: return stationary ? [.idle] : [.idle, direction, .idle, returning, .idle]
        case .firefly: return stationary ? [.idle, .pet, .settle] : [.idle, direction, .pet, .settle, returning, .idle]
        }
    }
}

/// Visual-only pose in the manifest's point canvas. It never enlarges the pet's hit region.
public struct FireflyPose: Equatable, Sendable {
    public let position: SamplePoint
    public let opacity: Double
    public let wingSpread: Double
}

public enum FireflyMotion {
    /// Derived entirely from an accepted authored frame. Holding that frame
    /// holds the toy; return/settle frames and a completed timeline have no toy.
    public static func pose(
        for snapshot: SampleTimelineSnapshot, manifest: SproutSampleManifest,
        direction: SampleClipID = .walkLeft, stationary: Bool = false
    ) -> FireflyPose? {
        guard !snapshot.isComplete, direction == .walkLeft || direction == .walkRight,
              let idle = manifest.clips[SampleClipID.idle.rawValue],
              let walk = manifest.clips[direction.rawValue],
              let pet = manifest.clips[SampleClipID.pet.rawValue],
              !idle.frames.isEmpty, !walk.frames.isEmpty, !pet.frames.isEmpty,
              manifest.framesPerSecond.isFinite, manifest.framesPerSecond > 0 else { return nil }
        let catchStart = idle.frames.count + (stationary ? 0 : walk.frames.count)
        let index = snapshot.timelineFrameIndex
        guard index >= 0, index < catchStart + pet.frames.count else { return nil }
        let catching = index >= catchStart
        let catchProgress = catching ? Double(index - catchStart) / Double(max(1, pet.frames.count - 1)) : 0
        let time = Double(index) / manifest.framesPerSecond
        let fadeIn = smoothStep(time / 0.3)
        let opacity = fadeIn * (1 - smoothStep((catchProgress - 0.35) / 0.50))
        guard opacity > 0 else { return nil }
        let approach = stationary ? 0 : min(1, max(0, Double(index - idle.frames.count) / Double(max(1, walk.frames.count - 1))))
        let ahead = 66.0 - 12.0 * approach
        let pull = smoothStep(catchProgress / 0.85)
        let sign = direction == .walkRight ? 1.0 : -1.0
        let x = 112 + sign * ahead * (1 - pull)
        let y = (146 + 4 * sin(time * .pi * 2 * 1.35)) * (1 - pull) + 175 * pull
        return FireflyPose(position: .init(x: x * manifest.displaySizePoints.width / 224,
                                          y: y * manifest.displaySizePoints.height / 224),
                           opacity: opacity, wingSpread: 0.35 + 0.65 * abs(sin(time * .pi * 2 * 4.8)))
    }

    private static func smoothStep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
