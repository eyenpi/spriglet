import Foundation

/// Only deliberate interactions with this pet; never observations of other apps.
public enum PetInteractionKind: String, CaseIterable, Codable, Sendable { case petted, played, relocated }

public struct PetInteractionValues: Equatable, Sendable {
    public let affection: Double
    public let play: Double
    public let relocation: Double
    public let quietSecondsRemaining: Double
}

/// Three bounded decaying traces, not an event log. No text or app activity is retained.
public struct PetInteractionMemory: Codable, Equatable, Sendable {
    private var affection = Trace()
    private var play = Trace()
    private var relocation = Trace()
    public init() {}

    public mutating func record(_ kind: PetInteractionKind, at now: Date = .now) {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return }
        switch kind {
        case .petted: affection.record(at: now, gain: 0.20, halfLife: 3 * 3_600)
        case .played: play.record(at: now, gain: 0.25, halfLife: 2 * 3_600)
        case .relocated: relocation.record(at: now, gain: 0.30, halfLife: 30 * 60)
        }
    }

    public func values(at now: Date = .now) -> PetInteractionValues {
        PetInteractionValues(
            affection: affection.value(at: now, halfLife: 3 * 3_600),
            play: play.value(at: now, halfLife: 2 * 3_600),
            relocation: relocation.value(at: now, halfLife: 30 * 60),
            quietSecondsRemaining: max(affection.quietRemaining(at: now, duration: 90),
                                       play.quietRemaining(at: now, duration: 150),
                                       relocation.quietRemaining(at: now, duration: 180))
        )
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        affection = (try? values.decode(Trace.self, forKey: .affection)) ?? Trace()
        play = (try? values.decode(Trace.self, forKey: .play)) ?? Trace()
        relocation = (try? values.decode(Trace.self, forKey: .relocation)) ?? Trace()
    }
    private enum CodingKeys: String, CodingKey { case affection, play, relocation }

    private struct Trace: Codable, Equatable, Sendable {
        private var strength: Double = 0
        private var updatedAt: Date?
        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let value = try values.decode(Double.self, forKey: .strength)
            let date = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
            if value.isFinite, let date, date.timeIntervalSinceReferenceDate.isFinite {
                strength = min(1, max(0, value))
                updatedAt = date
            }
        }

        mutating func record(at now: Date, gain: Double, halfLife: Double) {
            // Repeated presses/drag callbacks within 20 seconds are one observation.
            // A backwards clock or future persisted stamp is discarded on new input.
            if let age = age(at: now), age < 20 { return }
            strength = min(1, value(at: now, halfLife: halfLife) + gain)
            updatedAt = now
        }

        func value(at now: Date, halfLife: Double) -> Double {
            guard let age = age(at: now), age < 24 * 3_600 else { return 0 }
            return strength * exp2(-age / halfLife)
        }

        func quietRemaining(at now: Date, duration: Double) -> Double {
            guard strength > 0, let age = age(at: now) else { return 0 }
            return max(0, duration - age)
        }

        private func age(at now: Date) -> Double? {
            guard now.timeIntervalSinceReferenceDate.isFinite, let updatedAt else { return nil }
            let age = now.timeIntervalSince(updatedAt)
            return age.isFinite && age >= 0 ? age : nil
        }
        private enum CodingKeys: String, CodingKey { case strength, updatedAt }
    }
}
