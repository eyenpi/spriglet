import Foundation

/// The only situational facts the model receives. All are already known to
/// Spriglet: the local clock, whether the pet was napping, and a coarse bucket
/// of recent petting. No app, window, pointer, or location information.
public struct ConversationGrounding: Equatable, Sendable {
    public enum PartOfDay: String, CaseIterable, Sendable {
        case morning, afternoon, evening, night
    }

    public enum Affection: CaseIterable, Sendable {
        case none, some, lots
    }

    public let weekday: String
    public let partOfDay: PartOfDay
    public let wasSleeping: Bool
    public let affection: Affection

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    public init(date: Date, timeZone: TimeZone, companion: CompanionSnapshot) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        let weekdayIndex = min(max((components.weekday ?? 1) - 1, 0), 6)
        weekday = Self.weekdays[weekdayIndex]
        partOfDay = switch components.hour ?? 12 {
        case 5..<12: .morning
        case 12..<17: .afternoon
        case 17..<21: .evening
        default: .night
        }
        wasSleeping = companion.isSleeping
        affection = switch companion.recentAffection {
        case ..<0.15: .none
        case ..<0.5: .some
        default: .lots
        }
    }

    public var sentence: String {
        var parts = ["Right now it is \(weekday) \(partOfDay.rawValue)."]
        parts.append(wasSleeping ? "You were napping and just woke up to talk." : "You are awake and resting nearby.")
        switch affection {
        case .none: break
        case .some: parts.append("They petted you recently.")
        case .lots: parts.append("They have petted you a lot recently, and you feel especially loved.")
        }
        return parts.joined(separator: " ")
    }
}
