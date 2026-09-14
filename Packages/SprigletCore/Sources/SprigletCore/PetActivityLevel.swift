import Foundation

/// Frequency is separate from personality, parked mode, and automatic activity.
public enum PetActivityLevel: String, CaseIterable, Codable, Sendable {
    case quiet, balanced, lively

    public var title: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .lively: "Lively"
        }
    }

    public var summary: String {
        switch self {
        case .quiet: "Longer rests between small moments."
        case .balanced: "Occasional greetings, curious pauses, and naps."
        case .lively: "More frequent moments, with plenty of quiet time."
        }
    }

    var delayMultiplier: Double {
        switch self {
        case .quiet: 1.5
        case .balanced: 1
        case .lively: 0.75
        }
    }
}
